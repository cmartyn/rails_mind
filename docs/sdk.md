# Customer SDK

The prototype gem is `rails_mind`, namespace `RailsMind`. It is not published. Install from the private [SDK repository](https://github.com/cmartyn/rails_mind) while evaluating it. Your Git credentials need access; commit the application lockfile to retain the selected revision.

## Install

```ruby
# Customer Gemfile
gem "rails_mind", git: "https://github.com/cmartyn/rails_mind.git", branch: "main"
```

```sh
bundle install
bin/rails generate rails_mind:install --plan
bin/rails generate rails_mind:install
bin/rails rails_mind:doctor
```

The plan inspects `Gemfile.lock` and prints selected versions, coexistence decisions, and missing options. Installation adds one initializer, preserves an existing initializer even with `--force`, and does not change migrations, dependencies, Ahoy stores, Flipper adapters, or OpenTelemetry providers. The doctor is read-only and does not contact the server or print credentials.

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
`flags` can each be disabled in the initializer.

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
without printing credential values or contacting the server.

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
  visitor_id: ahoy.visitor_token,
  user_id: current_user&.id,
  account_id: current_account&.id
)

# Record an outcome after it commits, or inside an application after_commit.
RailsMind.track("Invoice paid", invoice_id: invoice.id, amount_cents: invoice.amount_cents)

