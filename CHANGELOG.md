# Changelog

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
