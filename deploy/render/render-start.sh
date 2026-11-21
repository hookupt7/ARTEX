#!/bin/bash
# Render entrypoint: optional local Postgres, artex on $PORT, first-boot bootstrap.
set -u
PORT="${PORT:-10000}"
LOG=/tmp/artex.log
PGBIN="${PGBIN:-/usr/lib/postgresql/15/bin}"
PGDATA="${PGDATA:-/tmp/pgdata}"
LPGPORT="${LOCAL_PG_PORT:-5432}"
APP_DIR="${APP_DIR:-/app}"

as_pg() { if [ "$(id -u)" = 0 ]; then runuser -u postgres -- "$@"; else "$@"; fi; }

if [ -z "${ARTEX_PG_DSN:-}" ]; then
  echo "[render] ARTEX_PG_DSN not set: starting in-container Postgres (data is ephemeral)"
  mkdir -p "$PGDATA" /tmp/pgsock
  [ "$(id -u)" = 0 ] && chown -R postgres:postgres "$PGDATA" /tmp/pgsock
  if [ ! -s "$PGDATA/PG_VERSION" ]; then
    as_pg "$PGBIN/initdb" -D "$PGDATA" -U artex --auth=trust -E UTF8 >/dev/null
  fi
  as_pg "$PGBIN/pg_ctl" -D "$PGDATA" -w -l /tmp/pg.log start \
    -o "-c listen_addresses=127.0.0.1 -c port=$LPGPORT -c unix_socket_directories=/tmp/pgsock -c shared_buffers=24MB -c max_connections=30 -c work_mem=2MB -c maintenance_work_mem=16MB -c fsync=off -c synchronous_commit=off -c full_page_writes=off" \
    || { cat /tmp/pg.log; exit 1; }
  as_pg "$PGBIN/psql" -h /tmp/pgsock -p "$LPGPORT" -U artex -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='artex'" | grep -q 1 \
    || as_pg "$PGBIN/createdb" -h /tmp/pgsock -p "$LPGPORT" -U artex artex
  export ARTEX_PG_DSN="postgres://artex@127.0.0.1:${LPGPORT}/artex?sslmode=disable"
fi

bootstrap() {
  local base="http://127.0.0.1:${PORT}" i tok st body id
  for i in $(seq 1 120); do curl -fs "$base/api/health" >/dev/null 2>&1 && break; sleep 1; done
  for i in $(seq 1 60); do
    st=$(curl -s "$base/api/auth/status" | jq -r '.initialized|tostring' 2>/dev/null)
    { [ "$st" = "true" ] || [ "$st" = "false" ]; } && break; sleep 1
  done
  echo "[render] auth initialized=$st"
  if [ "$st" = "false" ] && [ -n "${ARTEX_ADMIN_PASSWORD:-}" ]; then
    tok=""
    for i in $(seq 1 30); do
      tok=$(grep -o 'Setup token for the /setup page: [0-9a-f]*' "$LOG" | tail -1 | awk '{print $NF}')
      [ -n "$tok" ] && break; sleep 1
    done
    body=$(jq -nc --arg p "$ARTEX_ADMIN_PASSWORD" --arg t "$tok" '{password:$p,setup_token:$t}')
    curl -s -o /dev/null -w '[render] admin init: HTTP %{http_code}\n' -X POST "$base/api/auth/init" -H 'content-type: application/json' -d "$body"
  fi
  [ -n "${ARTEX_ADMIN_PASSWORD:-}" ] || return 0
  body=$(jq -nc --arg p "$ARTEX_ADMIN_PASSWORD" '{username:"ARTEX",password:$p}')
  tok=$(curl -s -X POST "$base/api/auth/login" -H 'content-type: application/json' -d "$body" | jq -r '.token // empty')
  [ -n "$tok" ] || { echo "[render] bootstrap login failed"; return 0; }
  if [ -n "${BOOT_LLM_API_KEY:-}" ]; then
    n=$(curl -s "$base/api/llm/profiles" -H "Authorization: Bearer $tok" | jq '.profiles | length')
    if [ "${n:-0}" = "0" ]; then
      body=$(jq -nc --arg n "${BOOT_LLM_NAME:-default}" --arg f "${BOOT_LLM_FORMAT:-openai}" \
        --arg u "${BOOT_LLM_BASE_URL:-}" --arg m "${BOOT_LLM_MODEL:-}" --arg k "$BOOT_LLM_API_KEY" \
        '{name:$n,format:$f,base_url:$u,model:$m,api_key:$k,streaming:true}')
      id=$(curl -s -X POST "$base/api/llm/profiles" -H "Authorization: Bearer $tok" -H 'content-type: application/json' -d "$body" | jq -r '.id // .profile.id // empty')
      echo "[render] LLM profile created: id=${id:-?}"
      [ -n "$id" ] && curl -s -o /dev/null -w '[render] profile activate: HTTP %{http_code}\n' -X POST "$base/api/llm/profiles/active" \
        -H "Authorization: Bearer $tok" -H 'content-type: application/json' -d "{\"id\":$id}"
    fi
  fi
}

bootstrap &

cd "$APP_DIR"
trap 'kill -TERM $child 2>/dev/null; wait $child; as_pg "$PGBIN/pg_ctl" -D "$PGDATA" -m fast stop >/dev/null 2>&1; exit 0' TERM INT
EXTRA=(); [ "$(id -u)" = 0 ] || EXTRA=(-exec-uid -1)
./artex -addr ":${PORT}" -proxy "" -data "$APP_DIR/data" "${EXTRA[@]}" "$@" > >(tee -a "$LOG") 2>&1 &
child=$!
wait $child
