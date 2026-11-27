#!/usr/bin/env bash
# Prints shell code that turns on genai-o11y telemetry for the current shell only.
# Nothing is written to ~/.claude or ~/.codex.
#
# usage:
#   eval "$(./scripts/agent-env.sh <strict|standard>)"   # turn on
#   eval "$(./scripts/agent-env.sh --off)"               # turn off
#
# Claude Code reads the exported OTEL_* variables.
# Codex has no environment variables for this, so the output defines a
# codex-otel function that runs `codex -c otel.<key>=<value> ... "$@"`.
# It calls codex (not the binary), so an existing codex shell function still runs.
#
# Works in bash and zsh. Exit codes: 0 success, 1 usage error.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  echo "usage: eval \"\$($(basename "$0") <strict|standard>)\" | eval \"\$($(basename "$0") --off)\"" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage

# quote <string>: single-quotes a string for bash and zsh.
quote() {
  local s="$1" q="'\\''"
  printf "'%s'" "${s//\'/$q}"
}

if [[ "$1" == --off ]]; then
  # Unset every key either profile can set.
  keys="$(jq -rs 'map(keys[]) | unique | join(" ")' "$ROOT"/agents/claude/*.env.json)"
  echo "unset $keys"
  echo "unset -f codex-otel 2>/dev/null || true"
  exit 0
fi

case "$1" in
  strict | standard) profile="$1" ;;
  *) usage ;;
esac

echo "# genai-o11y ($profile): telemetry for this shell only. Undo with: eval \"\$(scripts/agent-env.sh --off)\""
jq -r 'to_entries[] | "export \(.key)=\(.value | @sh)"' "$ROOT/agents/claude/$profile.env.json"

# Turn each `key = value` line of the Codex [otel] table into `-c otel.key=value`.
args=""
in_otel=false
while IFS= read -r line; do
  case "$line" in
    "[otel]") in_otel=true ;;
    "["*) in_otel=false ;;
    *" = "*)
      if [[ "$in_otel" == true ]]; then
        args+=" -c $(quote "otel.${line%% = *}=${line#* = }")"
      fi
      ;;
  esac
done <"$ROOT/agents/codex/$profile.toml"

echo "codex-otel() { codex$args \"\$@\"; }"
