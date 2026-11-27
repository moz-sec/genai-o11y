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
  out="$(docker compose port lgtm 4040 2>/dev/null || true)"
  [[ -z "$out" ]] || { fail ports "4040 must not be published (got $out)"; return 1; }
  # compose.debug.yaml may open these; they must then be on 127.0.0.1 only.
  for port in 9090 3100 3200; do
    out="$(docker compose port lgtm "$port" 2>/dev/null || true)"
    [[ -z "$out" ]] && continue
    [[ "$out" == "127.0.0.1:$port" ]] ||
      { fail ports "$port is published as '$out', want 127.0.0.1:$port or nothing"; return 1; }
    echo "WARN ports: debug port $port is open without authentication (compose.debug.yaml)"
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

check_collector() {
  local logs selected
  logs="$(docker compose logs --no-log-prefix lgtm 2>&1)"
  grep -q 'Otelcol is up and running' <<<"$logs" ||
    { fail collector "the Collector did not report ready"; return 1; }
  if grep -Eq 'error decoding|cannot unmarshal|Otelcol exited' <<<"$logs"; then
    fail collector "the Collector reported a config error (see docker compose logs lgtm)"
    return 1
  fi
  selected="$(docker compose exec -T lgtm head -1 /otel-lgtm/profile.yaml 2>/dev/null || true)"
  [[ "$selected" == "# profile: $PROFILE" ]] ||
    { fail collector "running profile is '${selected:-none}', want $PROFILE (run docker compose up -d --force-recreate)"; return 1; }
  pass collector
}

# present_if <condition command...>: prints present when the command succeeds, else absent.
present_if() {
  if "$@" >/dev/null 2>&1; then echo present; else echo absent; fi
}

# has_any_key <json array of keys> <key...>
has_any_key() {
  local keys="$1"
  shift
  jq -e --args 'any(.[]; . as $k | $ARGS.positional | index($k))' "$@" <<<"$keys"
}

# expect <what> <present|absent> <actual>
expect() {
  if [[ "$2" != "$3" ]]; then
    echo "  $1: want $2, got $3"
    sanitize_failed=1
  fi
}

send_fixtures() {
  local run_id="$1" trace_id span_id now start signal body
  trace_id="$(openssl rand -hex 16)"
  span_id="$(openssl rand -hex 8)"
  now="$(date +%s)"
  start="$(((now - 1) * 1000000000))"
  now="$((now * 1000000000))"
  for signal in logs metrics traces; do
    body="$(sed -e "s/__RUN_ID__/$run_id/g" -e "s/__NOW_NS__/$now/g" -e "s/__START_NS__/$start/g" \
      -e "s/__TRACE_ID__/$trace_id/g" -e "s/__SPAN_ID__/$span_id/g" "tests/fixtures/otlp/$signal.json")"
    curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' \
      --data-binary "$body" "http://127.0.0.1:4318/v1/$signal"
  done
}

# wait_for <description> <command...>: retries for up to 30 seconds.
wait_for() {
  local what="$1"
  shift
  for _ in $(seq 1 30); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  fail sanitize "timed out waiting for $what"
  return 1
}

loki_has_fixtures() {
  ds_query_loki "$1" | jq -e '[.data.result[].stream.service_name] | index("claude-code") and index("codex")'
}
prom_has_fixtures() { ds_query_prom "{marker=\"$1\"}" | jq -e '.data.result | length > 0'; }
tempo_has_fixtures() { ds_search_tempo "{ span.marker = \"$1\" }" | jq -e '.traces | length > 0'; }

