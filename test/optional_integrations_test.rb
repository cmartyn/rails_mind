require_relative "test_helper"
require "active_support"
require "rails_mind/integrations/rails"

class OptionalIntegrationsTest < SDKTest
  def test_ahoy_mirror_preserves_storage_return_identity_and_event_ids
    require "rails_mind/integrations/ahoy"
    store_class = Class.new(Ahoy::BaseStore) do
      attr_reader :received
      def track_event(data) = (@received = data; :stored)
    end
    RailsMind::Integrations.mirror_ahoy!(store_class)
    RailsMind::Integrations.mirror_ahoy!(store_class)
    tracker = Struct.new(:visitor_token).new("visitor-123")
    store = store_class.new(ahoy: tracker)
    data = { event_id: SecureRandom.uuid, name: "Invoice paid", user_id: 5, time: Time.now,
      visit_token: "visit-123", properties: { amount_cents: 4500, password: "private" } }
    assert_equal :stored, store.track_event(data)
    assert_same data, store.received
    assert_equal 1, @memory.events.size
    assert_equal data[:event_id], @memory.events.last["id"]
    assert_equal "visitor-123", @memory.events.last["visitor_id"]
    assert_equal "5", @memory.events.last["user_id"]
    assert_equal "private", data[:properties][:password]
    assert_equal "[FILTERED]", @memory.events.last.dig("properties", "password")
  rescue LoadError => error
    skip "Optional Ahoy gem unavailable: #{error.message}"
  end

  def test_ahoy_hosted_store_does_not_need_analytics_tables
    require "rails_mind/integrations/ahoy"
    tracker = Struct.new(:visitor_token).new("v1")
    store = RailsMind::Integrations::AhoyStore.new(ahoy: tracker)
    store.track_visit(visit_token: SecureRandom.uuid, visitor_token: "v1", started_at: Time.now, ip: "private", landing_page: "https://private")
    store.authenticate(visit_token: "visit", user_id: 2)
    assert_equal %w[visit event], @memory.events.map { |event| event["kind"] }
    assert_nil store.visit
    refute_includes JSON.generate(@memory.events), "private"
  rescue LoadError => error
    skip "Optional Ahoy gem unavailable: #{error.message}"
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
