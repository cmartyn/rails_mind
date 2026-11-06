# Customer SDK

The gem is `rails_mind`, namespace `RailsMind`. Install the MIT-licensed client
from RubyGems.org and commit the application lockfile to retain the selected
version. The hosted RailsMind service is a separate, proprietary application.
Version 0.4.0 is an early release with the [documented compatibility limits](compatibility.md).

## Install

```ruby
# Customer Gemfile
gem "rails_mind", "~> 0.4.0"
```

```sh
bundle install
bin/rails generate rails_mind:install --plan
bin/rails generate rails_mind:install
```

Then set `RAILS_MIND_KEY` ([configuration](#configuration-and-release-detection)) and, with
it in the app's environment, check the effective settings. Until the key is set,
doctor names it and exits non-zero.

```sh
bin/rails rails_mind:doctor
```

The plan inspects `Gemfile.lock` and prints selected versions, coexistence decisions, and missing options. Installation adds one initializer, preserves an existing initializer even with `--force`, and does not change migrations, dependencies, Flipper adapters, or OpenTelemetry providers. The doctor is read-only and does not contact the server or print credentials.

## Configuration and release detection

Set only the environment-scoped ingest key on the customer's server:

```sh
RAILS_MIND_KEY=<environment-scoped-credential>
```

The endpoint defaults to `https://railsmind.com`. To use a local or self-hosted
RailsMind instance, set `RAILS_MIND_ENDPOINT` (for example,
`http://127.0.0.1:3000`). An unset or whitespace-only override uses the hosted
default. HTTPS is required except for localhost/loopback development. The key
controls application/environment scope; never give it to browser JavaScript.
Collection stays off without a nonblank key. `apm`, `errors`, `analytics`, and
`flags` can each be disabled in the initializer. [Page views](#page-views) have
their own switches: `page_views`, `visitor_cookie` and `link_page_views_to_users`
(each `true` or `false`, on by default) and `ignore_page_view` (a callable that
receives the request). Switches are set in code, never read from the environment.

Release detection uses the first nonblank value in this order:

1. `RAILS_MIND_RELEASE` — optional explicit override.
2. `GIT_REVISION` — existing deployment convention.
3. `RENDER_GIT_COMMIT` — [Render's automatic runtime commit](https://render.com/docs/environment-variables).
4. `RAILWAY_GIT_COMMIT_SHA` — [Railway deployments triggered by GitHub](https://docs.railway.com/variables/reference).
5. `HEROKU_BUILD_COMMIT`, then `HEROKU_SLUG_COMMIT` — [Heroku dyno metadata](https://devcenter.heroku.com/articles/dyno-metadata); metadata features must be enabled, and the slug variable is deprecated.
6. `KAMAL_VERSION` — [Kamal's application-container version](https://github.com/basecamp/kamal/blob/master/lib/kamal/commands/app.rb), only when it is a full 40- or 64-character Git commit SHA.
7. The `REVISION` file inside `Rails.root` — for [Hatchbox deployments](https://jumpstartrails.com/discussions/appsignal-deploy-tracking) and other deployers that write this file.

Values are trimmed. The revision file is read once when configuration is created,
with a 500-byte limit; absent, blank, oversized, unreadable, or invalidly encoded
files are ignored. Detection does not run Git or inspect the working directory.
If no release is available, it remains unset and telemetry is still delivered.
Provider-specific metadata availability depends on the deployment type; there
is no universal runtime variable. Build-only and instance-specific IDs are not
used automatically. `HEROKU_RELEASE_VERSION`, arbitrary Kamal version labels,
and [Fly.io's `FLY_IMAGE_REF`](https://fly.io/docs/machines/runtime-environment/)
are also ignored: they can identify deployments or images rather than Git
revisions, while Assist uses releases to locate the corresponding code. Explicit
release overrides should identify a commit or ref in the connected repository. For DigitalOcean App Platform, commit metadata is a
[bindable value](https://docs.digitalocean.com/products/app-platform/how-to/use-environment-variables/),
not an automatically named runtime variable; optionally bind it to `GIT_REVISION`.

Explicit `config.endpoint` and `config.release` assignments still take precedence.
When upgrading an existing generated initializer, remove the old endpoint/release
assignments that directly read `ENV` so they do not overwrite the new defaults
with `nil` or bypass platform detection. The installer preserves existing files.
The doctor reports whether the effective endpoint, key, and release are present,
without printing credential values or contacting the server. While the key is
missing or the endpoint is blank, it names the setting after the report and
exits non-zero, as `rails_mind:verify` does.

## Verify the connection

From the customer app's server, using the same environment settings as the running app:

```sh
bin/rails rails_mind:verify
```

This sends one labeled installation check through the SDK's redaction, collector,
HTTP transport, and the normal ingestion queue. It prints a check ID and exits
successfully only when delivery is confirmed without drops. It has a ten-second
delivery deadline; a timeout can still mean the server received the check, so look
for its ID before retrying. Credentials are never printed. `before_send` may
suppress the check; changing its kind or ID is rejected. The optional signal
switches do not disable this explicitly requested check.

Open **Setup** in RailsMind, select the environment that owns the key, and match
the ID under **Latest installation check**. **Check processed** confirms the path
through the background worker. HTTP delivery alone does not confirm processing.
Then visit a page in your app and confirm **Recent telemetry** under app activity:
the command runs in its own process and cannot certify the configuration of an
already-running web or job process.

The check uses one event of the daily quota and expires with normal retention.
Its dedicated `check` signal carries the SDK version without customer identity,
trace, or release fields. It does not add business events, request measurements,
errors, or releases. Update the hosted app and run its migrations before using
this command with an older deployment that does not yet accept `check` signals.

Setup refreshes connection health every five seconds while visible, without
replacing unfinished setup forms. It shows active key use, first/latest retained
event arrival, processing backlog, and app activity. Arrival times come from the
server, so an old occurrence timestamp does not make a newly received event look
undelivered. A pending event older than two minutes needs investigation; app
traffic absent for fifteen minutes is shown as quiet, which may be normal.
Installation checks do not reset the app-activity clock. The panel reports the
environment's retained data, not lifetime history or SDK loss counters.

If a check fails, inspect the endpoint, active key, outbound HTTPS, and daily
quota. A delivered check missing from Setup may belong to a different environment.
If it remains pending, the RailsMind operator should inspect the telemetry worker
and failed jobs. Ingest keys remain write-only; viewing the confirmation requires
a signed-in workspace member.

## Identity and explicit outcomes

```ruby
# ApplicationController: a before_action inside the SDK request boundary.
RailsMind.identify(
  user_id: current_user&.id,
  account_id: current_account&.id
)

# Record an outcome after it commits, or inside an application after_commit.
RailsMind.track("Invoice paid", invoice_id: invoice.id, amount_cents: invoice.amount_cents)

# Explicit reporting also works when the current trace is not retained.
RailsMind.capture_exception(error, handled: true)
```

Context is fiber-local and restored around requests/jobs. `identify` sets the user and account IDs, so call it with both; passing nil or leaving one out clears it. It keeps the visitor ID the request already carries (from the [visitor cookie](#page-views)) unless you pass `visitor_id:`: a value replaces it and `nil` clears it. `identify` sends nothing by itself. Page views and `RailsMind.track` events carry the visitor ID and, once `identify` has run, the user and account IDs; RailsMind links a visitor to a user from any event that carries both, so that visitor's earlier anonymous page views join the user. Account IDs represent the current tenant, never a guessed company from email. Logout/account switching must update identity; a new request starts clean. The SDK does not rewrite or merge historical events.

ActiveJob serializes only the context identifier allowlist under `rails_mind_context`, then restores it while executing. Arguments are not inspected. This covers GoodJob through ActiveJob; direct Sidekiq jobs require a future explicit integration. Without OpenTelemetry, RailsMind creates a trace ID at a request, job, or mailer boundary and carries it across serialized ActiveJob context. An active OpenTelemetry span remains authoritative. Native IDs correlate observations; they do not invent a distributed parent/child span tree. Cross-service propagation belongs to the existing OpenTelemetry library; choose ActiveJob `propagation_style: :child` for a linked trace tree when configuring a new provider.

## Page views

With `analytics` and `page_views` on (the default), the SDK counts a page view
for each HTML page a controller renders for a person: a GET answered with a 2xx
`text/html` response. These are not counted:

- Turbo Frame requests, prefetches (`Sec-Purpose` or `X-Sec-Purpose: prefetch`)
  and XHRs;
- `Rails::` controllers (the `/up` health check included) and `ActiveStorage::`
  controllers;
- a blank or known-bot user agent (crawlers, link previews, LLM fetchers, uptime
  monitors and bare HTTP clients);
- anything your `ignore_page_view` hook returns true for. It receives the
  request; a hook that raises skips that page view.

```ruby
config.ignore_page_view = ->(request) { request.path.start_with?("/admin") }
```

A page view is a `pageview` event named `Controller#action`, with the trace and
request IDs of the request event for the same action. Its properties:

| Property | What it holds |
| --- | --- |
| `route` | The route pattern, such as `/posts/:id`, without `(.:format)` |
| `path` | The path and query string, with the app's `filter_parameters` applied (at most 1,000 characters) |
| `host` | The request's host |
| `referrer` | The referring URL's scheme, host and path; its query and fragment are not sent |
| `utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content`, `ref` | Those query parameters, at most 200 characters each |
| `user_agent` | The user agent, at most 500 characters; RailsMind derives device, browser and OS from it |
| `country` | Two letters from `CF-IPCountry` or `CloudFront-Viewer-Country`, when present |
| `visitor_id_kind` | `cookie` or `daily_hash` (below) |

The page view also carries the visitor ID and, once `identify` has run, the
user and account IDs. Set `config.link_page_views_to_users = false` to keep user
and account IDs off page views; other events still carry them. The IP address is
never sent. Every string goes through the same redaction as other events. Page
views are never sampled and count against the environment's daily quota.

### Visitor cookie

By default the SDK keeps a random visitor ID in a first-party cookie named
`_rails_mind_visitor`: a UUID, `path=/`, two years, `HttpOnly`, `SameSite=Lax`,
and `Secure` over HTTPS. Each counted page view sets or refreshes it, and a new
visitor's first page view already carries the ID that response sets. Every event
of the request, `RailsMind.track` calls and jobs enqueued there included, carries
the same ID, so an anonymous visit can lead to an outcome. A cookie value that is
not a UUID the SDK could have made is replaced.

A response marked `Cache-Control: public` never gets the cookie, so shared caches
keep working. Neither does a response from an `ActionController::Live`
controller, which sends its headers before the action ends. Their page views use
the visitor's cookie when they brought one, and otherwise the daily hash.

With `config.visitor_cookie = false`, no cookie is read or set. Page views, and
the other events of the same request, carry a daily hash instead: an HMAC of the
local date, the remote IP and the user agent, keyed from the app's
`secret_key_base` (never the ingest key) and cut to 32 hex characters. It changes
every day in the app's time zone, so a person who comes back the next day counts
as a new visitor. Without `secret_key_base` or a remote IP, page views carry no
visitor ID. Behind a proxy, set `config.action_dispatch.trusted_proxies` so
`request.remote_ip` is the visitor's address.

### Time zone

Every batch names the app's time zone (`config.time_zone` as an IANA name, so
Rails' default `UTC` is `Etc/UTC`) in the `X-RailsMind-Time-Zone` header, and
RailsMind counts days in that zone.

### Limits

- Turbo broadcast page refreshes (`broadcasts_refreshes`) reload a page the way
  a visit does, so each refresh counts as a page view in every open tab.
- Turbo 8 prefetches a link on hover (`X-Sec-Purpose: prefetch`) and, when the
  link is clicked, shows that prefetched response without asking the app again.
  Prefetches are not counted, so a page opened that way is not counted either.
  Add `<meta name="turbo-prefetch" content="false">` to the layout to count
  those visits.
- Pages served from a CDN or a browser cache never reach the app and are not
  counted. A `304 Not Modified` from `Rack::ConditionalGet` still counts.
- Bot filtering is a built-in user-agent list. Add your own rules with
  `ignore_page_view`.
- Page views come on top of request events, so HTML traffic sends more events
  than before; both share the collector's queue and the daily quota.

## Coming from Ahoy

Version 0.4.0 removed the Ahoy integration (`AhoyStore`, `mirror_ahoy!`) and
the Ahoy-based browser adapter. RailsMind counts [page views](#page-views)
itself and no longer receives `$visit`, `$view`, `$pageview`, `$frame_view` or
`$identify`. Before upgrading, delete `require "rails_mind/integrations/ahoy"`
and `RailsMind::Integrations.mirror_ahoy!`; the require now fails at boot.

- `ahoy.track("Invoice paid", ...)` becomes `RailsMind.track("Invoice paid", ...)`,
  called after the outcome commits. Keep the `ahoy.track` call too if your own
  Ahoy reports use it.
- Ahoy's `authenticate(user)` becomes `RailsMind.identify(user_id:, account_id:)`.
  Stop passing `visitor_id: ahoy.visitor_token`, so page views and events carry
  the RailsMind visitor cookie.
- A hosted-only `class Ahoy::Store < RailsMind::Integrations::AhoyStore` goes.
  Remove `ahoy_matey` too, or define `class Ahoy::Store < Ahoy::BaseStore; end`,
  because Ahoy needs an `Ahoy::Store`.
- Delete the copied `app/javascript/rails_mind.js`, its importmap pin, any asset
  path into the gem, and the `rails-mind-page` meta tag. Custom events sent from
  the browser are no longer supported; record them on the server with
  `RailsMind.track`.

Ahoy itself keeps working for your own reports; RailsMind no longer reads it.

## OpenTelemetry

Use selected tracing libraries, not `use_all`. The locally verified setup uses
Rack, ActionPack, ActionView, ActiveJob, PG, and Net::HTTP, with PG configured as
`db_statement: :omit`. Avoid additionally instrumenting the same SQL operation
at both ActiveRecord and PG layers. The Rails aggregate instrumentation package
loads component libraries; selecting only the Rails package itself does not
activate the child integrations. Follow the public
[Ruby instrumentation guide](https://opentelemetry.io/docs/languages/ruby/instrumentation/)
and [PG instrumentation documentation](https://github.com/open-telemetry/opentelemetry-ruby-contrib/tree/main/instrumentation/pg)
for your application's setup.

An existing provider remains authoritative:

```ruby
# Run after your existing OpenTelemetry::SDK.configure block.
require "rails_mind/integrations/open_telemetry"
RailsMind::Integrations::OpenTelemetry.attach!
```

Attachment adds one idempotent processor; it does not replace the global provider, sampler, propagator, instrumentation, or other exporters. Its exporter only sanitizes and enqueues locally; the shared worker performs network I/O. Span context is attached at start so identity survives later export. Known safe attributes are allowlisted. Raw span names, exception span events, HTTP bodies/headers, SQL statements, and bind values are not exported to RailsMind. Existing third-party exporters retain their own behavior and privacy settings. [OpenTelemetry exporters](https://opentelemetry.io/docs/languages/ruby/exporters/).

Request measurements and error reports come independently from Rails notifications/error reporting, even when detailed traces are sampled out. Routine requests separately follow the automatic endpoint sampling policy described below. Request measurements cover controller actions, not assets/health checks rejected before ActionController or streaming-body completion. Repeated-query evidence contains normalized-query hashes and counts, plus the shape of each query that repeated: the normalized SQL with string and numeric literals replaced by `?`, comments removed, and at most 400 characters. Set `config.capture_query_shapes = false` to send hashes only. Session settings and transaction control (`SET`, `SHOW`, `BEGIN`, `COMMIT`, `SAVEPOINT` and the like) count toward `query_count` but are never fingerprinted. It is a suspicion, not proof of an N+1. Normalization handles common literals, not every SQL grammar. Use Bullet/Prosopite or an explicit query-bound test in development to verify fixes. No production object scans are installed.

Full metrics/logs SDK integration is deferred. Hosted request aggregates describe retained events; sampling can bias their distributions. The SDK does not capture application logs.

## Automatic endpoint sampling

Version 0.3.0 enables automatic endpoint sampling by default. A compatible hosted
service supplies environment-wide endpoint rates based on its allowance policy.
The SDK applies them before queueing, reducing serialization, network, and retained
event volume. Each process uses the same policy and deterministic event-ID hash;
there are no independent per-process allowance grants. A server-side tightening
uses the same selection rule, so the two samplers do not multiply probabilities.

Only completed `request` events with status 200–399, a finite duration from zero
to below 1,000 ms, and fewer than three repeated queries are eligible. Slow,
failed, unknown-duration, and repeated-query requests remain unsampled, as do
business events, page views, errors, jobs, mailer observations, flags, checks,
and OpenTelemetry spans. This preserves their sampling priority, not guaranteed
delivery: queue bounds, payload limits, outages, and the server's hard daily quota
still apply. Existing OpenTelemetry samplers remain authoritative; this feature
does not promise complete distributed traces.

To turn off SDK request selection explicitly:

```ruby
RailsMind.configure do |config|
  config.automatic_sampling = false
end
```

The SDK communicates this choice on policy and ingestion requests. The
environment owner's hosted setting separately controls server-side sampling;
local opt-out does **not** disable it or bypass the daily quota.

The background worker requests `/api/v1/sampling_policy` with the ingest key and
refreshes at most once per minute after its first request observation, including
when the current rate is zero. It also receives controls on successful ingestion
and quota responses. Missing, malformed, or expired policies fall back to rate 1;
this may exhaust the server allowance during an outage. Expiry uses wall and
monotonic clocks, with a maximum accepted lifetime of ten minutes. Before a valid
v1 handshake, old servers and custom transports receive ordinary event-only
batches and retain normal flush behavior. Forked workers reset queues, policies,
counters, and report IDs and fetch their own copy of the shared policy.

Retained request properties include SDK-owned `rails_mind_sampling` metadata:
`version`, `policy_id`, effective `rate`, and `state` (`active`, `unavailable`,
`expired`, `disabled`, or `protected`). This is the SDK selection decision, not
proof of server acceptance or a complete traffic denominator.

At most once per minute per process, the worker freezes an identified report of
routine eligible observations; an explicit flush may send it sooner. Reports
contain controller/action names and counts only: `observed`, `retained` (selected
for enqueue), `sampled_out`, and `queue_dropped` (a subset of retained). They never
contain event properties or user/account identifiers. Counts are observed after
validation, redaction, and `before_send`; hooks that suppress events, crashes,
protected requests, and unknown endpoint names are outside this denominator.
Retained counts are not accepted counts. The resulting request percentiles and
rates cannot be treated as an unbiased whole-traffic distribution.

Reports have immutable UUIDs/bodies and separate durable acknowledgments. They
can travel in `events: []` batches without consuming event quota, and an
acknowledged report does not establish delivery of its accompanying events.
Counters cover at most 100 endpoint names per window, reports share the normal
batch byte limit, and each process retains at most five unacknowledged reports.
Overflows or invalid clock windows mark coverage `limited`; reports older than
seven days are discarded. This is bounded in-memory observation, not a durable
request ledger. Unacknowledged reports after a confirmed handshake can cause
`RailsMind.flush` to return false at its deadline.

## Jobs and mailer workflows

With `apm` enabled, the SDK automatically observes installed ActiveJob and Action
Mailer components. No SMTP-provider integration or OpenTelemetry setup is required.
It does not change the queue adapter, delivery provider, retry policy, or error
handling. Both integrations respect `RailsMind.suppress` and the normal collector
bounds. Request, job, and mailer identity/release context uses the existing core
fields; job arguments and email contents are never inspected for correlation.

The versioned property contract is `schema_version: 1` with `instrumentation`
equal to `active_job` or `action_mailer`:

| Component | Observations | Selected metadata |
| --- | --- | --- |
| ActiveJob | `enqueue`, `enqueue_at`, `perform_start`, `perform`, `enqueue_retry`, `retry_stopped`, `discard` | Class, queue, execution count, enqueue/schedule timestamps, queue delays |
| Action Mailer | `process`, `delivery_attempt_completed`, `delivery_not_observed` | Mailer/action, opaque attempt UUID when available, transport class, ordinary/forced invocation, delivery flags, exposed exception class |

New enqueue/start and mailer observations use `span`, so they do not inflate
business-event counts or the existing `job` execution/retry/discard feed. A
render-only mailer has a processing observation, not a delivery attempt. The
attempt UUID groups processing with its delivery invocation; retries create new
attempt UUIDs while the serialized job retains its correlation identifiers.

`queue_delay_ms` measures enqueue to execution start, including intentional
scheduling. `eligible_queue_delay_ms` subtracts intentional scheduling when the
required timestamps are available, with a zero floor. Missing timestamps remain
unknown. Retry handlers keep execution context after normal perform callbacks
unwind. These notifications are best-effort observations, not a durable queue
ledger: bulk/direct backend APIs may bypass them, and a missing completion does
not by itself prove a stuck job.

Mailer status describes local evidence. `observed` means the local call or
notification completed; `disabled` identifies ordinary delivery with
`perform_deliveries: false`; `error` requires an exposed exception. A callback
abort or other invocation that never reaches the transport is recorded as
`delivery_not_observed`, with `aborted`, `error`, or `unknown` as appropriate.
Forced delivery bypasses normal delivery flags and is observed separately.
Hidden transport failures (`raise_delivery_errors: false`) can still produce an
`observed` result. None of these establishes provider acceptance or inbox
arrival; recipient delivery remains unknown.

The SDK excludes recipients, sender addresses, subjects, bodies, attachments,
message IDs/headers, mailer/job arguments, credentials, and provider responses.
Only transport class names are selected, never transport settings. Rendering a
mailer and sending its content through a separate HTTP provider client produces
only the rendering evidence; add explicit reviewed app events or provider
callbacks if later delivery facts are needed. Keep real product outcomes such
as invitation acceptance separate, using explicit events after persistence.


## Flipper

The SDK subscribes to `feature_operation.flipper`. It observes names, operations, boolean results, and duration without changing adapters, groups, actors, rollout logic, or cache. Flipper's existing Rails instrumentation emits these events; applications with a custom instrumenter must deliberately opt into ActiveSupport notifications. Actor IDs are not collected. An evaluation is not experiment exposure. Managed flags and experiments are not implemented in this SDK. [Flipper instrumentation](https://www.flippercloud.io/docs/instrumentation).

## Bounds, privacy, and outages

Defaults are one lazy worker per process, 1,000 queued/in-flight events, 16 KiB per event, at most 100 events and 256 KiB per batch, and a two-second flush interval. Overflow drops the newest event. Retries retain the same encoded bytes/UUIDs; only HTTP 429, 5xx, and transient transport failures retry, at most three retries with bounded backoff. Other 4xx responses end delivery attempts. A failed response can follow partial server acceptance, so such events are classified as delivery unconfirmed. Redirects are not followed. Shutdown gets two seconds by default, then discards outstanding telemetry; forks start a fresh child queue rather than resending the parent's buffer.

```ruby
RailsMind.stats
# => { enqueued:, delivered:, dropped:, delivery_unconfirmed:, retried:, queued:, in_flight:,
#      losses: { "event.overflow" => 3, "error.delivery_unconfirmed" => 1 },
#      sampling: { observed:, retained:, sampled_out:, queue_dropped:,
#                  unreported:, reports_lost:, pending_reports:, limited:, policy_state:, policy_id: } }
RailsMind.flush(timeout: 2)
```

These are per-process counters. `dropped` counts known local discards, such as queue overflow or oversize payloads. `delivery_unconfirmed` counts events whose delivery attempts ended without a success response, including interrupted in-flight batches; some may have been accepted by the server. `delivered` counts submitted events in batches with a successful HTTP response; it does not prove server retention or background processing. The doctor prints stats for its process; inspect running app stats through your existing operational tooling. Only the routine-request report above sends queue-loss observations to the hosted app. All signal kinds can still undercount after crashes, rejected payloads, hooks, or outages. This is best-effort monitoring, not an accounting ledger; use a transactional outbox when durable business-event delivery is required.

Redaction occurs before buffering and again after custom `before_send`. Sensitive property names are filtered, nesting/string/collection sizes are capped, emails and common credential forms are scrubbed (exception messages included), and backtraces drop machine-home prefixes while keeping a `gems/<name>-<version>/` or `ruby/<version>/` origin for library frames. Error events also name where they happened: `role`, plus the controller action as `route` or the job's `job_class` and `queue`. Bodies, cookies (other than the SDK's own visitor cookie), credentials, SQL binds, and job arguments are never selected by integrations. Arbitrary user-provided text may contain sensitive content that generic redaction cannot recognize: use small, explicitly reviewed business properties. Exception messages can contain whatever your code interpolated into them; review your scrubbing policy, or set `config.capture_exception_message = false` to replace every message with a placeholder before it leaves.

The final local synthetic burst benchmark on Ruby 4.0.6 processed 10,000 calls in 1.7612 seconds (176.12 μs/call), delivering all 10,000 with zero drops/retries at the 1,000-event queue bound. This measures local sanitization/enqueue with a no-op transport, not production request overhead or network delivery. Earlier runs did overflow; thread scheduling and downstream speed affect the result. Deterministic tests separately verify overflow losses and bounded shutdown during a hung transport. Run `ruby script_benchmark.rb` on the deployment hardware before setting a production budget.

## Verified local pipeline

On 2026-09-14 the real sample Rails application sent 101 events through this SDK's HTTP transport to the local hosted ingestion API; GoodJob processed all 101. They included 90 spans, 3 requests, 3 business events, 2 Flipper observations, 1 visit, 1 error, and 1 job. There were no collector drops or retries. The intentional error shared its request's trace and account IDs. Every request/business/error/flag/job event had account context; the visit and some early spans preceded identity and therefore did not. The list reported seven repeated queries. Credential-key privacy probes arrived as `[FILTERED]` without their secret values.

This historical check used an internal sample application that is not included
in the public client repository. To verify your own installation, follow
[Verify the connection](#verify-the-connection). External hosted deployment and
published-gem installation remain unverified by that historical check.

## Connect your coding agent

Run `bin/rails generate rails_mind:agent --plan` to preview the connection setup.
The [agent guide](agents.md) covers Claude Code and Codex, environment-variable and
Rails credentials authentication, safe verification, and the complete fix journey.
The agent API token is separate from `RAILS_MIND_KEY`, the ingestion key above.