check_sanitize() {
  local run_id sent_at loki loki_keys prom prom_keys target_keys trace_ids trace trace_keys
  local strict_has=absent
  [[ "$PROFILE" == standard ]] && strict_has=present
  run_id="genai-o11y-fixture-$(date +%s)-$RANDOM"
  sanitize_failed=0

  sent_at="$(date +%s)"
  send_fixtures "$run_id" || { fail sanitize "could not send fixtures to 127.0.0.1:4318"; return 1; }

  local logql="{service_name=~\"claude-code|codex\"} | marker=\"$run_id\""
  wait_for "logs in Loki" loki_has_fixtures "$logql" || return 1
  wait_for "metrics in Prometheus" prom_has_fixtures "$run_id" || return 1
  wait_for "traces in Tempo" tempo_has_fixtures "$run_id" || return 1

  loki="$(ds_query_loki "$logql")"
  loki_keys="$(jq -c '[.data.result[].stream | keys[]] | unique' <<<"$loki")"
  prom="$(ds_query_prom "{marker=\"$run_id\"}")"
  prom_keys="$(jq -c '[.data.result[].metric | keys[]] | unique' <<<"$prom")"
  # Only samples written by this run; older ones stay visible for 5 minutes.
  target_keys="$(ds_query_prom "timestamp(target_info{job=~\"claude-code|codex\"}) >= $sent_at" |
    jq -c '[.data.result[].metric | keys[]] | unique')"
  trace_ids="$(ds_search_tempo "{ span.marker = \"$run_id\" }" | jq -r '.traces[].traceID')"
  trace="$(ds_get_trace "$(head -1 <<<"$trace_ids")")"
  trace_keys="$(jq -c '[.. | objects | select(has("key") and has("value")) | .key] | unique' <<<"$trace")"

  # Both profiles: no prompt text and no raw API bodies.
  expect "Loki prompt / prompt_text" absent "$(present_if has_any_key "$loki_keys" prompt prompt_text)"
  expect "Loki prompt text anywhere" absent "$(present_if grep -q 'fake prompt' <<<"$loki")"
  expect "Loki api_request_body event" absent "$(present_if grep -q 'api_request_body' <<<"$loki")"
  # Both profiles keep error classification.
  expect "Loki error_type" present "$(present_if has_any_key "$loki_keys" error_type)"
  expect "Loki status_code" present "$(present_if has_any_key "$loki_keys" status_code)"
  # strict removes these; standard keeps them.
  expect "Loki tool arguments / output / error" "$strict_has" \
    "$(present_if has_any_key "$loki_keys" tool_parameters tool_input arguments output error)"
  expect "Loki identity attributes" "$strict_has" \
    "$(present_if has_any_key "$loki_keys" user_email user_account_uuid organization_id host_name)"
  expect "Loki email address anywhere" "$strict_has" "$(present_if grep -q 'user@example.com' <<<"$loki")"
  expect "Prometheus identity labels" "$strict_has" \
    "$(present_if has_any_key "$prom_keys" user_email user_account_uuid)"
  expect "Prometheus target_info from this run" present "$(present_if jq -e 'length > 0' <<<"$target_keys")"
  expect "Prometheus target_info identity labels" "$strict_has" \
    "$(present_if has_any_key "$target_keys" user_email host_name host_id)"
  expect "Tempo tool_parameters" "$strict_has" "$(present_if has_any_key "$trace_keys" tool_parameters)"
  expect "Tempo identity attributes" "$strict_has" \
    "$(present_if has_any_key "$trace_keys" user.email host.name)"
  expect "Tempo email address anywhere" "$strict_has" "$(present_if grep -q 'user@example.com' <<<"$trace")"

  if ((sanitize_failed)); then
    fail sanitize "profile $PROFILE stored data it should not (or dropped data it should keep)"
    return 1
  fi
  pass sanitize
}

check_dashboards() {
  local uid dash home
  for uid in genai-usage-cost genai-activity; do
    dash="$(grafana_api GET "/api/dashboards/uid/$uid" 2>/dev/null)" ||
      { fail dashboards "$uid not found"; return 1; }
    jq -e '.meta.folderTitle == "genai-o11y"' >/dev/null <<<"$dash" ||
      { fail dashboards "$uid is not in the genai-o11y folder"; return 1; }
    jq -e '[.dashboard.templating.list[].name] | index("service") and index("model")' >/dev/null <<<"$dash" ||
      { fail dashboards "$uid lacks the service and model variables"; return 1; }
  done
  # Grafana 12+ imports the home JSON as a copy and answers with a redirect to it.
  home="$(grafana_api GET /api/dashboards/home)"
  uid="$(jq -r '.dashboard.uid // (.redirectUri // "" | capture("^/d/(?<u>[^/]+)").u) // ""' <<<"$home")"
  [[ -n "$uid" ]] && home="$(grafana_api GET "/api/dashboards/uid/$uid")"
  jq -e '.dashboard.title == "GenAI Usage & Cost"' >/dev/null <<<"$home" ||
    { fail dashboards "home dashboard is not GenAI Usage & Cost"; return 1; }
  # The leak panel must query Loki, so it sees every stored log line.
  jq -e '[.dashboard.panels[] | .panels[]? // . |
      select(.title == "Sanitization leaks" or .title == "サニタイズ漏れ") |
      .targets[] | select(.datasource.uid == "loki" and (.expr | length > 0))] | length > 0' \
    >/dev/null <<<"$dash" ||
    { fail dashboards "genai-activity has no Sanitization leaks panel with a LogQL query"; return 1; }
  pass dashboards
}

# check_all runs every check, even after a failure, and fails if any failed.
check_all() {
  local check failed=0
  for check in ports auth collector sanitize dashboards; do
    "check_$check" || failed=1
  done
  return "$failed"
}

usage() {
  echo "usage: $0 [all|ports|auth|collector|sanitize|dashboards]  (default: all)" >&2
  exit 1
}

case "${1:-all}" in
  all) check_all ;;
  ports) check_ports ;;
  auth) check_auth ;;
  collector) check_collector ;;
  sanitize) check_sanitize ;;
  dashboards) check_dashboards ;;
  *) usage ;;
esac
