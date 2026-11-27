# genai-o11y

[日本語](README.ja.md)

Local-only observability for AI coding agents.
genai-o11y collects OpenTelemetry metrics, logs, and traces from
[Claude Code](https://code.claude.com/docs/en/monitoring-usage) and
[OpenAI Codex CLI](https://developers.openai.com/codex/config-advanced).
It shows them on Grafana dashboards running on your own machine.

> [!WARNING]
> **Status: under development.** The design is in [docs/design.md](docs/design.md).
> The setup steps below describe the intended usage and may not work yet.

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
  *Activity* shows tool calls and errors, latency, traces, and a
  sanitization-leak check.
- **Safe agent setup**. A script merges the needed settings into
  `~/.claude/settings.json` and `~/.codex/config.toml`.
  It runs as a dry run by default, takes a backup, and stops on conflicts.

## Requirements

- macOS on Apple silicon
- Docker Desktop
- `jq`
- Claude Code and/or Codex CLI

## Quick start

```sh
cp .env.example .env            # set PROFILE=strict|standard and GRAFANA_ADMIN_PASSWORD
docker compose up -d
./scripts/apply-agent-config.sh strict          # dry run: shows the diff
./scripts/apply-agent-config.sh strict --apply  # writes the settings
./scripts/verify.sh                             # checks bindings and sanitization
```

Open <http://localhost:3000> and sign in as `admin`.

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
