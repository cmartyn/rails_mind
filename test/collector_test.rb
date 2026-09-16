require_relative "test_helper"

class CollectorTest < SDKTest
  def event(id = SecureRandom.uuid, padding: "")
    { id: id, kind: "event", name: "Paid", properties: { padding: padding } }
  end

  def test_retry_keeps_exact_event_ids_and_immutable_payload
    transport = ScriptedTransport.new([ RailsMind::Transport::Result.new(success: false, retryable: true) ])
    collector = RailsMind::Collector.new(@config, transport: transport, autostart: false)
    payload = event
    id = payload[:id]
    assert collector.push(payload)
    payload[:name] = "Mutated"
    assert collector.flush(timeout: 1)
    assert_equal 2, transport.bodies.size
    assert_equal transport.bodies.first, transport.bodies.last
    assert_equal id, JSON.parse(transport.bodies.last)["events"].first["id"]
    assert_equal "Paid", JSON.parse(transport.bodies.last)["events"].first["name"]
    assert_equal 1, collector.stats[:retried]
  ensure
    collector&.shutdown
  end

  def test_capacity_loss_is_explicit_and_no_sampling_occurs
    @config.queue_capacity = 2
    collector = RailsMind::Collector.new(@config, transport: ScriptedTransport.new, autostart: false)
    assert collector.push(event)
    assert collector.push(event)
    refute collector.push(event)
    assert_equal 2, collector.stats[:queued]
    assert_equal 1, collector.stats[:losses]["event.overflow"]
    collector.flush(timeout: 1)
    assert_equal 2, collector.stats[:delivered]
  ensure
    collector&.shutdown
  end

  def test_batch_size_and_utf8_byte_limits
    @config.max_batch_bytes = 1024
    @config.batch_size = 3
    transport = ScriptedTransport.new
    collector = RailsMind::Collector.new(@config, transport: transport, autostart: false)
    10.times { assert collector.push(event(padding: "🧠" * 50)) }
    refute collector.push(event(padding: "🧠" * 300))
    collector.flush(timeout: 1)
    assert_equal 10, transport.bodies.sum { |body| JSON.parse(body)["events"].size }
    transport.bodies.each do |body|
      assert_operator body.bytesize, :<=, 1024
      assert_operator JSON.parse(body)["events"].size, :<=, 3
    end
    assert_equal 1, collector.stats[:losses]["event.oversize"]
  ensure
    collector&.shutdown
  end

  def test_permanent_failure_not_retried_and_transient_retries_bounded
    result = RailsMind::Transport::Result.new(success: false, retryable: false)
    transport = ScriptedTransport.new([ result ])
    collector = RailsMind::Collector.new(@config, transport: transport, autostart: false)
    collector.push(event)
    collector.flush(timeout: 1)
    assert_equal 1, transport.bodies.size
    assert_equal 1, collector.stats[:losses]["event.delivery"]
    collector.shutdown

    transport = ScriptedTransport.new(Array.new(10) { RailsMind::Transport::Result.new(success: false, retryable: true) })
    collector = RailsMind::Collector.new(@config, transport: transport, autostart: false)
    collector.push(event)
    collector.flush(timeout: 1)
    assert_equal 4, transport.bodies.size
    assert_equal 3, collector.stats[:retried]
    assert_equal 1, collector.stats[:dropped]
  ensure
    collector&.shutdown
  end

  def test_hung_transport_does_not_block_enqueue_and_shutdown_is_bounded
    transport = Object.new
    def transport.send_batch(_body) = sleep(20)
    collector = RailsMind::Collector.new(@config, transport: transport)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    50.times { assert collector.push(event) }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :<, 0.1
    refute collector.shutdown(timeout: 0.05)
    assert_equal 50, collector.stats[:dropped]
    refute collector.push(event)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :<, 0.5
  end

  def test_configuration_reads_key_from_env
    previous = ENV["RAILS_MIND_KEY"]
    ENV["RAILS_MIND_KEY"] = "env-ingest-key"
    assert_equal "env-ingest-key", RailsMind::Configuration.new.token
  ensure
    ENV["RAILS_MIND_KEY"] = previous
  end
end
