# Changelog

## 0.2.0 — 2026-10-09

- Correlate requests, serialized ActiveJob executions, and mailer attempts with native trace IDs while preserving existing OpenTelemetry context.
- Observe job enqueue/start, retry/discard, and completion without changing existing job-count semantics; distinguish total queue delay from delay after a scheduled job becomes eligible.
- Observe Action Mailer processing, ordinary/forced delivery attempts, disabled delivery, callback aborts, and exposed failures. Collect only bounded lifecycle metadata, excluding recipients, subjects, message bodies, attachments, and arguments. Recipient delivery remains unknown.
- Connect Claude Code and Codex with `rails_mind:agent`, including a write-free preview, preserved existing configuration, and shared agent instructions.
- Choose an environment-variable API token or a local Rails encrypted-credentials helper; check readiness without displaying the token.
- Document the full agent handoff: read findings, follow a brief, report a PR, and watch deployment and recurrence in RailsMind.

## 0.1.0 — 2026-09-25

Initial public release of the RailsMind client under the MIT license.

- Collect Rails request, error, and ActiveJob telemetry with bounded buffering,
  redaction, retries, and best-effort delivery.
- Track explicit business events and propagate visitor, user, account, and trace
  context through supported request and job integrations.
- Integrate with existing Ahoy, Flipper, and OpenTelemetry installations, plus
  an optional Ahoy/Turbo browser adapter.
- Install with a Rails generator, inspect configuration with `rails_mind:doctor`,
  and check ingestion with `rails_mind:verify`.
- Default to `https://railsmind.com` and detect deployed Git revisions from
  supported hosting metadata or a `REVISION` file.

This is an early release. See [compatibility](docs/compatibility.md) and
[delivery and privacy limits](docs/sdk.md#bounds-privacy-and-outages) before use.
The separate hosted RailsMind service remains proprietary.
