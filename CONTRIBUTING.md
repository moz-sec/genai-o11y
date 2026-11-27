# Contributing

Thanks for your interest in genai-o11y. Issues and pull requests are welcome.

## Before you start

- Read [docs/design.md](docs/design.md) to understand the goals and non-goals.
- For a large change, open an issue first so we can agree on the approach.
- The rules in [AGENTS.md](AGENTS.md) apply to human contributors too.
  This is especially true of the hard rules about port binding and the `strict` profile.

## Development setup

Requirements:

- macOS (Apple silicon)
- Docker Desktop
- `jq`
- `shellcheck`
- `markdownlint-cli2`

```sh
cp .env.example .env
docker compose up -d
./scripts/verify.sh
git config core.hooksPath .githooks
```

The last command turns on the pre-commit hook in `.githooks/`.
It runs `scripts/lint.sh` on the staged files: `shellcheck` for shell scripts and `markdownlint-cli2` for Markdown.
Claude Code runs the same script after each file edit (see `.claude/settings.json`).
Run `./scripts/lint.sh` with no arguments to lint every tracked file.

## Pull requests

- Keep each pull request focused on one change.
- If an AI agent wrote or committed part of the change, add a `Co-Authored-By` trailer for it.
  See the Commits section in [AGENTS.md](AGENTS.md).
- Make sure these pass:
  - `docker compose config`
  - `./scripts/verify.sh` (with `PROFILE=strict`)
  - `./scripts/lint.sh` (`shellcheck` and `markdownlint-cli2`)
- If you change behavior, update `docs/design.md`, `README.md`, and `README.ja.md`.
- Never include real telemetry, prompts, emails or account IDs in issues, pull requests or test data.
  Use fake values such as `user@example.com`.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
