# Changelog

## 0.4.0 — 2026-11-06

Breaking: the Ahoy integration and the Ahoy-based browser adapter are gone. RailsMind counts page views itself. An app that keeps Ahoy for its own reports keeps it unchanged.

- Removed `RailsMind::Integrations::AhoyStore`, `AhoyMirror` and `RailsMind::Integrations.mirror_ahoy!`. `require "rails_mind/integrations/ahoy"` now raises `LoadError`, so delete that require and the `mirror_ahoy!` call before upgrading or the app fails at boot. `rails_mind:doctor` names them when it finds `ahoy_matey`.
- Removed the browser adapter (`javascript/rails_mind.js`) and `rails_mind:install --browser`; the option is now ignored. Delete the copied `app/javascript/rails_mind.js`, its importmap pin, any asset path into the gem and the `rails-mind-page` meta tag. Custom events sent from the browser are no longer supported; record them on the server.
- RailsMind no longer receives `$visit`, `$view`, `$pageview`, `$frame_view` or `$identify`.
- Migrating: `ahoy.track("Invoice paid", ...)` becomes `RailsMind.track("Invoice paid", ...)`, called after the outcome commits. Ahoy's `authenticate(user)` becomes `RailsMind.identify(user_id:, account_id:)`; stop passing `visitor_id: ahoy.visitor_token`. A hosted-only `Ahoy::Store < RailsMind::Integrations::AhoyStore` goes: remove `ahoy_matey` too, or define `class Ahoy::Store < Ahoy::BaseStore; end`. Keep any `ahoy.track` and `ahoy.authenticate` calls your own Ahoy reports need.
- A Gemfile pin of `~> 0.3.x` does not allow 0.4.0. 0.4.0 needs a RailsMind server that accepts the `pageview` kind; an older one rejects every batch that contains a page view.

Page views:

- Count a page view, a new `pageview` event named `Controller#action`, for each HTML page a controller renders for a person: a GET answered with a 2xx `text/html` response that is not a Turbo Frame request, a prefetch (`Sec-Purpose` or `X-Sec-Purpose`), an XHR, a `Rails::` or `ActiveStorage::` controller (the `/up` health check included), or from a blank or known-bot user agent. Page views share the request event's trace and request IDs and are never sampled.
- Each carries the route pattern, the path and query with the app's `filter_parameters` applied, the host, the referrer's scheme, host and path (never its query), the `utm_*` and `ref` query parameters, the user agent, the country from `CF-IPCountry` or `CloudFront-Viewer-Country`, and which kind of visitor ID it has. Every string is capped. The IP address is never sent.
- Keep a random visitor ID in a first-party cookie, `_rails_mind_visitor` (a UUID, two years, `HttpOnly`, `SameSite=Lax`, `Secure` over HTTPS), set or refreshed on counted page views and never on a `Cache-Control: public` response. Every event of the request, `RailsMind.track` calls and enqueued jobs included, carries the same ID, so an anonymous visit can lead to an outcome. A value that is not a UUID is replaced. `config.visitor_cookie = false` reads and sets no cookie and uses a daily hash instead: an HMAC of the local date, IP and user agent keyed from `secret_key_base`, which changes every day.
- Link visitors to users: page views carry the user and account IDs `identify` set, and `identify` now keeps the request's visitor ID when `visitor_id:` is not passed (passing it still replaces it, and `nil` clears it). `identify` still sends nothing itself; RailsMind links a visitor to a user from any event carrying both. `config.link_page_views_to_users = false` keeps user and account IDs off page views.
- Name the app's time zone (`config.time_zone` as an IANA name, `Etc/UTC` by default) in an `X-RailsMind-Time-Zone` header on every batch, so RailsMind counts days in it.
- New switches, set in code and never read from the environment: `config.page_views`, `config.visitor_cookie`, `config.link_page_views_to_users` (each `true` by default and validated as a boolean) and `config.ignore_page_view`, a callable that receives the request and skips the page view when it returns true or raises. `rails_mind:doctor` reports the three switches.
- Known limit: Turbo broadcast page refreshes reload a page the way a visit does, so each refresh counts as a page view in every open tab.

