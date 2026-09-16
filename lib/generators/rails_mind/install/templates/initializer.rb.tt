RailsMind.configure do |config|
  config.token = ENV["RAILS_MIND_KEY"] # Environment-scoped server credential. Never expose to browsers.

  # Endpoint defaults to https://railsmind.com; RAILS_MIND_ENDPOINT overrides it.
  # Release is detected from hosting metadata or Rails.root/REVISION when available.
  # RAILS_MIND_RELEASE is an optional override. Neither variable is required.

  # Optional capabilities can be switched off independently.
  # config.apm = false
  # config.errors = false
  # config.analytics = false
  # config.flags = false

  # Exception messages are omitted by default. Review before enabling.
  # config.capture_exception_message = true
  # config.before_send = ->(event) { event } # Return nil to drop an event.
end

# No existing Ahoy store, Flipper adapter, or OpenTelemetry provider is changed.
# Run `bin/rails rails_mind:doctor` and follow docs/sdk.md for opt-in integrations.
