#!/usr/bin/env bash
# Merges genai-o11y telemetry settings into the Claude Code and Codex configs.
#
# usage: apply-agent-config.sh <strict|standard> [--apply]
#
# Without --apply it only prints what would change (dry run).
# With --apply it backs up each file it changes, then writes it.
#
# Exit codes:
#   0  done, or dry run
#   1  usage error
#   2  an existing Claude Code setting has a different value
#   3  managed settings already configure telemetry
#   4  a settings file is not valid JSON
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
CODEX_CONFIG="${CODEX_CONFIG:-$HOME/.codex/config.toml}"
MANAGED_SETTINGS="${MANAGED_SETTINGS:-/Library/Application Support/ClaudeCode/managed-settings.json}"

usage() {
  echo "usage: $(basename "$0") <strict|standard> [--apply]" >&2
  exit 1
}

profile="${1:-}"
apply=false
case "$profile" in
  strict | standard) ;;
  *) usage ;;
esac
case "${2:-}" in
  "") ;;
  --apply) apply=true ;;
  *) usage ;;
esac
[[ $# -le 2 ]] || usage

CLAUDE_TEMPLATE="$ROOT/agents/claude/$profile.env.json"
CODEX_TEMPLATE="$ROOT/agents/codex/$profile.toml"

# resolve <path>: follows a symlink so that writing keeps the link intact.
resolve() {
  if [[ -L "$1" ]]; then
    readlink -f "$1"
  else
    printf '%s\n' "$1"
  fi
}

# valid_json_object <file>: true when the file holds one JSON object.
valid_json_object() {
  [[ -s "$1" ]] && jq -e 'type == "object"' "$1" >/dev/null 2>&1
}

backup() {
  local file="$1" bak
  bak="$file.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$file" "$bak"
  echo "backup: $bak"
}

# write_file <target> <content file>: replaces target via a temp file in the same directory.
write_file() {
  local target="$1" content="$2" tmp
  mkdir -p "$(dirname "$target")"
  tmp="$(mktemp "$target.tmp.XXXXXX")"
  cat "$content" >"$tmp"
  if [[ -e "$target" ]]; then
    chmod "$(stat -f '%Lp' "$target")" "$tmp"
  fi
  mv "$tmp" "$target"
}

work="$(mktemp -d "${TMPDIR:-/tmp}/apply-agent-config.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# 1. Managed settings take precedence over user settings, so do not compete with them.
if [[ -e "$MANAGED_SETTINGS" ]]; then
  if ! valid_json_object "$MANAGED_SETTINGS"; then
    echo "error: $MANAGED_SETTINGS is not a valid JSON object" >&2
    exit 4
  fi
  managed_keys="$(jq -r '(.env // {}) | keys[] | select(startswith("OTEL_") or . == "CLAUDE_CODE_ENABLE_TELEMETRY")' "$MANAGED_SETTINGS")"
  if [[ -n "$managed_keys" ]]; then
    echo "error: managed settings already configure telemetry ($MANAGED_SETTINGS):" >&2
    while IFS= read -r key; do echo "  $key" >&2; done <<<"$managed_keys"
    echo "Ask your administrator instead of changing user settings." >&2
    exit 3
  fi
fi

# 2. Claude Code: merge the template into .env, refusing to change existing values.
claude_target="$(resolve "$CLAUDE_SETTINGS")"
if [[ -e "$claude_target" ]]; then
  if ! valid_json_object "$claude_target"; then
    echo "error: $CLAUDE_SETTINGS is empty or not a valid JSON object; fix it first" >&2
    exit 4
  fi
  cp "$claude_target" "$work/claude.current.json"
else
  echo '{}' >"$work/claude.current.json"
fi

conflicts="$(jq -r --slurpfile new "$CLAUDE_TEMPLATE" '
  (.env // {}) as $env
  | $new[0] | to_entries[]
  | .key as $k
  | select(($env | has($k)) and $env[$k] != .value)
  | "  \(.key): current \($env[.key] | tojson), wanted \(.value | tojson)"
' "$work/claude.current.json")"
if [[ -n "$conflicts" ]]; then
  echo "error: $CLAUDE_SETTINGS already has different values:" >&2
  echo "$conflicts" >&2
  echo "Nothing was written. Change or remove these keys, then run again." >&2
  exit 2
fi

jq --indent 2 --slurpfile new "$CLAUDE_TEMPLATE" '.env = ((.env // {}) + $new[0])' \
  "$work/claude.current.json" >"$work/claude.new.json"

# 3. Codex: append the [otel] table only when the file has none.
codex_target="$(resolve "$CODEX_CONFIG")"
codex_action=append
if [[ -e "$codex_target" ]] && grep -Eq '^[[:space:]]*\[otel(\.|\])' "$codex_target"; then
  codex_action=manual
fi

# 4. Report, then write if asked.
claude_changed=true
if [[ -e "$claude_target" ]] && jq -e --slurpfile a "$work/claude.new.json" '. == $a[0]' "$claude_target" >/dev/null; then
  claude_changed=false
fi

echo "== Claude Code: $CLAUDE_SETTINGS"
if [[ "$claude_changed" == true ]]; then
  jq --indent 2 . "$work/claude.current.json" >"$work/claude.current.pretty.json"
  diff -u --label current --label new "$work/claude.current.pretty.json" "$work/claude.new.json" || [[ $? == 1 ]]
else
  echo "already up to date"
fi

echo "== Codex: $CODEX_CONFIG"
if [[ "$codex_action" == manual ]]; then
  echo "An [otel] table already exists, so this file is left as is."
  echo "Make sure it matches the following (metrics_exporter must not be statsig):"
  cat "$CODEX_TEMPLATE"
else
  echo "Will append:"
  cat "$CODEX_TEMPLATE"
fi

if [[ "$apply" != true ]]; then
  echo
  echo "Dry run. Run again with --apply to write the changes."
  exit 0
fi

if [[ "$claude_changed" == true ]]; then
  [[ -e "$claude_target" ]] && backup "$claude_target"
  write_file "$claude_target" "$work/claude.new.json"
  echo "wrote: $CLAUDE_SETTINGS"
fi

if [[ "$codex_action" == append ]]; then
  if [[ -e "$codex_target" ]]; then
    backup "$codex_target"
    cp "$codex_target" "$work/codex.new.toml"
    # Keep the existing last line intact and separate the new table with a blank line.
    [[ -z "$(tail -c 1 "$work/codex.new.toml")" ]] || echo >>"$work/codex.new.toml"
    echo >>"$work/codex.new.toml"
  else
    : >"$work/codex.new.toml"
  fi
  cat "$CODEX_TEMPLATE" >>"$work/codex.new.toml"
  write_file "$codex_target" "$work/codex.new.toml"
  echo "wrote: $CODEX_CONFIG"
fi
