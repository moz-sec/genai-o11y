# Security Policy

## Reporting a vulnerability

Please do not open a public issue for security problems.
Use GitHub's [private vulnerability reporting](https://github.com/moz-sec/genai-o11y/security/advisories/new) instead.

Examples of what we consider a vulnerability:

- A port that ends up reachable from outside the machine (not bound to `127.0.0.1`).
- Data that the `strict` profile should remove (see [docs/design.md](docs/design.md)) but that is still stored.
- `apply-agent-config.sh` overwriting or corrupting existing user settings.
- Telemetry sent to any destination other than the local container.

We aim to acknowledge reports within 7 days.

## Supported versions

Only the latest commit on the default branch is supported.

## Scope

The container image (`grafana/otel-lgtm`) is third-party software.
So are the agents (Claude Code, Codex CLI).
Report vulnerabilities in them to their upstream projects.
