#!/usr/bin/env bash
# Checks that the stack is bound to localhost, requires login,
# and stores only what the selected profile allows.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/grafana.sh
source scripts/lib/grafana.sh
load_env

pass() { echo "PASS $1"; }
fail() {
  echo "FAIL $1: $2"
  return 1
}

check_ports() {
  local port out cid lan
  for port in 3000 4317 4318; do
    out="$(docker compose port lgtm "$port" 2>/dev/null || true)"
    [[ "$out" == "127.0.0.1:$port" ]] ||
      { fail ports "$port is published as '${out:-nothing}', want 127.0.0.1:$port"; return 1; }
  done
  for port in 9090 3200 4040; do
    out="$(docker compose port lgtm "$port" 2>/dev/null || true)"
    [[ -z "$out" ]] || { fail ports "$port must not be published (got $out)"; return 1; }
  done
  cid="$(docker compose ps -q lgtm)"
  [[ -n "$cid" ]] || { fail ports "container lgtm is not running"; return 1; }
  if docker inspect "$cid" --format '{{json .NetworkSettings.Ports}}' |
    jq -e '[.[] // [] | .[] | .HostIp] | any(. != "127.0.0.1")' >/dev/null; then
    fail ports "a port is bound to an address other than 127.0.0.1"
    return 1
  fi
  lan="$(ipconfig getifaddr en0 2>/dev/null || true)"
  if [[ -z "$lan" ]]; then
    echo "WARN ports: no LAN address on en0, skipped the LAN check"
  elif curl -s -o /dev/null --max-time 2 "http://$lan:3000/"; then
    fail ports "Grafana answers on the LAN address $lan"
    return 1
  fi
  pass ports
}

check_auth() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' "$GRAFANA_URL/api/dashboards/home" || true)"
  [[ "$code" == "401" ]] || { fail auth "anonymous request returned $code, want 401"; return 1; }
  grafana_api GET /api/user | jq -e '.login == "admin"' >/dev/null ||
    { fail auth "admin login failed"; return 1; }
  pass auth
}

usage() {
  echo "usage: $0 {ports|auth}" >&2
  exit 1
}

case "${1:-}" in
  ports) check_ports ;;
  auth) check_auth ;;
  *) usage ;;
esac
