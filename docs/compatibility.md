# Compatibility and dependency decisions

Verified on 2026-09-14. Version numbers come from RubyGems release metadata and the actual installed libraries used in tests. The initial promise is narrow: coexistence with current versions, not importing historical data or replacing existing services.

| Foundation | Verified version / license | Current coverage |
| --- | --- | --- |
| Ruby / Rails | 4.0.6 / 8.1.3.1; Ruby / MIT | Real Rails sample and notification/error/ActiveJob tests. Gem allows Ruby ≥3.3, Rails ≥7.2 and <9; older combinations are candidates, not yet certified. |
| Ahoy | [5.5.0, MIT](https://rubygems.org/gems/ahoy_matey) | Actual custom store and mirror tests; default store data/return value preserved; stable IDs; no hosted-only analytics tables. |
| Flipper | [1.4.2, MIT](https://rubygems.org/gems/flipper) | Actual group targeting and adapter identity preserved; ActiveSupport observation only. No managed flag mode. |
| OpenTelemetry SDK | [1.13.0, Apache-2.0](https://rubygems.org/gems/opentelemetry-sdk) | Existing exporter/provider and sampler coexistence tested; sampled-out traces do not suppress errors/business events. |
| OTel Rails components | [0.42.0 aggregate, Apache-2.0](https://rubygems.org/gems/opentelemetry-instrumentation-rails) | Sample selects Rack 0.31.1, ActionPack 0.18.1, ActionView 0.13.0, ActiveJob 0.13.0. Request/SQL/job telemetry through actual libraries. |
| OTel PG / Net::HTTP | [0.37.0](https://rubygems.org/gems/opentelemetry-instrumentation-pg) / [0.29.0](https://rubygems.org/gems/opentelemetry-instrumentation-net_http), Apache-2.0 | PG statements omitted; exporter allowlist discards raw SQL/HTTP payloads. Net::HTTP auto-instrumentation installed in the sample; external HTTP service interaction not required for the demo. |
| GoodJob | [4.19.2, MIT](https://rubygems.org/gems/good_job) | Hosted/sample backend; ActiveJob context integration. Sample uses inline execution, so multi-process GoodJob queue/retry behavior needs staging verification. |
| Turbo | [turbo-rails 2.0.23, MIT](https://rubygems.org/gems/turbo-rails) | Browser adapter contract tests and a real Chromium navigation check cover visits, cached previews, back/forward restoration, Frames, repeat installation, late start, and explicit events. See the release verification below for scope. |
| Other error reporters | Rails error interface; no mandatory SDK | Subscriber coexistence tested with a second subscriber. Sentry/Honeybadger/Bugsnag/Rollbar detection only; no vendor-specific version certification. |
| Sidekiq, Solid Queue, Delayed Job | Detection only | ActiveJob jobs inherit the shared integration when used through Rails; backend-specific APIs/direct jobs are not covered. |
| Bullet / Prosopite | Optional, deferred dependency | Use in development/isolated reproduction. No automatic production scans or forks. |
| Field Test | Optional, deferred dependency | Detect installed version; no assignment/exposure/import or experiment analysis in this release. |

Current Ahoy 5.5 and OTel 1.13 require Ruby ≥3.3. No integration gems are mandatory at SDK runtime beyond Rails and Net::HTTP. Customers select optional dependencies; the installer does not silently add them. MIT/Apache licenses allow this extension strategy without maintaining forks.

The preferred foundations remain suitable for the pilot. Ahoy's store model provides a supported buffered-delivery seam but its database associations do not exist in hosted-only mode. Flipper's authoritative configuration remains in the customer's existing adapter; managed flags need an explicit future mode. OTel Ruby tracing supplies the useful mature signal here; broad metrics/logs/exporter parity is deliberately outside this prototype. [Ahoy store contract](https://github.com/ankane/ahoy#data-stores), [Flipper observation contract](https://www.flippercloud.io/docs/instrumentation), [OpenTelemetry Ruby](https://opentelemetry.io/docs/languages/ruby/).

Tests are in `test` and browser lifecycle tests in `javascript`. Historical
end-to-end Rails checks used a separate internal sample application that is not
part of this public repository. Re-run the matrix when bumping dependencies.
No external telemetry service, vendor account, historical migration, production
overhead budget, or published gem installation has been verified by those checks.

The local sample-to-hosted HTTP/GoodJob path was exercised with 101 accepted and processed events across all seven signal kinds, zero SDK losses, matched error/request account+trace correlation, and filtered credential probes. This verifies the local wire contract as well as isolated adapters; it does not certify a deployed customer application.

## Run the checks

```sh
bundle install
bundle exec rake test
node --test javascript/rails_mind.test.js
bundle exec ruby script/package_smoke.rb
```

CI runs Ruby 4.0.6 / Rails 8.1.3.1 on Linux, plus browser adapter contract tests
on Node 22. The package smoke check builds and installs a gem in a temporary directory, loads that copy,
and runs the installer against its packaged templates and browser adapter.
The sample app remains in the hosted application's repository with its own lockfile.

## 0.1.0 release verification

Rechecked on 2026-09-25 with Ruby 4.0.6, the locked Rails 8.1.3.1 dependencies,
and Node 22:

- Ruby suite: 40 tests, 377 assertions, no failures or skips.
- Browser adapter contract suite: 3 tests passed.
- Built-gem installation smoke check: 2 tests, 13 assertions; the installed gem
  loaded its own code, generator templates, and browser adapter.
- A localhost fixture using the actual JavaScript distributed with
  `turbo-rails` 2.0.23 passed in Chromium: initial load, repeated installation,
  completed visits, cached previews, back/forward restoration, labeled and
  unlabeled Frames, form navigation, explicit business outcomes, pageview
  opt-out, stopping listeners, and late initialization. Cached previews and
  Frame loads produced no extra pageviews; form navigation inferred no business
  outcome. Ahoy was a recording stub, so this check validates browser lifecycle
  behavior rather than Ahoy's server endpoint, cookies, or CSRF handling.

These checks cover the client package and its documented integrations locally.
They do not certify other browsers, every allowed Ruby/Rails combination,
production delivery guarantees, or a deployed customer application's setup.
