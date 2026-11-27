#!/usr/bin/env bash
# Assertions are bash snippets passed to check() and run with eval,
# so single-quoted expansions and globals set by helpers are intended.
# shellcheck disable=SC2016,SC2034
# Tests for scripts/agent-env.sh. No Docker needed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/agent-env.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-env-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

# A fake codex binary that prints each argument on its own line.
mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/codex" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done
EOF
chmod +x "$TMP_ROOT/bin/codex"

failures=0
current=""
NL=$'\n'

check() {
  if ! eval "$1"; then
    echo "  assertion failed: $1"
    case_failed=1
  fi
}

# in_shell <shell> <script args> <commands>: evals the script output in a fresh
# shell with an empty HOME and the fake codex first in PATH, then runs commands.
in_shell() {
  local shell="$1" args="$2" commands="$3" home="$TMP_ROOT/home-$current"
  mkdir -p "$home"
  CODE=0
  OUT="$(env -i HOME="$home" PATH="$TMP_ROOT/bin:/usr/bin:/bin" "$shell" -c \
    "genai_env=\"\$('$SCRIPT' $args)\" || exit 9; eval \"\$genai_env\"; $commands" 2>&1)" || CODE=$?
}

t_bad_profile() {
  CODE=0
  "$SCRIPT" work >/dev/null 2>&1 || CODE=$?
  check '[[ $CODE == 1 ]]'
  CODE=0
  "$SCRIPT" >/dev/null 2>&1 || CODE=$?
  check '[[ $CODE == 1 ]]'
}

t_strict_exports_claude_env() {
  in_shell bash strict 'env | sort'
  check '[[ $CODE == 0 ]]'
  local key value
  while IFS=$'\t' read -r key value; do
    check "[[ \$OUT == *$'\n'$key=$value$'\n'* || \$OUT == $key=$value$'\n'* ]]"
  done <<<"$(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$ROOT/agents/claude/strict.env.json")"
  check '[[ $OUT != *OTEL_LOG_TOOL_DETAILS* ]]'
}

t_standard_exports_tool_details() {
  in_shell bash standard 'env'
  check '[[ $OUT == *OTEL_LOG_TOOL_DETAILS=1* ]]'
  check '[[ $OUT != *OTEL_METRICS_INCLUDE_ACCOUNT_UUID* ]]'
}

t_codex_otel_passes_overrides() {
  in_shell bash strict 'codex-otel exec "hello world"'
  check '[[ $CODE == 0 ]]'
  check '[[ $OUT == *"otel.log_user_prompt=false"* ]]'
  check '[[ $OUT == *"otel.metrics_exporter={ otlp-http = { endpoint = \"http://localhost:4318/v1/metrics\", protocol = \"binary\" } }"* ]]'
  check '[[ $OUT == *"otel.exporter={ otlp-http = { endpoint = \"http://localhost:4318/v1/logs\""* ]]'
  check '[[ $OUT == *"otel.trace_exporter={ otlp-http = { endpoint = \"http://localhost:4318/v1/traces\""* ]]'
  check '[[ $(grep -c "^-c$" <<<"$OUT") == 4 ]]'
  check '[[ $OUT == *"${NL}exec${NL}hello world" ]]'
}

# A codex shell function the user already has (for example one that injects a token)
# must still run: codex-otel calls codex, not the binary directly.
t_codex_otel_keeps_user_codex_function() {
  in_shell bash strict 'codex() { echo wrapped; command codex "$@"; }; codex-otel exec'
  check '[[ $OUT == "wrapped${NL}"* ]]'
}

t_works_in_zsh() {
  command -v zsh >/dev/null || return 0
  in_shell zsh strict 'echo "telemetry=$CLAUDE_CODE_ENABLE_TELEMETRY"; codex-otel exec'
  check '[[ $CODE == 0 ]]'
  check '[[ $OUT == *telemetry=1* ]]'
  check '[[ $OUT == *"otel.metrics_exporter="* ]]'
}

t_off_unsets_everything() {
  in_shell bash strict "off=\"\$('$SCRIPT' --off)\" || exit 8; eval \"\$off\"; env; type codex-otel || echo no-function"
  check '[[ $CODE == 0 ]]'
  check '[[ $OUT != *CLAUDE_CODE_ENABLE_TELEMETRY* ]]'
  check '[[ $OUT != *OTEL_* ]]'
  check '[[ $OUT == *no-function* ]]'
}

t_writes_no_files() {
  in_shell bash standard 'true'
  check '[[ $CODE == 0 ]]'
  check '[[ -z "$(find "$TMP_ROOT/home-$current" -mindepth 1)" ]]'
}

cases=(
  bad_profile strict_exports_claude_env standard_exports_tool_details
  codex_otel_passes_overrides codex_otel_keeps_user_codex_function works_in_zsh
  off_unsets_everything writes_no_files
)

for current in "${cases[@]}"; do
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