## 0.3.2 — 2026-10-13

Security fix for the scrubbing 0.3.1 turned on by default. Upgrade from 0.3.1.

- An `Authorization` header in a message or string (`Bearer`, `Basic`, `Token` and other schemes; any case; `:`, `=` or `=>`; quoted, unquoted or wrapped in an array as `Net::HTTP#to_hash` prints it; `Proxy-Authorization` too) loses its credential. A `Digest` or `AWS4-HMAC-SHA256` header loses its whole value. 0.3.1 replaced only the scheme word and sent the credential after it.
- Userinfo goes from a URL of any scheme (`redis://:password@`, `rediss://`, `amqp://`, `postgres://`, `mysql2://`, `mongodb+srv://` and others), not only `http(s)://`, up to the last `@` before the path, so an unencoded `@` in a password leaves nothing behind.
- Provider credentials go without a key word next to them: GitHub tokens (`ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_`), AWS access key IDs (`AKIA`, `ASIA`), Stripe secret and restricted keys (`sk_live_`, `sk_test_`, `rk_…`), Slack tokens (`xox…-`), `sk-` API keys and JWTs.
- Card numbers (13 to 19 digits, grouped by spaces or dashes or not, passing the Luhn check, also next to an expiry or another number) and US social security numbers (`123-45-6789`) go from free text: messages, backtraces, event names and properties. Identity, correlation and release values (`user_id`, `account_id`, `visitor_id`, `request_id`, `release` and the like) are left alone, so a numeric account ID is never mistaken for a card. In printed hashes, `phone` and `ssn` values go too.
- Scrubbing reads at most 8 KB of a string, cut at whitespace, and every pass is linear, so a hostile message cannot stall the request that raised it. What is sent is still at most 1024 characters.
- A PostgreSQL literal ending in a backslash no longer lets the next literal through, in query shapes or database error messages. Rails runs PostgreSQL with `standard_conforming_strings`, where `\` escapes a quote only inside `E'…'`, while MySQL lets it escape one; a statement or message containing a backslash is now read both ways and anything either reading takes for a literal goes. Statements without a backslash keep their fingerprints; one with an ambiguous `\'` keeps its text only up to that literal, so its fingerprint changes.
- Tests: an adversarial corpus of these inputs that no secret may survive, as a message, an event property or a query shape.
- `rails_mind:doctor` now exits 1 and names `RAILS_MIND_KEY` or the endpoint when collection would be off.

## 0.3.1 — 2026-10-11

- Send exception messages by default, scrubbed like every other string (emails, credentials, URL queries), and further for what generic scrubbing misses: database errors lose the failing row, key values, rejected input and quoted SQL literals, and printed hashes or keyword arguments lose the values of sensitive keys. `config.capture_exception_message = false` restores the placeholder. The flag is still not validated, so an app that assigned it from ENV boots as before.
- Send the shape of each repeated query next to its fingerprint: the normalized SQL with literals replaced by `?`, comments removed, and at most 400 characters and 900 bytes, only for fingerprints that repeated within the request. One pass handles doubled and backslash-escaped quotes, `E''` and `$$` strings, hex numbers, comments containing quotes, a literal left open where a long statement is cut, and MySQL's double-quoted strings. `config.capture_query_shapes = false` sends fingerprints only.
- Strip SQL comments (query log tags, Marginalia) before fingerprinting, so a query tagged per request keeps one fingerprint.
- Name where each exception happened: `role` (`web`, `job`, `runner` or `console`), with the controller action as `route` for requests and `job_class` and `queue` for jobs, including unhandled job failures.
- Keep the origin of library frames in backtraces (`gems/activerecord-8.1.4/lib/…`, `ruby/4.0.0/…`, `ruby/vendor_ruby/…`) so they can no longer pass for the application's own `lib/` files; an application directory that happens to be called `gems/` stays the application's.
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
