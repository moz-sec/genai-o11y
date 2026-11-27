# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, and others) working in this repository.
Human contributors should read [CONTRIBUTING.md](CONTRIBUTING.md) as well.

## Project overview

genai-o11y runs `grafana/otel-lgtm` as a single container on macOS.
It collects OpenTelemetry data from Claude Code and Codex CLI
and shows it on Grafana dashboards.
The design and its rationale are in [docs/design.md](docs/design.md).
Read it before you make a non-trivial change.

## Layout

| Path | Purpose |
| --- | --- |
| `compose.yaml` | The only container definition. The image is pinned here |
| `.env.example` | Profile selection and Grafana admin password |
| `renovate.json` | Renovate opens a PR when a new `grafana/otel-lgtm` image is released (never automerged) |
| `collector/` | OpenTelemetry Collector config: `base.yaml` plus `strict.yaml` / `standard.yaml` |
| `grafana/` | Dashboard JSON and provisioning |
| `agents/` | Per-profile settings for Claude Code (`env`) and Codex (`[otel]`) |
| `scripts/` | `apply-agent-config.sh`, `agent-env.sh` (current shell only), `verify.sh` and `lint.sh` |
| `.githooks/` | pre-commit hook that runs `scripts/lint.sh` (enable with `git config core.hooksPath .githooks`) |
| `docs/` | Design and other documentation. All docs live here |

## Hard rules

These protect users' data. Never break them, even if a task seems to require it.

1. **Never bind to `0.0.0.0`**. Every published port must use `127.0.0.1:<host>:<container>`.
   `compose.yaml` must not publish 9090, 3100, 3200, or 4040 (they have no authentication).
   Only the opt-in `compose.debug.yaml` may publish 9090, 3100, and 3200. Never publish 4040.
2. **Pin the image**. Use `grafana/otel-lgtm:<version>@sha256:<digest>`.
   When you bump it, compare the new image's bundled `otelcol-config.yaml`
   with `collector/base.yaml`.
   Also check that the bundled dashboards are still provisioned by
   `grafana/conf/provisioning/dashboards/grafana-dashboards.yaml`, which `compose.yaml` overrides.
   Note the result in the change description.
3. **The `strict` profile must not store** any of the following.
   This applies to logs, traces, and metrics (including `target_info` labels).
   - prompt text and assistant responses
   - tool arguments or output
   - error bodies
   - `user.email`, `user.account_uuid`, `user.account_id`, `user.id`
   - `organization.id`, `host.name`, or `host.id`
4. **Both profiles drop prompt text** in the Collector.
   They do so even though the agents already keep it off by default.
5. **Never send telemetry off the machine**. Do not add exporters to remote endpoints.
   Codex `metrics_exporter` must be `otlp-http` (its default, `statsig`, sends data to OpenAI).
6. **Do not overwrite user config**. `apply-agent-config.sh` defaults to a dry run
   and takes a timestamped backup before writing.
   It stops when an existing key has a different value.
7. **No real user data in the repo**. Test fixtures must use obviously fake values
   (for example `user@example.com`).

## Checks before you finish

- `docker compose config` succeeds.
- `./scripts/verify.sh` passes for the `strict` profile.
  If you changed sanitization, also add a case for the new attribute to `verify.sh`.
- Markdown passes `markdownlint-cli2` with `.markdownlint-cli2.jsonc`.
- `./scripts/lint.sh` passes. It runs `shellcheck` and `markdownlint-cli2`.
  Claude Code runs it after each edit through `.claude/settings.json`; other agents should run it themselves.
- If you changed behavior, update these files in the same change:
  - `docs/design.md`
  - both READMEs (`README.md` and `README.ja.md`)

## Conventions

- Shell scripts: `bash` with `set -euo pipefail`. Check them with `shellcheck`.
- YAML: 2-space indent.
- Dashboard JSON: export from Grafana, then remove the instance-specific `id` and `version` fields.
  Use datasource UIDs, not names.
- Docs: Japanese or English is fine. Keep the two READMEs in sync.
- Telemetry names change between agent versions.
  Check names against real data (or the official docs) before you write a query or a filter rule.

## Commits

When an AI agent creates a commit, it must add a `Co-Authored-By` trailer.
The trailer names the agent and the model.

- Format: `Co-Authored-By: <agent name> (<model>) <noreply address of the vendor>`.
  If the agent has its own documented trailer, use that instead.
- Put the trailer on the last line of the commit message, after a blank line.
- If several agents worked on the commit, add one trailer per agent.
- Use the same trailer in pull request descriptions created by an agent.

Examples:

```text
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Co-Authored-By: Codex (<model>) <noreply@openai.com>
```
