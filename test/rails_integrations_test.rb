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

  def test_request_has_unsampled_measurement_hashed_query_patterns_and_shapes_of_repeated_queries
    app = ->(_env) do
      ActiveSupport::Notifications.instrument("process_action.action_controller", controller: "OrdersController", action: "index", status: 200, method: "GET", params: { secret: "private" }) do
        3.times do |index|
          ActiveSupport::Notifications.instrument("sql.active_record", name: "User Load", sql: "SELECT * FROM users /*request_id:abc-#{index},email:ann@example.com*/ WHERE id = #{index} AND name = 'ann #{index}'", binds: [ "private" ])
        end
        ActiveSupport::Notifications.instrument("sql.active_record", name: "Order Load", sql: "SELECT * FROM orders WHERE token = 'single-secret'", binds: [])
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
    assert_equal 4, event.dig("properties", "query_count")
    assert_equal 2, event.dig("properties", "repeated_query_count")
    fingerprints = event.dig("properties", "query_fingerprints")
    assert_equal 2, fingerprints.size
    repeated, _count = fingerprints.max_by { |_, count| count }
    assert_match(/\A[0-9a-f]{24}\z/, repeated)
    assert_equal({ repeated => "SELECT * FROM users WHERE id = ? AND name = ?" }, event.dig("properties", "query_shapes"), "only repeated fingerprints carry a shape")
    json = JSON.generate(event)
    refute_includes json, "private"
    refute_includes json, "ann"
    refute_includes json, "abc-", "query comments are stripped"
    refute_includes json, "/*"
    refute_includes json, "single-secret"
    assert_empty RailsMind::Context.snapshot
  end

  def test_session_settings_and_transaction_control_are_counted_but_never_fingerprinted_as_repeats
    app = ->(_env) do
      ActiveSupport::Notifications.instrument("process_action.action_controller", controller: "WorkflowsController", action: "show", status: 200, method: "GET") do
        3.times { ActiveSupport::Notifications.instrument("sql.active_record", name: "SQL", sql: "SET LOCAL statement_timeout = '2s'", binds: []) }
        2.times { ActiveSupport::Notifications.instrument("sql.active_record", name: nil, sql: "SHOW statement_timeout", binds: []) }
        %w[BEGIN SAVEPOINT\ active_record_1 RELEASE\ SAVEPOINT\ active_record_1 COMMIT ROLLBACK RESET\ ALL DISCARD\ ALL PRAGMA\ foreign_keys].each do |sql|
          2.times { ActiveSupport::Notifications.instrument("sql.active_record", name: "SQL", sql: "/* request_id:1 */ #{sql}", binds: []) }
        end
        ActiveSupport::Notifications.instrument("sql.active_record", name: "Workflow Load", sql: "SELECT * FROM workflows WHERE id = 1", binds: [])
      end
      [ 200, {}, [ "ok" ] ]
    end
    RailsMind::Integrations::RequestContext.new(app).call({})
    properties = @memory.events.last["properties"]
    assert_equal 22, properties["query_count"], "every statement still counts toward the request's statements"
    assert_equal 0, properties["repeated_query_count"]
    assert_equal 1, properties["query_fingerprints"].size
    assert_empty properties["query_shapes"]
  end

  def test_query_shapes_are_bounded_and_can_be_kept_at_home
    long_sql = "SELECT #{(1..120).map { |i| "orders.column_#{i}" }.join(', ')} FROM orders WHERE id = 1"
    app = ->(_env) do
      ActiveSupport::Notifications.instrument("process_action.action_controller", controller: "OrdersController", action: "show", status: 200, method: "GET") do
        2.times { ActiveSupport::Notifications.instrument("sql.active_record", name: "Order Load", sql: long_sql, binds: []) }
      end
      [ 200, {}, [ "ok" ] ]
    end
    RailsMind::Integrations::RequestContext.new(app).call({})
    shape = @memory.events.last.dig("properties", "query_shapes").values.sole
    assert_equal 400, shape.length
    assert shape.start_with?("SELECT orders.column_1, orders.column_2")
    refute_includes shape, "id = 1"

    @config.capture_query_shapes = false
    RailsMind::Integrations::RequestContext.new(app).call({})
    event = @memory.events.last
    assert_equal 1, event.dig("properties", "repeated_query_count")
    refute event["properties"].key?("query_shapes")
    refute_includes JSON.generate(event), "SELECT"
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

  class RailsMindExampleController
    def action_name = "show"
  end

  def test_error_reports_say_which_action_job_or_process_raised_them
    require "active_support/error_reporter"
    ActiveSupport::ExecutionContext.clear
    reporter = ActiveSupport::ErrorReporter.new
    reporter.subscribe(RailsMind::Integrations::ErrorSubscriber.new)
    reporter.report(RuntimeError.new("in a request"), handled: false, context: { controller: RailsMindExampleController.new }, source: "application.action_dispatch")
    assert_equal({ "role" => "web", "route" => "RailsIntegrationsTest::RailsMindExampleController#show" },
      @memory.events.last["properties"].slice("role", "route", "job_class", "queue"))

    reporter.report(RuntimeError.new("in a job"), handled: false, context: { job: TelemetryExampleJob.new }, source: "application.active_job")
    assert_equal({ "role" => "job", "job_class" => "TelemetryExampleJob", "queue" => "default" },
      @memory.events.last["properties"].slice("role", "route", "job_class", "queue"))

    reporter.report(NameError.new("in a script"), handled: false, context: { job: TelemetryExampleJob.new }, source: "application.runner.railties")
    assert_equal({ "role" => "runner" }, @memory.events.last["properties"].slice("role", "route", "job_class", "queue"))

    app = ->(_env) { raise KeyError, "unrouted" }
    env = { "action_dispatch.request.path_parameters" => { controller: "admin/orders", action: "show" } }
    assert_raises(KeyError) { RailsMind::Integrations::RequestContext.new(app).call(env) }
    assert_equal({ "role" => "web", "route" => "Admin::OrdersController#show" }, @memory.events.last["properties"].slice("role", "route"))
  end

  def test_rails_error_reporter_uses_collector_without_replacing_other_subscribers
    require "active_support/error_reporter"
    reporter = ActiveSupport::ErrorReporter.new
    existing = Object.new
    def existing.report(error, **options) = @seen = error
    def existing.seen = @seen
    reporter.subscribe(existing)
    reporter.subscribe(RailsMind::Integrations::ErrorSubscriber.new)
    @config.capture_exception_message = false
    error = RuntimeError.new("private")
    reporter.report(error, handled: false, context: { account_id: "a1", password: "private" })
    assert_same error, existing.seen
    assert_equal "a1", @memory.events.last["account_id"]
    refute_includes JSON.generate(@memory.events), "private"
  end
end
