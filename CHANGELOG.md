# Changelog

## 0.3.1 — unreleased

- Send exception messages by default, scrubbed like every other string (emails, credentials, URL queries). `config.capture_exception_message = false` restores the placeholder.
- Send the shape of each repeated query next to its fingerprint: the normalized SQL with literals replaced by `?`, comments removed, and at most 400 characters, only for fingerprints that repeated within the request. `config.capture_query_shapes = false` sends fingerprints only.
- Strip SQL comments (query log tags, Marginalia) before fingerprinting, so a query tagged per request keeps one fingerprint.
- Name where each exception happened: `role` (`web`, `job`, `runner` or `console`), with the controller action as `route` for requests and `job_class` and `queue` for jobs, read from the execution context Rails passes to error subscribers.
- Keep the origin of library frames in backtraces (`gems/activerecord-8.1.4/lib/…`, `ruby/4.0.0/…`) so they can no longer pass for the application's own `lib/` files.
- Stop fingerprinting session settings and transaction control (`SET`, `SHOW`, `RESET`, `DISCARD`, `BEGIN`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`, `RELEASE`, `PRAGMA` and the like), so a per-query `SET LOCAL statement_timeout` no longer reads as an N+1. They still count toward `query_count`.

## 0.3.0 — 2026-10-10

- Enable bounded automatic endpoint sampling for routine successful requests, driven by expiring hosted policies. Preserve slow, failed, repeated-query requests and all other signal kinds from SDK sampling.
- Report eligible request selection and queue losses with immutable IDs and independent acknowledgments, including report-only batches at zero sampling rates. Keep old-server event delivery compatible until a v1 handshake.
- Add explicit local opt-out, effective request metadata, bounded control parsing, fork resets, and sampling diagnostics. Local opt-out does not disable server-side sampling or quotas.
- Separate known local drops from unconfirmed delivery; failed responses may follow partial server acceptance.

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
