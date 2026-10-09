require_relative "test_helper"
require "active_support"
require "active_job"
require "rails_mind/integrations/rails"

class LifecycleJob < ActiveJob::Base
  include RailsMind::Integrations::JobContext
  self.queue_adapter = :test
  self.logger = nil

  def perform(_private_argument = nil)
    RailsMind.track("Lifecycle work completed")
  end
end

class AbortedEnqueueJob < LifecycleJob
  before_enqueue { throw :abort }
end

class AbortedPerformJob < LifecycleJob
  before_perform { throw :abort }
end

class FailingLifecycleJob < LifecycleJob
  def perform(*) = raise(RuntimeError, "private-job-message")
end

class RetriedLifecycleJob < FailingLifecycleJob
  retry_on RuntimeError, wait: 60, attempts: 2, jitter: 0
end

class DiscardedLifecycleJob < FailingLifecycleJob
  discard_on RuntimeError
end

class JobLifecycleTest < SDKTest
  def setup
    super
    LifecycleJob.queue_adapter = :test
    LifecycleJob.queue_adapter.enqueued_jobs.clear
    RailsMind::Integrations::RailsNotifications.install!
  end

  def teardown
    RailsMind::Integrations::RailsNotifications.uninstall!
    super
  end

  def test_request_enqueue_and_serialized_execution_share_native_trace
    job = nil
    app = ->(_env) do
      RailsMind.identify(user_id: "user-1", visitor_id: "visitor-1")
      ActiveSupport::Notifications.instrument("process_action.action_controller",
        controller: "InvitesController", action: "create", status: 201) do
        job = LifecycleJob.perform_later("private-argument")
      end
      [ 201, {}, [] ]
    end
    RailsMind::Integrations::RequestContext.new(app).call("action_dispatch.request_id" => "request-1")
    serialized = job.serialize
    ActiveJob::Base.execute(serialized)

    events = @memory.events
    trace = events.first["trace_id"]
    assert_match(/\A[0-9a-f]{32}\z/, trace)
    assert_equal [ trace ], events.map { |event| event["trace_id"] }.uniq
    assert_equal trace, serialized.dig("rails_mind_context", "trace_id")
    assert_equal [ "user-1" ], events.map { |event| event["user_id"] }.uniq
    assert_equal [ "request-1" ], events.map { |event| event["request_id"] }.uniq
    assert_equal %w[enqueue perform_start perform], lifecycle.map { |event| event.dig("properties", "operation") }
    assert_equal %w[span span job], lifecycle.map { |event| event["kind"] }
    assert_equal %w[enqueued started ok], lifecycle.map { |event| event["status"] }
    lifecycle.each do |event|
      assert_equal 1, event.dig("properties", "schema_version")
      assert_equal "LifecycleJob", event.dig("properties", "job_class")
      assert_equal job.job_id, event["job_id"]
      refute event.key?("span_id")
      refute event.key?("parent_span_id")
    end
    refute_includes JSON.generate(events), "private-argument"
    assert_empty RailsMind::Context.snapshot
  end

  def test_aborted_callbacks_are_not_reported_as_successful
    assert_equal false, AbortedEnqueueJob.perform_later
    enqueue = operation("enqueue")
    assert_equal "aborted", enqueue["status"]
    assert_empty LifecycleJob.queue_adapter.enqueued_jobs

    @memory.events.clear
    AbortedPerformJob.perform_now
    assert_equal "started", operation("perform_start")["status"]
    assert_equal "aborted", operation("perform")["status"]
    assert_empty @memory.events.select { |event| event["kind"] == "event" }
    assert_empty RailsMind::Context.snapshot
  end

  def test_adapter_rejection_and_exception_do_not_claim_enqueued
    adapter = Object.new
    def adapter.enqueue(*) = raise(ActiveJob::EnqueueError, "private-adapter-message")
    def adapter.enqueue_at(*) = enqueue
    LifecycleJob.queue_adapter = adapter
    assert_equal false, LifecycleJob.perform_later("private-argument")
    assert_equal "error", operation("enqueue")["status"]
    refute_includes JSON.generate(@memory.events), "private-adapter-message"

    @memory.events.clear
    unexpected_adapter = Object.new
    def unexpected_adapter.enqueue(*) = raise(RuntimeError, "private-unexpected-message")
    def unexpected_adapter.enqueue_at(*) = enqueue
    LifecycleJob.queue_adapter = unexpected_adapter
    assert_raises(RuntimeError) { LifecycleJob.perform_later }
    assert_equal "error", operation("enqueue")["status"]
    refute_includes JSON.generate(@memory.events), "private-unexpected-message"
    assert_empty RailsMind::Context.snapshot
  end

  def test_scheduled_wait_is_separate_from_eligible_queue_delay
    job = LifecycleJob.set(wait_until: Time.now + 60).perform_later
    enqueue = operation("enqueue_at")
    assert_equal "enqueued", enqueue["status"]
    assert Time.iso8601(enqueue.dig("properties", "scheduled_at"))
    serialized = job.serialize
    serialized["enqueued_at"] = (Time.now - 120).utc.iso8601(6)
    serialized["scheduled_at"] = (Time.now - 5).utc.iso8601(6)
    ActiveJob::Base.execute(serialized)

    %w[perform_start perform].each do |name|
      properties = operation(name)["properties"]
      assert_in_delta 120_000, properties["queue_delay_ms"], 1000
      assert_in_delta 5000, properties["eligible_queue_delay_ms"], 1000
      assert_equal serialized["enqueued_at"], properties["enqueued_at"]
      assert_equal serialized["scheduled_at"], properties["scheduled_at"]
    end
  end

  def test_immediate_jobs_do_not_invent_a_scheduled_time_or_eligible_delay
    LifecycleJob.perform_now
    properties = operation("perform")["properties"]
    refute properties.key?("enqueued_at")
    refute properties.key?("scheduled_at")
    refute properties.key?("queue_delay_ms")
    refute properties.key?("eligible_queue_delay_ms")
  end

  def test_retry_preserves_trace_and_original_execution_timing
    job = nil
    RailsMind.with_context(request_id: "request-2", user_id: "user-2") do
      job = RetriedLifecycleJob.perform_later
    end
    serialized = job.serialize
    serialized["enqueued_at"] = (Time.now - 5).utc.iso8601(6)
    ActiveJob::Base.execute(serialized)

    trace = serialized.dig("rails_mind_context", "trace_id")
    retry_job = LifecycleJob.queue_adapter.enqueued_jobs.last
    assert_equal trace, retry_job.dig("rails_mind_context", "trace_id")
    assert_equal "user-2", retry_job.dig("rails_mind_context", "user_id")
    assert_equal [ trace ], @memory.events.map { |event| event["trace_id"] }.uniq
    assert_equal "error", operation("enqueue_retry")["status"]
    assert_in_delta 5000, operation("perform").dig("properties", "queue_delay_ms"), 1000
    assert_equal serialized["enqueued_at"], operation("perform").dig("properties", "enqueued_at")
    assert_empty RailsMind::Context.snapshot

    @memory.events.clear
    assert_raises(RuntimeError) { ActiveJob::Base.execute(retry_job) }
    assert_equal "error", operation("retry_stopped")["status"]
    assert_equal "error", operation("perform")["status"]
    assert_equal [ trace ], @memory.events.map { |event| event["trace_id"] }.uniq
    assert_empty RailsMind::Context.snapshot
  end

  def test_discard_and_perform_failure_stay_correlated_without_error_content
    DiscardedLifecycleJob.perform_now("private-argument")
    assert_equal "error", operation("discard")["status"]
    trace = operation("perform")["trace_id"]
    assert_equal [ trace ], @memory.events.map { |event| event["trace_id"] }.uniq
    refute_includes JSON.generate(@memory.events), "private-job-message"
    refute_includes JSON.generate(@memory.events), "private-argument"
    assert_empty RailsMind::Context.snapshot
  end

  def test_reused_job_resets_start_time_and_restores_outer_context
    job = LifecycleJob.new
    RailsMind.with_context(user_id: "outer") do
      job.perform_now
      job.rails_mind_started_at = Time.now - 600
      job.perform_now
      assert_equal "outer", RailsMind::Context.snapshot[:user_id]
      assert_nil RailsMind::Context.snapshot[:trace_id]
    end
    assert_operator job.rails_mind_started_at, :>, Time.now - 10
    assert_equal [ 1, 2 ], lifecycle.select { |event| event.dig("properties", "operation") == "perform" }
      .map { |event| event.dig("properties", "executions") }
    assert_empty RailsMind::Context.snapshot
  end

  def test_suppression_and_apm_opt_out_apply_to_new_lifecycle_signals
    RailsMind::Context.suppress do
      job = LifecycleJob.perform_later
      ActiveJob::Base.execute(job.serialize)
    end
    assert_empty @memory.events
    @config.apm = false
    job = LifecycleJob.perform_later
    ActiveJob::Base.execute(job.serialize)
    assert_empty lifecycle
    assert_equal [ "event" ], @memory.events.map { |event| event["kind"] }
  end

  def test_otel_context_overrides_native_and_survives_serialization
    require "opentelemetry/sdk"
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    job = nil
    trace = nil
    span_id = nil
    RailsMind.with_context(trace_id: "explicit-native") do
      provider.tracer("lifecycle-test").in_span("request") do |span|
        trace = span.context.hex_trace_id
        span_id = span.context.hex_span_id
        job = LifecycleJob.perform_later
      end
      assert_equal "explicit-native", RailsMind::Context.snapshot[:trace_id]
    end
    serialized = job.serialize
    assert_equal trace, serialized.dig("rails_mind_context", "trace_id")
    assert_equal span_id, serialized.dig("rails_mind_context", "span_id")
    ActiveJob::Base.execute(serialized)
    assert_equal [ trace ], @memory.events.map { |event| event["trace_id"] }.uniq
    assert_equal [ span_id ], @memory.events.map { |event| event["span_id"] }.uniq
    assert_empty RailsMind::Context.snapshot
  rescue LoadError => error
    skip "Optional OpenTelemetry gem unavailable: #{error.message}"
  end

  private

  def lifecycle
    @memory.events.select { |event| event.dig("properties", "instrumentation") == "active_job" }
  end

  def operation(name)
    lifecycle.find { |event| event.dig("properties", "operation") == name }
  end
end
