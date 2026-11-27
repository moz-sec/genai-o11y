#!/usr/bin/env bash
# Assertions are bash snippets passed to check() and run with eval,
# so single-quoted expansions and globals set by run() are intended.
# shellcheck disable=SC2016,SC2034
# Tests for scripts/apply-agent-config.sh. No Docker needed.
# Every case runs against files in its own temporary directory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/apply-agent-config.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/apply-agent-config-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
current=""

# setup creates a fresh fake home and points the script at it.
setup() {
  local dir="$TMP_ROOT/$current"
  mkdir -p "$dir/.claude" "$dir/.codex"
  export CLAUDE_SETTINGS="$dir/.claude/settings.json"
  export CODEX_CONFIG="$dir/.codex/config.toml"
  export MANAGED_SETTINGS="$dir/managed-settings.json"
  DIR="$dir"
}

# run <args...>: runs the script, stores stdout in OUT and the exit code in CODE.
run() {
  CODE=0
  OUT="$("$SCRIPT" "$@" 2>&1)" || CODE=$?
}

# check <bash test>: records a failure but keeps running the case.
check() {
  if ! eval "$1"; then
    echo "  assertion failed: $1"
    case_failed=1
  fi
}

backups() { find "$DIR/.claude" -name 'settings.json.bak.*' | wc -l | tr -d ' '; }

t_dry_run_writes_nothing() {
  echo '{"model":"x"}' >"$CLAUDE_SETTINGS"
  printf 'model = "o3"\n' >"$CODEX_CONFIG"
  run strict
  check '[[ $CODE == 0 ]]'
  check '[[ $(cat "$CLAUDE_SETTINGS") == "{\"model\":\"x\"}" ]]'
  check '[[ $(cat "$CODEX_CONFIG") == "model = \"o3\"" ]]'
  check '[[ $OUT == *CLAUDE_CODE_ENABLE_TELEMETRY* ]]'
  check '[[ $OUT == *"[otel]"* ]]'
  check '[[ $(backups) == 0 ]]'
}

t_creates_missing_settings() {
  rm -rf "$DIR/.claude" "$DIR/.codex"
  run strict --apply
  check '[[ $CODE == 0 ]]'
  check '[[ $(jq -r ".env.CLAUDE_CODE_ENABLE_TELEMETRY" "$CLAUDE_SETTINGS") == 1 ]]'
  check 'grep -q "^\[otel\]" "$CODEX_CONFIG"'
}

t_keeps_other_keys() {
  echo '{"model":"x","env":{"FOO":"bar"}}' >"$CLAUDE_SETTINGS"
  run strict --apply
  check '[[ $CODE == 0 ]]'
  check '[[ $(jq -r .model "$CLAUDE_SETTINGS") == x ]]'
  check '[[ $(jq -r .env.FOO "$CLAUDE_SETTINGS") == bar ]]'
}

t_backup_before_write() {
  echo '{"model":"x"}' >"$CLAUDE_SETTINGS"
  run strict --apply
  check '[[ $CODE == 0 ]]'
  check '[[ $(backups) == 1 ]]'
  local bak
  bak="$(find "$DIR/.claude" -name 'settings.json.bak.*')"
  check '[[ $bak =~ settings\.json\.bak\.[0-9]{14}$ ]]'
  check '[[ $(cat "$bak") == "{\"model\":\"x\"}" ]]'
}

t_conflict_aborts() {
  local before='{"env":{"OTEL_EXPORTER_OTLP_ENDPOINT":"https://example.com"}}'
  echo "$before" >"$CLAUDE_SETTINGS"
  run strict --apply
  check '[[ $CODE == 2 ]]'
  check '[[ $(cat "$CLAUDE_SETTINGS") == "$before" ]]'
  check '[[ $OUT == *OTEL_EXPORTER_OTLP_ENDPOINT* ]]'
  check '[[ ! -e "$CODEX_CONFIG" ]]'
}

t_same_value_is_not_conflict() {
  echo '{"env":{"OTEL_EXPORTER_OTLP_ENDPOINT":"http://localhost:4318"}}' >"$CLAUDE_SETTINGS"
  run strict --apply
  check '[[ $CODE == 0 ]]'
}

