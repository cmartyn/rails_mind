require_relative "test_helper"
require "active_support"
require "active_job"
require "rails_mind/integrations/rails"

class TelemetryExampleJob < ActiveJob::Base
  include RailsMind::Integrations::JobContext
  self.queue_adapter = :test

  def perform
    RailsMind.track("Job completed")
  end
end

class RailsIntegrationsTest < SDKTest
  def setup
    super
    RailsMind::Integrations::RailsNotifications.install!
  end

  def teardown
    RailsMind::Integrations::RailsNotifications.uninstall!
    super
  end

  def test_request_has_unsampled_measurement_and_hashed_query_patterns
    app = ->(_env) do
      ActiveSupport::Notifications.instrument("process_action.action_controller", controller: "OrdersController", action: "index", status: 200, method: "GET", params: { secret: "private" }) do
        3.times do |index|
          ActiveSupport::Notifications.instrument("sql.active_record", name: "User Load", sql: "SELECT * FROM users WHERE id = #{index}", binds: [ "private" ])
        end
      end
      [ 200, {}, [ "ok" ] ]
    end
    RailsMind::Integrations::RailsNotifications.install! # Must not duplicate subscribers.
    response = RailsMind::Integrations::RequestContext.new(app).call("action_dispatch.request_id" => "request-42")
    assert_equal 200, response.first
    requests = @memory.events.select { |event| event["kind"] == "request" }
    assert_equal 1, requests.size
    event = requests.first
    assert_equal "request-42", event["request_id"]
    assert_equal 3, event.dig("properties", "query_count")
    assert_equal 2, event.dig("properties", "repeated_query_count")
    assert_match(/\A[0-9a-f]{24}\z/, event.dig("properties", "query_fingerprints").keys.first)
    refute_includes JSON.generate(event), "SELECT"
    refute_includes JSON.generate(event), "private"
    assert_empty RailsMind::Context.snapshot
  end

  def test_job_context_survives_serialization_and_does_not_leak_to_next_job
    serialized = nil
    RailsMind.with_context(user_id: "u1", account_id: "a1", request_id: "r1") do
      job = TelemetryExampleJob.perform_later
      serialized = job.serialize
    end
    assert_equal "a1", serialized.dig("rails_mind_context", "account_id")
    serialized["enqueued_at"] = (Time.now - 5).utc.iso8601(6)
    ActiveJob::Base.execute(serialized)
    business = @memory.events.find { |event| event["name"] == "Job completed" }
    assert_equal "a1", business["account_id"]
    assert_equal serialized["job_id"], business["job_id"]
    job_event = @memory.events.find { |event| event["kind"] == "job" }
    assert_equal "a1", job_event["account_id"]
    assert_in_delta 5000, job_event.dig("properties", "queue_delay_ms"), 500
    assert_empty RailsMind::Context.snapshot
    TelemetryExampleJob.perform_now
    assert_nil @memory.events.reverse.find { |event| event["name"] == "Job completed" }["account_id"]
  end

  def test_rails_error_reporter_uses_collector_without_replacing_other_subscribers
    require "active_support/error_reporter"
    reporter = ActiveSupport::ErrorReporter.new
    existing = Object.new
    def existing.report(error, **options) = @seen = error
    def existing.seen = @seen
    reporter.subscribe(existing)
    reporter.subscribe(RailsMind::Integrations::ErrorSubscriber.new)
    error = RuntimeError.new("private")
    reporter.report(error, handled: false, context: { account_id: "a1", password: "private" })
    assert_same error, existing.seen
    assert_equal "a1", @memory.events.last["account_id"]
    refute_includes JSON.generate(@memory.events), "private"
  end
end
