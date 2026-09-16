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
| Turbo | [turbo-rails 2.0.23, MIT](https://rubygems.org/gems/turbo-rails) | Browser adapter lifecycle contract tests cover visits, previews, Frames, repeat installation, and explicit events. Full real-browser navigation matrix remains a release gate. |
| Other error reporters | Rails error interface; no mandatory SDK | Subscriber coexistence tested with a second subscriber. Sentry/Honeybadger/Bugsnag/Rollbar detection only; no vendor-specific version certification. |
| Sidekiq, Solid Queue, Delayed Job | Detection only | ActiveJob jobs inherit the shared integration when used through Rails; backend-specific APIs/direct jobs are not covered. |
| Bullet / Prosopite | Optional, deferred dependency | Use in development/isolated reproduction. No automatic production scans or forks. |
| Field Test | Optional, deferred dependency | Detect installed version; no assignment/exposure/import or experiment analysis in this release. |

Current Ahoy 5.5 and OTel 1.13 require Ruby ≥3.3. No integration gems are mandatory at SDK runtime beyond Rails and Net::HTTP. Customers select optional dependencies; the installer does not silently add them. MIT/Apache licenses allow this extension strategy without maintaining forks.

The preferred foundations remain suitable for the pilot. Ahoy's store model provides a supported buffered-delivery seam but its database associations do not exist in hosted-only mode. Flipper's authoritative configuration remains in the customer's existing adapter; managed flags need an explicit future mode. OTel Ruby tracing supplies the useful mature signal here; broad metrics/logs/exporter parity is deliberately outside this prototype. [Ahoy store contract](https://github.com/ankane/ahoy#data-stores), [Flipper observation contract](https://www.flippercloud.io/docs/instrumentation), [OpenTelemetry Ruby](https://opentelemetry.io/docs/languages/ruby/).

Tests are in `test`, browser lifecycle tests in `javascript`, and real Rails request tests in the separate [sample app](https://github.com/cmartyn/mind/tree/main/sample/test). Re-run the matrix when bumping dependencies. No external telemetry service, vendor account, historical migration, production overhead budget, or published gem installation has been verified.

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