t_managed_settings_aborts() {
  echo '{"env":{"OTEL_LOGS_EXPORTER":"otlp"}}' >"$MANAGED_SETTINGS"
  run strict --apply
  check '[[ $CODE == 3 ]]'
  check '[[ ! -e "$CLAUDE_SETTINGS" ]]'
  check '[[ ! -e "$CODEX_CONFIG" ]]'
}

t_invalid_json_aborts() {
  echo '{' >"$CLAUDE_SETTINGS"
  run strict --apply
  check '[[ $CODE == 4 ]]'
  check '[[ $(cat "$CLAUDE_SETTINGS") == "{" ]]'
  : >"$CLAUDE_SETTINGS"
  run strict --apply
  check '[[ $CODE == 4 ]]'
  check '[[ ! -s "$CLAUDE_SETTINGS" ]]'
  check '[[ ! -e "$CODEX_CONFIG" ]]'
}

t_codex_appends_when_missing() {
  printf 'model = "o3"\n' >"$CODEX_CONFIG"
  run strict --apply
  check '[[ $CODE == 0 ]]'
  check '[[ $(head -1 "$CODEX_CONFIG") == "model = \"o3\"" ]]'
  check 'grep -q "^\[otel\]" "$CODEX_CONFIG"'
  check 'grep -q "metrics_exporter = { otlp-http" "$CODEX_CONFIG"'
  check '[[ $(find "$DIR/.codex" -name "config.toml.bak.*" | wc -l | tr -d " ") == 1 ]]'
}

t_codex_existing_otel_untouched() {
  local before
  before=$'[otel]\nexporter = "none"'
  echo "$before" >"$CODEX_CONFIG"
  run strict --apply
  check '[[ $CODE == 0 ]]'
  check '[[ $(cat "$CODEX_CONFIG") == "$before" ]]'
  check '[[ $OUT == *"metrics_exporter = { otlp-http"* ]]'
}

t_profile_values() {
  run strict --apply
  check '[[ $(jq -r .env.OTEL_METRICS_INCLUDE_ACCOUNT_UUID "$CLAUDE_SETTINGS") == false ]]'
  check '[[ $(jq -r ".env | has(\"OTEL_LOG_TOOL_DETAILS\")" "$CLAUDE_SETTINGS") == false ]]'
  rm -f "$CLAUDE_SETTINGS"
  run standard --apply
  check '[[ $(jq -r .env.OTEL_LOG_TOOL_DETAILS "$CLAUDE_SETTINGS") == 1 ]]'
  check '[[ $(jq -r ".env | has(\"OTEL_METRICS_INCLUDE_ACCOUNT_UUID\")" "$CLAUDE_SETTINGS") == false ]]'
}

t_bad_profile() {
  run work
  check '[[ $CODE == 1 ]]'
  run
  check '[[ $CODE == 1 ]]'
  run strict --force
  check '[[ $CODE == 1 ]]'
}

# Dotfile managers often make settings.json a symlink; keep the link intact.
t_follows_symlink() {
  echo '{"model":"x"}' >"$DIR/real-settings.json"
  ln -s "$DIR/real-settings.json" "$CLAUDE_SETTINGS"
  run strict --apply
  check '[[ $CODE == 0 ]]'
  check '[[ -L "$CLAUDE_SETTINGS" ]]'
  check '[[ $(jq -r .env.CLAUDE_CODE_ENABLE_TELEMETRY "$DIR/real-settings.json") == 1 ]]'
}

cases=(
  dry_run_writes_nothing creates_missing_settings keeps_other_keys backup_before_write
  conflict_aborts same_value_is_not_conflict managed_settings_aborts invalid_json_aborts
  codex_appends_when_missing codex_existing_otel_untouched profile_values bad_profile
  follows_symlink
)

for current in "${cases[@]}"; do
  setup
  if (
    case_failed=0
    "t_$current"
    exit "$case_failed"
  ); then
    echo "ok $current"
  else
    echo "not ok $current"
    failures=$((failures + 1))
  fi
done

if ((failures > 0)); then
  echo "$failures of ${#cases[@]} cases failed"
  exit 1
fi
echo "all ${#cases[@]} cases passed"
