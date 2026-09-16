# RailsMind SDK

One bounded collector for Rails requests, errors, jobs, Ahoy events, Flipper observations, and selected OpenTelemetry spans. Prototype version 0.1.0; unpublished.

```ruby
gem "rails_mind", git: "https://github.com/cmartyn/rails_mind.git", branch: "main"
```

This is the canonical SDK repository. It is private during the pilot: your Git
credentials must have access. Commit your application's `Gemfile.lock` to pin the
resolved revision; use a reviewed `ref:` commit for deployment updates. See
[development and repository access](CONTRIBUTING.md).

```sh
bundle install
bin/rails generate rails_mind:install --plan
bin/rails generate rails_mind:install
bin/rails rails_mind:doctor
```

Set `RAILS_MIND_ENDPOINT`, `RAILS_MIND_KEY`, and `RAILS_MIND_RELEASE`. The ingest key belongs to one application environment. Collection stays off until endpoint and key are both present.

After setting the endpoint and key, run `bin/rails rails_mind:verify` on the app's
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

See [installation and privacy](docs/sdk.md), [compatibility](docs/compatibility.md), and the [sample app](https://github.com/cmartyn/mind/tree/main/sample).

Tests:

```sh
bundle install
bundle exec rake test
node --test javascript/rails_mind.test.js
bundle exec ruby script/package_smoke.rb
ruby script_benchmark.rb
```

Business/request/error events are unsampled, but delivery is best effort. Check `RailsMind.stats` for losses. The SDK does not guarantee durable business-event counts; use a transactional outbox when that is required.
