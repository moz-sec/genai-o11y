# genai-o11y

[日本語](README.ja.md)

Local-only observability for AI coding agents.
genai-o11y collects OpenTelemetry metrics, logs, and traces from
[Claude Code](https://code.claude.com/docs/en/monitoring-usage) and
[OpenAI Codex CLI](https://developers.openai.com/codex/config-advanced).
It shows them on Grafana dashboards running on your own machine.

## Features

- **One container**. It runs the official
  [`grafana/otel-lgtm`](https://github.com/grafana/docker-otel-lgtm) image,
  pinned by version and digest.
  The image bundles Grafana, Prometheus, Loki and Tempo with the OpenTelemetry Collector.
- **Localhost only**. Every published port is bound to `127.0.0.1`.
  No telemetry leaves the machine.
- **Two collection profiles**. With `strict` (the default), the Collector removes prompts,
  tool arguments and error bodies before storage.
  It also removes emails, account IDs and host names.
  The `standard` profile removes only prompts and keeps more detail for analysis.
- **Ready-made dashboards**. *Usage & Cost* shows tokens and estimated cost,
  sessions, active time and lines of code.
  *Activity* shows tool calls and errors, latency, the event log,
  traces (click one to see its spans), and a sanitization-leak check.
  Codex is not yet verified with real data: *Usage & Cost* shows Claude Code only,
  and *Activity* includes Codex logs on a best-effort basis.
- **Safe agent setup**. A script merges the needed settings into
  `~/.claude/settings.json` and `~/.codex/config.toml`.
  It runs as a dry run by default, takes a backup, and stops on conflicts.
  If you would rather not touch those files, turn telemetry on for one shell only.

## Requirements

- macOS on Apple silicon
- Docker Desktop
- `jq`
- Claude Code and/or Codex CLI

## Quick start

```sh
cp .env.example .env            # set PROFILE=strict|standard and GRAFANA_ADMIN_PASSWORD
docker compose up -d
./scripts/verify.sh             # checks bindings, login, sanitization and dashboards
```

Then turn on telemetry in the agents. Pick one of the two ways.

**Persistent**: write the settings to the agents' config files.

```sh
./scripts/apply-agent-config.sh strict          # dry run: shows the diff
./scripts/apply-agent-config.sh strict --apply  # writes the settings (with a backup)
```

**This shell only**: nothing is written to `~/.claude` or `~/.codex`.

```sh
eval "$(./scripts/agent-env.sh strict)"   # exports the variables for Claude Code
claude                                    # Claude Code reads them
codex-otel                                # runs codex with the [otel] settings as -c options
eval "$(./scripts/agent-env.sh --off)"    # turns it off again
```

Codex has no environment variables for these settings, so use `codex-otel` instead of `codex`.
It calls `codex`, so a `codex` shell function you already have still runs.
If `~/.claude/settings.json` sets the same `env` keys, those values win.

Open <http://localhost:3000> and sign in as `admin`.

## Check that it works

`./scripts/verify.sh` sends fake telemetry and checks what was stored.
It prints one `PASS` or `FAIL` line per check and exits with 1 if any check fails.
Run one check with `./scripts/verify.sh <ports|auth|collector|sanitize|dashboards>`.

Then check with a real agent:

1. Use Claude Code (or Codex) for a few minutes with telemetry on.
   Ask it to read a file and run a command, so that tools are called.
2. Open *GenAI Usage & Cost* (the home dashboard).
   Tokens, estimated cost and sessions should show values.
3. Open *GenAI Activity*. Tool calls, API latency and *Events* should show values.
   Click a trace ID in *Recent traces* to see its spans in *Trace detail*.
   With `PROFILE=strict`, *Sanitization leaks* should be 0 (green).

Metrics reach Prometheus about once a minute, so the first values can take a minute to appear.
Codex is not yet verified with real data.

## Switch the profile

1. Set `PROFILE` in `.env`.
2. Run `docker compose up -d`. The container is recreated with the new profile.
3. Apply the agent settings for the new profile
   (`apply-agent-config.sh <profile>` or `agent-env.sh <profile>`).
   `apply-agent-config.sh` stops if a key already has a different value.
   Change those keys by hand in that case.

Data stored before the switch stays as it was.
When you move from `standard` to `strict`, delete it with
`docker compose down -v` (this deletes all stored telemetry) and start again.

## Update the image

1. Set the new `grafana/otel-lgtm:<version>@sha256:<digest>` as `LGTM_IMAGE`
   in `.env.example` and in your `.env`.
2. Compare the bundled Collector config with `collector/base.yaml`:

   ```sh
   docker run --rm --entrypoint cat "$LGTM_IMAGE" /otel-lgtm/otelcol-config.yaml | diff - collector/base.yaml
   ```

   Exporter endpoints or component names can change between versions.
3. Run `docker compose up -d` and `./scripts/verify.sh`.

## Collection profiles

| Item | `strict` (default) | `standard` |
| --- | --- | --- |
| Metrics | On | On |
| Logs (events) | On, sanitized | On |
| Traces | On (Claude Code: beta) | On |
| Prompt text | Removed | Removed |
| Tool arguments / output | Removed | Kept |
| Emails, account IDs, host names | Removed | Kept |
| Error bodies | Removed (status code and type kept) | Kept |

See [docs/design.md](docs/design.md) for the exact attribute list.

## Security notes

- `grafana/otel-lgtm` is intended for development and testing.
  Telemetry can contain sensitive data even when stored locally.
  Check any policy that applies to the machine before you use it.
- Binding ports to `127.0.0.1` blocks inbound access from other machines.
  It does not restrict outbound traffic from the container.
- Enable disk encryption (FileVault) to protect the stored data.
- Metrics, logs and traces are kept for 30 days.
  To delete all stored telemetry, run `docker compose down -v`.

To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
Coding agents should also read [AGENTS.md](AGENTS.md).

## License

[MIT](LICENSE)
