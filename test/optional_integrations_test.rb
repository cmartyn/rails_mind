require_relative "test_helper"
require "active_support"
require "rails_mind/integrations/rails"

class OptionalIntegrationsTest < SDKTest
  def test_the_ahoy_integration_is_gone
    assert_raises(LoadError) { require "rails_mind/integrations/ahoy" }
    refute RailsMind::Integrations.respond_to?(:mirror_ahoy!)
    refute RailsMind::Integrations.const_defined?(:AhoyStore)
  end

  def test_flipper_observer_preserves_existing_group_targeting_and_adapter
    require "flipper"
    RailsMind::Integrations::RailsNotifications.install!
    adapter = Flipper::Adapters::Memory.new
    flipper = Flipper.new(adapter, instrumenter: ActiveSupport::Notifications)
    configured_adapter = flipper.adapter
    Flipper.register(:rails_mind_test_staff) { |actor| actor.respond_to?(:staff?) && actor.staff? }
    actor = Struct.new(:flipper_id) { def staff? = true }.new("staff-1")
    flipper.enable_group(:new_checkout, :rails_mind_test_staff)
    assert flipper.enabled?(:new_checkout, actor)
    refute flipper.enabled?(:new_checkout)
    assert_same configured_adapter, flipper.adapter
    checks = @memory.events.select { |event| event.dig("properties", "operation") == "enabled?" }
    assert_equal [ true, false ], checks.map { |event| event.dig("properties", "enabled") }
    assert checks.none? { |event| event.dig("properties", "exposure") }
    refute_includes JSON.generate(checks), "staff-1"
  rescue LoadError => error
    skip "Optional Flipper gem unavailable: #{error.message}"
  ensure
    RailsMind::Integrations::RailsNotifications.uninstall!
  end

  def test_otel_reuses_provider_keeps_existing_exporter_and_removes_sql
    require "rails_mind/integrations/open_telemetry"
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    existing = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(existing))
    RailsMind::Integrations::OpenTelemetry.attach!(provider: provider)
    RailsMind::Integrations::OpenTelemetry.attach!(provider: provider)
    tracer = provider.tracer("test.library")
    RailsMind.with_context(account_id: "account-1") do
      tracer.in_span("SELECT secret FROM users", attributes: { "db.system" => "postgresql", "db.operation" => "SELECT", "db.statement" => "private", "http.request.body" => "private" }) do |span|
        span.set_attribute("user.email", "private@example.com")
      end
    end
    assert_equal 1, existing.finished_spans.size
    assert_equal 1, @memory.events.size
    event = @memory.events.first
    assert_equal "db.SELECT", event["name"]
    assert_equal "account-1", event["account_id"]
    assert_match(/\A[0-9a-f]{32}\z/, event["trace_id"])
    refute_includes JSON.generate(event), "private"
    assert_includes existing.finished_spans.first.attributes.values, "private" # Other exporter untouched.
  rescue LoadError => error
    skip "Optional OpenTelemetry gem unavailable: #{error.message}"
  end

  def test_unsampled_trace_does_not_drop_error_or_business_event
    require "rails_mind/integrations/open_telemetry"
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new(sampler: OpenTelemetry::SDK::Trace::Samplers::ALWAYS_OFF)
    RailsMind::Integrations::OpenTelemetry.attach!(provider: provider)
    provider.tracer("test").in_span("not retained") do
      @client.capture_exception(RuntimeError.new("private"))
      @client.emit(:event, "Payment completed")
    end
    assert_equal %w[error event], @memory.events.map { |event| event["kind"] }
  rescue LoadError => error
    skip "Optional OpenTelemetry gem unavailable: #{error.message}"
  end
end
