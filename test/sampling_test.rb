require_relative "test_helper"

class SamplingTest < SDKTest
  def setup
    super
    @now = Time.utc(2026, 10, 11, 12)
    @tick = 100.0
    @sampling = RailsMind::Sampling.new(@config, clock: -> { @now }, monotonic: -> { @tick })
  end

  def test_default_enabled_and_only_routine_completed_requests_are_sampled
    assert @config.automatic_sampling
    assert @sampling.apply_policy(policy(rate: 0))
    refute @sampling.consider(request).first
    [ { "status" => "400" }, { "status" => "500" }, { "status" => nil }, { "status" => "error" },
      { "duration_ms" => 1000 }, { "duration_ms" => nil }, { "properties" => { "repeated_query_count" => 3 } },
      { "kind" => "error" }, { "kind" => "event" }, { "kind" => "visit" }, { "kind" => "job" },
      { "kind" => "span" }, { "kind" => "flag" }, { "kind" => "check" } ].each do |attributes|
      assert @sampling.consider(request.merge(attributes)).first, attributes.inspect
    end
    assert_equal 1, @sampling.stats[:sampled_out]
    assert_equal 1, @sampling.stats[:observed]
  end

  def test_policy_endpoint_rates_and_hash_are_stable_across_clients_and_policy_ids
    sample = request
    fraction = Digest::SHA256.digest("rails_mind:sampling:v1:#{sample['id']}").unpack1("Q>") / (2.0**64)
    @sampling.apply_policy(policy(rate: 0, endpoints: [ { "name" => "OrdersController#index", "rate" => fraction + 0.000001 } ]))
    assert @sampling.consider(sample).first
    assert_in_delta fraction + 0.000001, sample.dig("properties", "rails_mind_sampling", "rate")
    @sampling.apply_policy(policy(rate: fraction, id: "different"))
    refute @sampling.consider(request).first
  end

  def test_opt_out_and_server_disabled_bypass_local_selection_and_are_reported
    @sampling.apply_policy(policy(rate: 0))
    @config.automatic_sampling = false
    event = request
    assert @sampling.consider(event).first
    assert_equal "disabled", event.dig("properties", "rails_mind_sampling", "state")
    @sampling.rotate(force: true, byte_budget: 16_000)
    assert_equal false, @sampling.report(force: true)["enabled"]
    @config.automatic_sampling = true
    @sampling.apply_policy(policy(rate: 0).merge("enabled" => false))
    assert @sampling.consider(request).first
  end

  def test_invalid_stale_future_and_expired_controls_do_not_reduce_collection
    [ policy(rate: -0.1), policy(rate: Float::NAN), policy(rate: 1.1), policy.merge("version" => 2),
      policy.merge("enabled" => "true"), policy.merge("expires_at" => (@now + 3600).iso8601),
      policy.merge("issued_at" => (@now + 301).iso8601), policy.merge("endpoints" => [ { "name" => "x", "rate" => "0" } ]) ].each do |value|
      refute @sampling.apply_policy(value), value.inspect
      assert @sampling.consider(request).first
    end
    @sampling.apply_policy(policy(rate: 0))
    refute @sampling.apply_policy(policy(rate: 1).merge("issued_at" => (@now - 1).iso8601))
    @tick += 301
    event = request
    assert @sampling.consider(event).first
    assert_equal "expired", event.dig("properties", "rails_mind_sampling", "state")
  end

  def test_monotonic_expiry_cannot_be_extended_by_a_backward_wall_clock
    @sampling.apply_policy(policy(rate: 0))
    @now -= 1000
    @tick += 301
    assert @sampling.consider(request).first
  end

  def test_reports_keep_selection_separate_from_queue_loss_and_are_immutable_on_retry
    @sampling.apply_policy(policy(rate: 1))
    selected, observation = @sampling.consider(request)
    assert selected
    @sampling.queue_dropped(observation)
    @sampling.apply_policy(policy(rate: 0, id: "second"))
    refute @sampling.consider(request).first
    @sampling.rotate(force: true, byte_budget: 16_000)
    report = @sampling.report(force: true)
    assert_equal 1, report["version"]
    assert_equal "mixed", report["policy_id"]
    assert_equal [ 2, 1, 1, 1 ], report["endpoints"].first.values_at("observed", "retained", "sampled_out", "queue_dropped")
    assert_raises(FrozenError) { report["endpoints"].first["observed"] = 900 }
    frozen_wire = JSON.generate(report)
    @sampling.consider(request)
    assert_equal frozen_wire, JSON.generate(@sampling.report(force: true))
    @sampling.acknowledge(SecureRandom.uuid)
    assert_same report, @sampling.report(force: true)
    @sampling.acknowledge(report["id"])
    assert_nil @sampling.report(force: true)
  end

  def test_reports_rotate_once_per_minute_and_control_refresh_is_bounded
    @sampling.apply_policy(policy(rate: 1))
    @sampling.consider(request)
    assert @sampling.policy_due?
    @sampling.policy_requested!
    refute @sampling.policy_due?
    @sampling.rotate(byte_budget: 16_000)
    assert_nil @sampling.report
    @tick += 60
    @now += 60
    assert @sampling.policy_due?
    @sampling.rotate(byte_budget: 16_000)
    assert @sampling.report
    @sampling.report_sent!
    assert_nil @sampling.report
  end

  def test_cardinality_report_bytes_and_pending_memory_have_explicit_coverage_limits
    @sampling.apply_policy(policy(rate: 1))
    101.times { |n| assert @sampling.consider(request.merge("name" => "Endpoint#{n}Controller#index")).first }
    assert_equal 1, @sampling.stats[:unreported]
    @sampling.rotate(force: true, byte_budget: 960)
    assert_operator @sampling.stats[:pending_reports], :<=, RailsMind::Sampling::MAX_PENDING
    assert_operator @sampling.stats[:reports_lost], :>, 0
    report = @sampling.report(force: true)
    assert_equal true, report["limited"]
    assert_operator JSON.generate(report).bytesize, :<=, 960
    refute_includes JSON.generate(report), "account_id"
    refute_includes JSON.generate(report), "private"
  end

  def test_stale_reports_and_overlong_clock_windows_are_discarded_explicitly
    @sampling.apply_policy(policy(rate: 1))
    @sampling.consider(request)
    @sampling.rotate(force: true, byte_budget: 16_000)
    @now += 8 * 86_400
    @sampling.rotate(force: true, byte_budget: 16_000)
    assert_nil @sampling.report(force: true)
    assert_equal 1, @sampling.stats[:reports_lost]
    @sampling.consider(request)
    @sampling.rotate(force: true, byte_budget: 16_000)
    assert @sampling.stats[:unreported].positive?
  end

  private

  def request
    { "id" => "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "kind" => "request", "name" => "OrdersController#index",
      "status" => "200", "duration_ms" => 20, "account_id" => "private", "properties" => { "repeated_query_count" => 0 } }
  end

  def policy(rate: 1, id: "policy-1", endpoints: [])
    { "version" => 1, "id" => id, "enabled" => true, "issued_at" => @now.iso8601, "expires_at" => (@now + 300).iso8601,
      "default_rate" => rate, "endpoints" => endpoints }
  end
end
