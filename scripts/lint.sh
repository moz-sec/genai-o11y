#!/usr/bin/env bash
# Lints the given files: shellcheck for shell scripts, markdownlint-cli2 for Markdown.
# Other files are ignored. With no arguments, lints every tracked file.
# Used by .githooks/pre-commit and the Claude Code hook in .claude/settings.json.
set -euo pipefail

cd "$(dirname "$0")/.."

files=("$@")
if ((${#files[@]} == 0)); then
  while IFS= read -r f; do files+=("$f"); done < <(git ls-files)
fi

sh_files=()
md_files=()
for f in "${files[@]}"; do
  # Paths may be absolute (agent hook); make them relative to the repo root.
  f="${f#"$PWD"/}"
  [[ -f "$f" ]] || continue
  case "$f" in
    *.md) md_files+=("$f") ;;
    *.sh | .githooks/*) sh_files+=("$f") ;;
  esac
done

status=0
if ((${#sh_files[@]})); then
  shellcheck -x "${sh_files[@]}" || status=1
fi
if ((${#md_files[@]})); then
  markdownlint-cli2 "${md_files[@]}" || status=1
fi
exit "$status"
