# RailsMind SDK

The MIT-licensed Ruby client for [RailsMind](https://railsmind.com). One bounded
collector for Rails requests, errors, jobs, mailer attempts, Ahoy events, Flipper
observations, and selected OpenTelemetry spans. Version 0.2.0 is an early release; see
[compatibility and validation limits](docs/compatibility.md).

```ruby
gem "rails_mind", "~> 0.2.0"
```

Install from RubyGems.org and commit your application's `Gemfile.lock` to pin the
resolved version. This repository contains the open-source client library. The
hosted RailsMind service is a separate, proprietary application; its source is
not included or licensed by this repository. See [development](CONTRIBUTING.md)
and [release notes](CHANGELOG.md).

```sh
bundle install
bin/rails generate rails_mind:install --plan
bin/rails generate rails_mind:install
bin/rails rails_mind:doctor
```

Set **`RAILS_MIND_KEY`** for the destination application environment. It is the only
required setting; collection stays off without it. The endpoint defaults to
`https://railsmind.com`. Release IDs are detected from hosting metadata or the
app's deployed `REVISION` file; telemetry still works when none is available.
`RAILS_MIND_ENDPOINT` and `RAILS_MIND_RELEASE` are optional overrides. See
[configuration and release detection](docs/sdk.md#configuration-and-release-detection).

After setting the key, run `bin/rails rails_mind:verify` on the app's
server. Match its check ID in RailsMind **Setup** and wait for **Check processed**.
Then visit the app to confirm real traffic. This command sends one labeled
diagnostic check, consumes one event of quota, and leaves business/performance
metrics alone. It requires a hosted app with installation-check support;
`rails_mind:doctor` remains read-only. See the
[verification guide](docs/sdk.md#verify-the-connection) for failure states
and the limits of this check.

```ruby
RailsMind.with_context(user_id: current_user.id.to_s, account_id: current_account.id.to_s) do
  RailsMind.track("Invoice paid", invoice_id: invoice.id, amount_cents: invoice.amount_cents)
end
```

Requests, ActiveJob executions, and Action Mailer attempts share native trace
context without requiring OpenTelemetry. Existing OpenTelemetry context stays
authoritative. Mail observations contain class/action, timing, and attempt
metadata, never recipients or rendered content; an attempt is not proof of inbox
delivery. See [workflow observations](docs/sdk.md#jobs-and-mailer-workflows).

See [installation and privacy](docs/sdk.md) and [compatibility](docs/compatibility.md).

Connect Claude Code or Codex with `bin/rails generate rails_mind:agent --plan`.
Choose an environment-variable API token or Rails encrypted credentials, then
follow the [agent setup guide](docs/agents.md) from first connection to a reported
PR and deployment confirmation. Requires rails_mind 0.2.0 or later.

Tests:

```sh
bundle install
bundle exec rake test
node --test javascript/rails_mind.test.js
bundle exec ruby script/package_smoke.rb
ruby script_benchmark.rb
```

Business/request/error events are unsampled, but delivery is best effort. Check `RailsMind.stats` for losses. The SDK does not guarantee durable business-event counts; use a transactional outbox when that is required.
