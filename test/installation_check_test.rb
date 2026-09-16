require_relative "test_helper"
require "rails_mind/installation_check"

class InstallationCheckTest < SDKTest
  def test_check_uses_the_collector_even_when_all_optional_signals_are_disabled
    @config.apm = @config.errors = @config.analytics = @config.flags = false
    transport = ScriptedTransport.new
    result = RailsMind::Context.with(account_id: "customer", trace_id: "trace") do
      RailsMind::InstallationCheck.new(@config, transport: transport).run
    end
    assert result[:success]
    event = JSON.parse(transport.bodies.sole)["events"].sole
    assert_equal result[:check_id], event["id"]
    assert_equal "check", event["kind"]
    assert_equal [ "id", "kind", "name", "occurred_at", "properties" ], event.keys.sort
    assert_equal({ "sdk_version" => RailsMind::VERSION }, event["properties"])
    refute_includes result.to_json, @config.token
    assert_empty @memory.events
  end

  def test_missing_configuration_does_not_send_a_check
    @config.token = nil
    transport = ScriptedTransport.new
    result = RailsMind::InstallationCheck.new(@config, transport: transport).run
    refute result[:success]
    assert_nil result[:check_id]
    assert_empty transport.bodies
    assert_includes result[:message], "Set RAILS_MIND_KEY"
    refute_includes result[:message], "Set RAILS_MIND_ENDPOINT"
  end

  def test_hosted_defaults_allow_verification_with_only_a_key
    config = RailsMind::Configuration.new(env: { "RAILS_MIND_KEY" => "test-only" })
    transport = ScriptedTransport.new
    result = RailsMind::InstallationCheck.new(config, transport: transport).run
    assert result[:success], result[:message]
    assert_equal "https://railsmind.com", config.endpoint
    assert_equal 1, transport.bodies.size
  end

  def test_permanent_rejection_is_a_failed_check_even_when_flush_finishes
    transport = ScriptedTransport.new([ RailsMind::Transport::Result.new(success: false, retryable: false) ])
    result = RailsMind::InstallationCheck.new(@config, transport: transport).run
    refute result[:success]
    assert_includes result[:message], "Delivery failed"
    assert_equal 1, transport.bodies.size
  end

  def test_retry_preserves_the_check_id
    transport = ScriptedTransport.new([ RailsMind::Transport::Result.new(success: false, retryable: true) ])
    result = RailsMind::InstallationCheck.new(@config, transport: transport).run
    assert result[:success]
    assert_equal 2, transport.bodies.size
    assert_equal transport.bodies.first, transport.bodies.last
  end

  def test_filtering_or_repurposing_the_check_is_reported_without_sending
    [ ->(_event) { nil }, ->(event) { event.merge("kind" => "event") }, ->(event) { event.merge("id" => SecureRandom.uuid) } ].each do |hook|
      @config.before_send = hook
      transport = ScriptedTransport.new
      result = RailsMind::InstallationCheck.new(@config, transport: transport).run
      refute result[:success]
      assert_includes result[:message], "did not enqueue"
      assert_empty transport.bodies
    end
  end

  def test_unconfirmed_delivery_has_a_deadline_and_never_claims_success
    transport = Object.new
    transport.define_singleton_method(:send_batch) { |_body| sleep(20) }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = RailsMind::InstallationCheck.new(@config, transport: transport).run(timeout: 0.02)
    refute result[:success]
    assert_includes result[:message], "deadline"
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
  end
end