# Explicit reporting also works when the current trace is not retained.
RailsMind.capture_exception(error, handled: true)
```

Context is fiber-local and restored around requests/jobs. `identify` replaces the three identity values, so call it with all available values; passing nil clears that value. Preserve Ahoy's visitor ID when a visitor logs in, and emit `$identify` through Ahoy authentication to connect later events. Account IDs represent the current tenant, never a guessed company from email. Logout/account switching must update identity; a new request starts clean. Historical anonymous events are not rewritten or merged across accounts by the SDK.

ActiveJob serializes only the context identifier allowlist under `rails_mind_context`, then restores it while executing. Arguments are not inspected. This covers GoodJob through ActiveJob; direct Sidekiq jobs require a future explicit integration. Distributed trace propagation belongs to the existing OpenTelemetry library; choose ActiveJob `propagation_style: :child` for a linked trace tree when configuring a new provider.

## Ahoy

Ahoy's documented store extension points preserve existing `ahoy.track` calls. Choose one mode explicitly. [Ahoy custom stores](https://github.com/ankane/ahoy#data-stores).

For an established installation, keep the current `Ahoy::Store` definition, storage, ID generator, user method, and cookies, then add this after its configuration:

```ruby
require "rails_mind/integrations/ahoy"
RailsMind::Integrations.mirror_ahoy!(Ahoy::Store)
```

The existing store runs first with its original hash. Its return value and exceptions survive. RailsMind then mirrors visits/events/authentication without modifying the data. Repeated installation does not add another wrapper. Existing event IDs remain stable on transport retries; non-UUID Ahoy IDs map deterministically into UUIDv8 values.

For a new hosted-only installation:

```ruby
require "rails_mind/integrations/ahoy"
Ahoy.api = true # Only when using the optional browser adapter.
Ahoy.geocode = false
class Ahoy::Store < RailsMind::Integrations::AhoyStore
end
```

This store requires no growing analytics tables. It does not offer database-backed `Ahoy::Visit` objects, `visitable` associations, geocoding storage, historical import, or cookie-free persisted visit lookup. Applications using those behaviors should keep their current store and mirror. Disable an existing duplicate pageview handler only as a deliberate customer configuration change.

## OpenTelemetry

Use selected tracing libraries, not `use_all`. For a new setup, see the [sample initializer](https://github.com/cmartyn/mind/blob/main/sample/config/initializers/opentelemetry.rb): Rack, ActionPack, ActionView, ActiveJob, PG, and Net::HTTP. PG is configured with `db_statement: :omit`. Avoid additionally instrumenting the same SQL operation at both ActiveRecord and PG layers. The Rails aggregate instrumentation package loads component libraries; selecting only the Rails package itself does not activate the child integrations. [Ruby instrumentation](https://opentelemetry.io/docs/languages/ruby/instrumentation/), [PG instrumentation source](https://github.com/open-telemetry/opentelemetry-ruby-contrib/tree/main/instrumentation/pg).

An existing provider remains authoritative:

```ruby
# Run after your existing OpenTelemetry::SDK.configure block.
require "rails_mind/integrations/open_telemetry"
RailsMind::Integrations::OpenTelemetry.attach!
```

Attachment adds one idempotent processor; it does not replace the global provider, sampler, propagator, instrumentation, or other exporters. Its exporter only sanitizes and enqueues locally; the shared worker performs network I/O. Span context is attached at start so identity survives later export. Known safe attributes are allowlisted. Raw span names, exception span events, HTTP bodies/headers, SQL statements, and bind values are not exported to RailsMind. Existing third-party exporters retain their own behavior and privacy settings. [OpenTelemetry exporters](https://opentelemetry.io/docs/languages/ruby/exporters/).

Request durations/counts and error reports come independently from Rails notifications/error reporting, even when detailed traces are sampled out. Request measurements cover controller actions, not assets/health checks rejected before ActionController or streaming-body completion. Repeated-query evidence contains only normalized-query hashes and counts; it is a suspicion, not proof of an N+1. Hash normalization handles common literals, not every SQL grammar. Use Bullet/Prosopite or an explicit query-bound test in development to verify fixes. No production object scans are installed.

Jobs record duration, failure/retry/discard lifecycle, execution count, queue name, and enqueue-to-start delay where ActiveJob exposes it. Scheduled delay is included in the enqueue-to-start number. Signals do not include arguments. Full metrics/logs SDK integration is deferred; v0.1 computes hosted aggregates from unsampled request events and does not capture application logs.

## Flipper and browser behavior

The SDK subscribes to `feature_operation.flipper`. It observes names, operations, boolean results, and duration without changing adapters, groups, actors, rollout logic, or cache. Flipper's existing Rails instrumentation emits these events; applications with a custom instrumenter must deliberately opt into ActiveSupport notifications. Actor IDs are not collected. An evaluation is not experiment exposure. Managed flags and experiments are not implemented in this SDK. [Flipper instrumentation](https://www.flippercloud.io/docs/instrumentation).

Run `bin/rails generate rails_mind:install --browser` to copy the optional module. Importmap users pin it, then pass their existing Ahoy instance:

```javascript
import ahoy from "ahoy"
import { start } from "rails_mind"
const analytics = start({ ahoy, frames: true })
```

Add `<meta name="rails-mind-page" content="Invoices#index">` to supply a stable page label. The adapter transmits no URL or query string. It counts the initial page and each completed Turbo visit once, ignores cached preview renders, and keeps `turbo:frame-load` as a separate `$frame_view` only for Frames with `data-analytics-frame`. It does not infer payment/signup success from forms or HTTP responses. Set `pageviews: false` if the application already counts pageviews. Repeated installation returns the same adapter. Browser delivery uses Ahoy's same-origin endpoint/cookies and existing CSRF policy; there is no browser ingestion credential. [Turbo events](https://turbo.hotwired.dev/reference/events).

## Bounds, privacy, and outages

Defaults are one lazy worker per process, 1,000 queued/in-flight events, 16 KiB per event, at most 100 events and 256 KiB per batch, and a two-second flush interval. Overflow drops the newest event. Retries retain the same encoded bytes/UUIDs; only HTTP 429, 5xx, and transient transport failures retry, at most three retries with bounded backoff. Other 4xx responses drop the batch. Redirects are not followed. Shutdown gets two seconds by default, then discards outstanding telemetry; forks start a fresh child queue rather than resending the parent's buffer.

```ruby
RailsMind.stats
# => { enqueued:, delivered:, dropped:, retried:, queued:, in_flight:,
#      losses: { "event.overflow" => 3, "error.delivery" => 1 } }
RailsMind.flush(timeout: 2)
```

These are per-process counters. The doctor prints them for its process; inspect running app stats through your existing operational tooling. The hosted app does not currently receive loss counters. Request/business/error signals are unsampled, but process crashes, rejected payloads, redaction hooks, exhausted retries, or queue pressure can still undercount. This is best-effort monitoring, not an accounting ledger. A future transactional outbox can provide durable business-event delivery; the current implementation does not claim that guarantee.

Redaction occurs before buffering and again after custom `before_send`. Sensitive property names are filtered, nesting/string/collection sizes are capped, emails and common credential forms are scrubbed, exception messages are omitted by default, and backtraces drop machine-home prefixes. Bodies, cookies, credentials, SQL binds, and job arguments are never selected by integrations. Arbitrary user-provided text may contain sensitive content that generic redaction cannot recognize: use small, explicitly reviewed business properties. Opting into exception messages requires reviewing `capture_exception_message` and your custom scrubbing policy.

The final local synthetic burst benchmark on Ruby 4.0.6 processed 10,000 calls in 1.7612 seconds (176.12 μs/call), delivering all 10,000 with zero drops/retries at the 1,000-event queue bound. This measures local sanitization/enqueue with a no-op transport, not production request overhead or network delivery. Earlier runs did overflow; thread scheduling and downstream speed affect the result. Deterministic tests separately verify overflow losses and bounded shutdown during a hung transport. Run `ruby script_benchmark.rb` on the deployment hardware before setting a production budget.

## Verified local pipeline

On 2026-09-14 the real sample Rails application sent 101 events through this SDK's HTTP transport to the local hosted ingestion API; GoodJob processed all 101. They included 90 spans, 3 requests, 3 business events, 2 Flipper observations, 1 visit, 1 error, and 1 job. There were no collector drops or retries. The intentional error shared its request's trace and account IDs. Every request/business/error/flag/job event had account context; the visit and some early spans preceded identity and therefore did not. The list reported seven repeated queries. Credential-key privacy probes arrived as `[FILTERED]` without their secret values.

The verification script is in the separate [sample app](https://github.com/cmartyn/mind/blob/main/sample/script/verify_delivery.rb); it reads a key from `RAILS_MIND_KEY_FILE`, sends only to the configured endpoint, prints no credential, and marks events with a `sample-verification-*` release. External hosted deployment and published-gem installation remain unverified.
