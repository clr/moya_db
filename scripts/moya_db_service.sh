#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REL_DIR="$ROOT_DIR/_build/prod/rel/moya_db"
PID_FILE="${MOYA_DB_PID_FILE:-/tmp/moya_db_release.pid}"

build_release() {
  cd "$ROOT_DIR"
  MIX_ENV=prod mix deps.get
  MIX_ENV=prod mix release
}

start_service() {
  if [[ -f "$PID_FILE" ]] && ps -p "$(cat "$PID_FILE")" >/dev/null 2>&1; then
    echo "MoyaDB already running (PID $(cat "$PID_FILE"))."
    exit 0
  fi

  [[ -x "$REL_DIR/bin/moya_db" ]] || build_release

  "$REL_DIR/bin/moya_db" daemon
  sleep 1

  local pid
  pid="$(pgrep -f "$REL_DIR" | head -n1 || true)"
  if [[ -n "$pid" ]]; then
    echo "$pid" > "$PID_FILE"
    echo "MoyaDB started (PID $pid)."
  else
    echo "MoyaDB started. (PID discovery skipped)"
  fi
}

stop_service() {
  if [[ -x "$REL_DIR/bin/moya_db" ]]; then
    "$REL_DIR/bin/moya_db" stop || true
  fi

  if [[ -f "$PID_FILE" ]]; then
    rm -f "$PID_FILE"
  fi

  echo "MoyaDB stopped."
}

status_service() {
  if [[ -f "$PID_FILE" ]] && ps -p "$(cat "$PID_FILE")" >/dev/null 2>&1; then
    echo "MoyaDB running (PID $(cat "$PID_FILE"))."
  else
    echo "MoyaDB not running (or PID file missing)."
  fi
}

case "${1:-}" in
  build)
    build_release
    ;;
  start)
    start_service
    ;;
  stop)
    stop_service
    ;;
  restart)
    stop_service
    start_service
    ;;
  status)
    status_service
    ;;
  *)
    echo "Usage: $0 {build|start|stop|restart|status}"
    exit 1
    ;;
esac