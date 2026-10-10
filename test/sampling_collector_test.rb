require_relative "test_helper"
require "timeout"

class SamplingCollectorTest < SDKTest
  class ControlTransport
    attr_reader :bodies, :gets
    attr_accessor :acknowledge, :responses, :policy

    def initialize(policy)
      @policy, @bodies, @gets, @acknowledge, @responses = policy, [], 0, true, []
    end

    def fetch_sampling_policy
      @gets += 1
      RailsMind::Transport::Result.new(success: true, sampling_policy: policy)
    end

    def send_batch(body)
      @bodies << body
      packet = JSON.parse(body)
      RailsMind::Transport::Result.new(success: responses.empty? ? true : responses.shift,
        retryable: true, retry_after: 0, sampling_policy: policy,
        sampling_report_ack: acknowledge && packet.dig("sampling_report", "id"))
    end
  end

  def test_rate_zero_sends_report_only_and_refreshes_without_spending_an_event
    with_collector(rate: 0) do |collector, transport, client|
      refute client.emit(:request, "OrdersController#index", status: "200", duration_ms: 5)
      assert collector.flush(timeout: 1)
      packet = JSON.parse(transport.bodies.sole)
      assert_empty packet["events"]
      assert_equal [ 1, 0, 1, 0 ], packet.dig("sampling_report", "endpoints").first.values_at("observed", "retained", "sampled_out", "queue_dropped")
      assert_equal 1, transport.gets
      assert_equal 0, collector.stats[:dropped]
      assert_equal 0, collector.stats[:delivered]
    end
  end

  def test_protected_signals_survive_rate_zero_and_metadata_is_sdk_owned
    with_collector(rate: 0) do |collector, transport, client|
      @config.before_send = ->(event) { event.merge("properties" => event["properties"].merge("rails_mind_sampling" => { "rate" => 0 })) }
      assert client.emit(:request, "OrdersController#index", status: "500", duration_ms: 5)
      assert client.emit(:request, "OrdersController#index", status: "200", duration_ms: 1000)
      assert client.emit(:request, "OrdersController#index", status: "200", duration_ms: 5, properties: { repeated_query_count: 3 })
      assert client.emit(:event, "Invoice paid")
      assert client.capture_exception(RuntimeError.new("private"))
      assert collector.flush(timeout: 1)
      events = transport.bodies.flat_map { |body| JSON.parse(body)["events"] }
      assert_equal 5, events.size
      assert_equal [ 1.0 ], events.select { |event| event["kind"] == "request" }.map { |event| event.dig("properties", "rails_mind_sampling", "rate") }.uniq
      assert_equal 0, collector.stats.dig(:sampling, :sampled_out)
    end
  end

  def test_selected_counts_queue_loss_and_immutable_report_survive_429_retry
    @config.queue_capacity = 1
    with_collector(rate: 1) do |collector, transport, client|
      transport.responses = [ false, true ]
      assert client.emit(:request, "OrdersController#index", status: "200", duration_ms: 5)
      refute client.emit(:request, "OrdersController#index", status: "200", duration_ms: 5)
      assert collector.flush(timeout: 1)
      assert_equal 2, transport.bodies.size
      assert_equal transport.bodies.first, transport.bodies.last
      report = JSON.parse(transport.bodies.first)["sampling_report"]
      assert_equal [ 2, 2, 0, 1 ], report["endpoints"].first.values_at("observed", "retained", "sampled_out", "queue_dropped")
      assert_equal 1, collector.stats[:delivered]
      assert_equal 1, collector.stats[:losses]["request.overflow"]
      assert_equal 0, collector.stats.dig(:sampling, :pending_reports)
    end
  end

  def test_unacknowledged_reports_are_bounded_and_never_claim_confirmed_flush
    with_collector(rate: 0) do |collector, transport, client|
      transport.acknowledge = false
      refute client.emit(:request, "OrdersController#index", status: "200", duration_ms: 5)
      refute collector.flush(timeout: 0.03)
      assert_equal 1, transport.bodies.size
      assert_equal 1, collector.stats.dig(:sampling, :pending_reports)
      transport.acknowledge = true
      assert collector.flush(timeout: 1)
      assert_equal transport.bodies.first, transport.bodies.last
    end
  end

  def test_batch_byte_budget_includes_report_and_report_can_be_sent_before_events
    @config.max_batch_bytes = 1024
    with_collector(rate: 1) do |collector, transport, client|
      assert client.emit(:request, "OrdersController#index", status: "200", duration_ms: 5, properties: { detail: "x" * 450 })
      assert collector.flush(timeout: 1)
      assert_operator transport.bodies.size, :>=, 2
      assert_equal 1, transport.bodies.sum { |body| JSON.parse(body)["events"].size }
      transport.bodies.each { |body| assert_operator body.bytesize, :<=, 1024 }
    end
  end

  def test_child_process_does_not_resend_parent_queue_reports_or_policy
    skip "fork unavailable" unless Process.respond_to?(:fork)
    with_collector(rate: 0) do |collector, _transport, client|
      assert client.emit(:event, "Parent event")
      refute client.emit(:request, "OrdersController#index", status: "200", duration_ms: 5)
      read, write = IO.pipe
      pid = fork do
        read.close
        snapshot = collector.stats
        selected = client.emit(:request, "OrdersController#index", status: "200", duration_ms: 5)
        Marshal.dump([ snapshot, selected ], write)
        write.close
        exit! 0
      end
      write.close
      snapshot, selected = Marshal.load(read)
      Process.wait(pid)
      read.close
      assert_equal 0, snapshot[:queued]
      assert_equal 0, snapshot.dig(:sampling, :observed)
      assert_equal "unavailable", snapshot.dig(:sampling, :policy_state)
      assert selected
      assert_equal 1, collector.stats[:queued]
      assert_equal 1, collector.stats.dig(:sampling, :sampled_out)
    ensure
      read&.close unless read&.closed?
      write&.close unless write&.closed?
    end
  end

  def test_worker_reports_at_zero_rate_without_explicit_flush_or_queued_events
    with_collector(rate: 0) do |collector, transport, client|
      tick = 0.0
      now = Time.now.utc
      sampler = RailsMind::Sampling.new(@config, clock: -> { now + tick }, monotonic: -> { tick })
      sampler.apply_policy(transport.policy)
      collector.instance_variable_set(:@sampling, sampler)
      @config.flush_interval = 0.001
      receipts = Queue.new
      original = transport.method(:send_batch)
      transport.define_singleton_method(:send_batch) do |body|
        result = original.call(body)
        receipts << JSON.parse(body)
        result
      end
      refute client.emit(:request, "OrdersController#index", status: "200", duration_ms: 5)
      tick = 60.0
      collector.send(:start_worker)
      packet = Timeout.timeout(1) { receipts.pop }
      assert_empty packet["events"]
      assert_equal 1, packet.dig("sampling_report", "endpoints").first["sampled_out"]
      assert_operator transport.gets, :>=, 1
    end
  end

  def test_old_server_without_controls_keeps_event_only_flush_successful
    transport = ScriptedTransport.new
    collector = RailsMind::Collector.new(@config, transport: transport, autostart: false)
    client = RailsMind::Client.new(@config, collector: collector)
    assert client.emit(:request, "OrdersController#index", status: "200", duration_ms: 5)
    assert collector.flush(timeout: 1)
    assert_equal 1, collector.stats[:delivered]
    refute JSON.parse(transport.bodies.sole).key?("sampling_report")
    assert_equal 0, collector.stats.dig(:sampling, :pending_reports)
    assert_equal "unavailable", collector.stats.dig(:sampling, :policy_state)
  ensure
    collector&.shutdown(timeout: 0.05)
  end

  def test_post_handshake_can_report_pre_handshake_counts_within_same_flush
    with_collector(rate: 1) do |collector, transport, client|
      collector.instance_variable_set(:@sampling, RailsMind::Sampling.new(@config))
      transport.define_singleton_method(:fetch_sampling_policy) { RailsMind::Transport::Result.new(success: false) }
      assert client.emit(:request, "OrdersController#index", status: "200", duration_ms: 5)
      assert collector.flush(timeout: 1)
      assert_equal 2, transport.bodies.size
      first, second = transport.bodies.map { |body| JSON.parse(body) }
      refute first.key?("sampling_report")
      assert_empty second["events"]
      assert_equal 1, second.dig("sampling_report", "endpoints").first["observed"]
    end
  end

  def test_acknowledged_report_and_unconfirmed_events_are_counted_separately
    with_collector(rate: 1) do |collector, transport, client|
      transport.responses = [ false ] * 4
      assert client.emit(:request, "OrdersController#index", status: "200", duration_ms: 5)
      assert collector.flush(timeout: 1)
      assert_equal 0, collector.stats[:delivered]
      assert_equal 0, collector.stats[:dropped]
      assert_equal 1, collector.stats[:delivery_unconfirmed]
      assert_equal 1, collector.stats[:losses]["request.delivery_unconfirmed"]
      assert_equal 0, collector.stats.dig(:sampling, :pending_reports)
      assert_equal 1, transport.bodies.uniq.size
    end
  end

  private

  def with_collector(rate:)
    policy = { "version" => 1, "id" => "test-policy", "issued_at" => Time.now.utc.iso8601,
      "expires_at" => (Time.now.utc + 300).iso8601, "enabled" => true, "default_rate" => rate, "endpoints" => [] }
    transport = ControlTransport.new(policy)
    collector = RailsMind::Collector.new(@config, transport: transport, autostart: false)
    collector.instance_variable_get(:@sampling).apply_policy(policy)
    client = RailsMind::Client.new(@config, collector: collector)
    yield collector, transport, client
  ensure
    collector&.shutdown(timeout: 0.05)
  end
end
