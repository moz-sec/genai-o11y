# shellcheck shell=bash
# Helpers shared by verify.sh. Source this file; do not execute it.

GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:3000}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# load_env reads .env (if present) and defaults PROFILE to strict.
load_env() {
  if [[ -f "$REPO_ROOT/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$REPO_ROOT/.env"
    set +a
  fi
  PROFILE="${PROFILE:-strict}"
  export PROFILE
}

# grafana_api <method> <path> [curl args...]
# Calls the Grafana HTTP API as admin, prints the body, fails on HTTP >= 400.
grafana_api() {
  local method="$1" path="$2"
  shift 2
  curl -fsS -u "admin:${GRAFANA_ADMIN_PASSWORD:?GRAFANA_ADMIN_PASSWORD is not set}" \
    -X "$method" "$GRAFANA_URL$path" "$@"
}
