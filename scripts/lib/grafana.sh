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

# Datasource UIDs provisioned by grafana/otel-lgtm.
LOKI_UID=loki
PROM_UID=prometheus
TEMPO_UID=tempo

# ds_query_loki <logql>: log lines from the last hour, as Loki JSON.
ds_query_loki() {
  grafana_api GET "/api/datasources/proxy/uid/$LOKI_UID/loki/api/v1/query_range" -G \
    --data-urlencode "query=$1" --data-urlencode "since=1h" --data-urlencode "limit=1000"
}

# ds_query_prom <promql>: an instant query, as Prometheus JSON.
ds_query_prom() {
  grafana_api GET "/api/datasources/proxy/uid/$PROM_UID/api/v1/query" -G \
    --data-urlencode "query=$1"
}

# ds_search_tempo <traceql>: traces from the last hour that match the query.
ds_search_tempo() {
  local now
  now="$(date +%s)"
  grafana_api GET "/api/datasources/proxy/uid/$TEMPO_UID/api/search" -G \
    --data-urlencode "q=$1" --data-urlencode "start=$((now - 3600))" --data-urlencode "end=$((now + 60))"
}

# ds_get_trace <trace id>: one trace as OTLP JSON.
ds_get_trace() {
  grafana_api GET "/api/datasources/proxy/uid/$TEMPO_UID/api/v2/traces/$1" -H 'Accept: application/json'
}
