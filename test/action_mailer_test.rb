require_relative "test_helper"
require "action_mailer"
require "active_job"
require "rails_mind/integrations/rails"
require "rails_mind/integrations/action_mailer"

class LifecycleMailer < ActionMailer::Base
  include RailsMind::Integrations::MailerCallbacks
  default from: "sender-private@example.com"

  def welcome(secret = "argument-private")
    attachments["private-file.txt"] = "attachment-private"
    mail(to: [ "recipient-private@example.com", "other-private@example.com" ], subject: "subject-private", message_id: "message-private@example.com") do |format|
      format.text { render plain: "body-private #{secret}" }
    end
  end

  def render_failure
    raise ArgumentError, "render-private"
  end

  def nothing
  end
end

class AbortedLifecycleMailer < LifecycleMailer
  before_deliver(prepend: true) { throw :abort }
end

class FailedCallbackLifecycleMailer < LifecycleMailer
  before_deliver { raise ArgumentError, "callback-private" }
end

class FailedAfterCallbackLifecycleMailer < LifecycleMailer
  after_deliver { raise ArgumentError, "after-callback-private" }
end

class DisabledCallbackLifecycleMailer < LifecycleMailer
  before_deliver { message.perform_deliveries = false }
end

class SuppressedErrorCallbackLifecycleMailer < LifecycleMailer
  before_deliver { message.raise_delivery_errors = false }
end

class AuxiliaryCallbackLifecycleMailer < LifecycleMailer
  before_deliver(prepend: true) do
    auxiliary = Mail.new(from: "auxiliary-private@example.com", to: "auxiliary-private@example.com", subject: "auxiliary-private")
    auxiliary.delivery_method(:test)
    auxiliary.deliver!
  end
end

class AuxiliaryLifecycleInterceptor
  def self.delivering_email(message)
    return if message.subject == "auxiliary-private"
    auxiliary = Mail.new(from: "auxiliary-private@example.com", to: "auxiliary-private@example.com", subject: "auxiliary-private")
    auxiliary.delivery_method(:test)
    auxiliary.deliver!
  end
end

class LifecycleFailingTransport
  def initialize(_settings = {})
  end

  def deliver!(_mail)
    raise IOError, "transport-private"
  end
end

ActionMailer::Base.add_delivery_method(:lifecycle_failure, LifecycleFailingTransport)
ActionMailer::MessageDelivery.prepend(RailsMind::Integrations::MailerDeliveryContext)
Mail::Message.prepend(RailsMind::Integrations::ForcedMailerTransport)
ActionMailer::MailDeliveryJob.include(RailsMind::Integrations::JobContext)

class ActionMailerTest < SDKTest
  def setup
    super
    ActionMailer::Base.logger = nil
    ActiveJob::Base.logger = nil
    ActionMailer::MailDeliveryJob.queue_adapter = :test
    LifecycleMailer.delivery_method = :test
    LifecycleMailer.perform_deliveries = true
    LifecycleMailer.raise_delivery_errors = true
    ActionMailer::Base.deliveries.clear
    RailsMind::Integrations::RailsNotifications.install!
    RailsMind::Integrations::MailerNotifications.install!
  end

  def teardown
    RailsMind::Integrations::RailsNotifications.uninstall!
    RailsMind::Integrations::MailerNotifications.uninstall!
    assert_empty RailsMind::Context.snapshot
    assert_nil Thread.current[:rails_mind_mailer_attempt]
    super
  end

  def test_sync_delivery_has_correlated_bounded_metadata_and_no_message_content
    RailsMind.with_context(request_id: "request-1", account_id: "account-1") do
      LifecycleMailer.welcome.deliver_now
    end
    assert_equal 1, ActionMailer::Base.deliveries.size
    assert_equal %w[process delivery_attempt_completed], mail_events.map { |event| event.dig("properties", "operation") }
    process, delivery = mail_events
    assert_equal process["trace_id"], delivery["trace_id"]
    assert_match(/\A[0-9a-f]{32}\z/, delivery["trace_id"])
    assert_equal process.dig("properties", "attempt_id"), delivery.dig("properties", "attempt_id")
    assert_equal "request-1", delivery["request_id"]
    assert_equal "account-1", delivery["account_id"]
    assert_equal "LifecycleMailer", delivery.dig("properties", "mailer")
    assert_equal "welcome", delivery.dig("properties", "action")
    assert_equal "Mail::TestMailer", delivery.dig("properties", "delivery_method")
    assert_equal false, delivery.dig("properties", "forced")
    assert_equal true, delivery.dig("properties", "perform_deliveries")
    assert_equal true, delivery.dig("properties", "raise_delivery_errors")
    assert_equal "observed", delivery["status"]
    assert_equal "span", delivery["kind"]
    assert_equal "abc123", delivery["release"]
    assert_operator Time.iso8601(delivery["occurred_at"]), :>, Time.now - 60
    assert_private_content_absent
  end

  def test_disabled_delivery_is_observed_without_claiming_a_send
    LifecycleMailer.perform_deliveries = false
    LifecycleMailer.welcome.deliver_now
    assert_empty ActionMailer::Base.deliveries
    assert_equal "disabled", delivery_event["status"]
    assert_equal false, delivery_event.dig("properties", "perform_deliveries")
  end

  def test_suppressed_transport_error_stays_unknown_not_successful_delivery
    LifecycleMailer.delivery_method = :lifecycle_failure
    LifecycleMailer.raise_delivery_errors = false
    LifecycleMailer.welcome.deliver_now
    assert_equal "observed", delivery_event["status"]
    assert_equal false, delivery_event.dig("properties", "raise_delivery_errors")
    assert_equal "LifecycleFailingTransport", delivery_event.dig("properties", "delivery_method")
    assert_empty @memory.events.select { |event| event["kind"] == "error" }
    assert_private_content_absent
  end

  def test_raised_transport_failure_is_preserved_and_reported_once
    LifecycleMailer.delivery_method = :lifecycle_failure
    error = assert_raises(IOError) { LifecycleMailer.welcome.deliver_now }
    assert_equal "transport-private", error.message
    assert_equal "error", delivery_event["status"]
    assert_equal "IOError", delivery_event.dig("properties", "exception_class")
    assert_equal 1, @memory.events.count { |event| event["kind"] == "error" }
    assert_private_content_absent
  end

  def test_forced_delivery_bypasses_disabled_flag_without_mislabeling_it
    LifecycleMailer.perform_deliveries = false
    LifecycleMailer.welcome.deliver_now!
    assert_equal 1, ActionMailer::Base.deliveries.size
    assert_equal "observed", delivery_event["status"]
    assert_equal true, delivery_event.dig("properties", "forced")
    assert_equal false, delivery_event.dig("properties", "perform_deliveries")
  end

  def test_forced_failure_remains_raised_despite_raise_delivery_errors_false
    LifecycleMailer.delivery_method = :lifecycle_failure
    LifecycleMailer.raise_delivery_errors = false
    assert_raises(IOError) { LifecycleMailer.welcome.deliver_now! }
    assert_equal "error", delivery_event["status"]
    assert_equal true, delivery_event.dig("properties", "forced")
    assert_equal false, delivery_event.dig("properties", "raise_delivery_errors")
  end

  def test_aborted_callback_is_not_a_delivery_attempt
    assert_equal false, AbortedLifecycleMailer.welcome.deliver_now
    assert_empty ActionMailer::Base.deliveries
    assert_nil delivery_event
    outcome = mail_events.last
    assert_equal "delivery_not_observed", outcome.dig("properties", "operation")
    assert_equal "aborted", outcome["status"]
    assert_equal "welcome", outcome.dig("properties", "action")
  end

  def test_callback_failure_before_and_after_the_delivery_keeps_original_exception
    assert_raises(ArgumentError) { FailedCallbackLifecycleMailer.welcome.deliver_now }
    assert_nil delivery_event
    assert_equal "error", mail_events.last["status"]
    assert_equal "delivery_not_observed", mail_events.last.dig("properties", "operation")
    assert_equal 1, @memory.events.count { |event| event["kind"] == "error" }

    @memory.events.clear
    assert_raises(ArgumentError) { FailedAfterCallbackLifecycleMailer.welcome.deliver_now }
    assert_equal "observed", delivery_event["status"], "the attempt completed before an after-delivery callback failed"
    assert_equal 1, @memory.events.count { |event| event["kind"] == "error" }
    assert_private_content_absent
  end

  def test_render_failure_and_an_action_without_mail_do_not_become_delivery
    assert_raises(ArgumentError) { LifecycleMailer.render_failure.deliver_now }
    assert_nil delivery_event
    assert_equal %w[process delivery_not_observed], mail_events.map { |event| event.dig("properties", "operation") }
    assert_equal [ "error" ], mail_events.map { |event| event["status"] }.uniq
    assert_equal 1, @memory.events.count { |event| event["kind"] == "error" }

    @memory.events.clear
    LifecycleMailer.nothing.deliver_now
    assert_nil delivery_event
    assert_equal "unknown", mail_events.last["status"]
    assert_equal "delivery_not_observed", mail_events.last.dig("properties", "operation")
  end

  def test_rendering_for_a_direct_provider_never_invents_a_mailer_delivery
    LifecycleMailer.welcome.message
    assert_equal [ "process" ], mail_events.map { |event| event.dig("properties", "operation") }
    refute mail_events.first["properties"].key?("attempt_id")
    assert_empty ActionMailer::Base.deliveries
    assert_private_content_absent
  end

  def test_queued_mail_keeps_request_trace_identity_and_uses_new_attempt_id_per_invocation
    serialized = nil
    RailsMind.with_context(request_id: "r1", account_id: "a1", user_id: "u1") do
      RailsMind::Context.with_trace do
        job = LifecycleMailer.welcome("queued-private").deliver_later
        serialized = job.serialize
      end
    end
    ActiveJob::Base.execute(serialized)
    first = delivery_event
    assert_equal serialized.dig("rails_mind_context", "trace_id"), first["trace_id"]
    assert_equal serialized["job_id"], first["job_id"]
    assert_equal "a1", first["account_id"]
    assert_equal "u1", first["user_id"]
    assert_equal "r1", first["request_id"]
    ActiveJob::Base.execute(serialized)
    attempts = mail_events.select { |event| event.dig("properties", "operation") == "delivery_attempt_completed" }
    assert_equal 2, attempts.map { |event| event.dig("properties", "attempt_id") }.uniq.size
    assert_equal 1, attempts.map { |event| event["trace_id"] }.uniq.size
    assert_private_content_absent
  end

  def test_suppression_and_apm_opt_out_leave_mailer_behavior_unchanged
    RailsMind::Context.suppress { LifecycleMailer.welcome.deliver_now }
    assert_empty @memory.events
    @config.apm = false
    LifecycleMailer.welcome.deliver_now
    assert_empty @memory.events
    assert_equal 2, ActionMailer::Base.deliveries.size
  end

  def test_repeated_installation_does_not_duplicate_and_prepared_message_still_has_action
    RailsMind::Integrations::MailerNotifications.install!
    message = LifecycleMailer.welcome
    message.message
    @memory.events.clear
    message.deliver_now
    assert_equal 1, mail_events.size
    assert_equal "welcome", delivery_event.dig("properties", "action")
  end

  def test_forced_delivery_does_not_attribute_auxiliary_raw_mail_from_callbacks_or_interceptors
    AuxiliaryCallbackLifecycleMailer.welcome.deliver_now!
    assert_equal 2, ActionMailer::Base.deliveries.size
    assert_equal 1, mail_events.count { |event| event.dig("properties", "operation") == "delivery_attempt_completed" }
    assert_equal "AuxiliaryCallbackLifecycleMailer", delivery_event.dig("properties", "mailer")

    @memory.events.clear
    ActionMailer::Base.deliveries.clear
    Mail.register_interceptor(AuxiliaryLifecycleInterceptor)
    LifecycleMailer.welcome.deliver_now!
    assert_equal 2, ActionMailer::Base.deliveries.size
    assert_equal 1, mail_events.count { |event| event.dig("properties", "operation") == "delivery_attempt_completed" }
    assert_equal "LifecycleMailer", delivery_event.dig("properties", "mailer")
    assert_private_content_absent
  ensure
    Mail.unregister_interceptor(AuxiliaryLifecycleInterceptor)
  end

  def test_callback_changed_delivery_flags_describe_the_actual_attempt
    DisabledCallbackLifecycleMailer.welcome.deliver_now
    assert_equal "disabled", delivery_event["status"]
    assert_equal false, delivery_event.dig("properties", "perform_deliveries")
    assert_empty ActionMailer::Base.deliveries

    @memory.events.clear
    SuppressedErrorCallbackLifecycleMailer.delivery_method = :lifecycle_failure
    SuppressedErrorCallbackLifecycleMailer.welcome.deliver_now
    assert_equal "observed", delivery_event["status"]
    assert_equal false, delivery_event.dig("properties", "raise_delivery_errors")
    assert_empty @memory.events.select { |event| event["kind"] == "error" }
  ensure
    SuppressedErrorCallbackLifecycleMailer.delivery_method = :test
  end

  def test_collector_failure_cannot_change_delivery_return_or_replace_transport_exception
    broken_collector = Object.new
    def broken_collector.push(*) = raise(RuntimeError, "collector-private")
    RailsMind.client = RailsMind::Client.new(@config, collector: broken_collector)
    delivery = LifecycleMailer.welcome
    message = delivery.message
    assert_same message, delivery.deliver_now
    assert_equal 1, ActionMailer::Base.deliveries.size

    LifecycleMailer.delivery_method = :lifecycle_failure
    failure = assert_raises(IOError) { LifecycleMailer.welcome.deliver_now }
    assert_equal "transport-private", failure.message
    forced_failure = assert_raises(IOError) { LifecycleMailer.welcome.deliver_now! }
    assert_equal "transport-private", forced_failure.message
  ensure
    RailsMind.client = @client
  end

  def test_existing_otel_provider_context_and_exporter_are_preserved
    require "opentelemetry/sdk"
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    previous_provider = OpenTelemetry.tracer_provider
    trace = nil
    span_id = nil
    RailsMind.with_context(trace_id: "native-existing", user_id: "user-1") do
      provider.tracer("customer-mailer").in_span("customer-operation") do |span|
        trace = span.context.hex_trace_id
        span_id = span.context.hex_span_id
        LifecycleMailer.welcome.deliver_now
      end
      assert_equal "native-existing", RailsMind::Context.snapshot[:trace_id]
    end
    assert_equal [ trace ], mail_events.map { |event| event["trace_id"] }.uniq
    assert_equal [ span_id ], mail_events.map { |event| event["span_id"] }.uniq
    assert_equal [ "user-1" ], mail_events.map { |event| event["user_id"] }.uniq
    assert_equal 1, exporter.finished_spans.size
    assert_same previous_provider, OpenTelemetry.tracer_provider
  end

  private
    def mail_events
      @memory.events.select { |event| event.dig("properties", "instrumentation") == "action_mailer" }
    end

    def delivery_event
      mail_events.find { |event| event.dig("properties", "operation") == "delivery_attempt_completed" }
    end

    def assert_private_content_absent
      json = JSON.generate(@memory.events)
      %w[sender-private recipient-private other-private subject-private message-private body-private argument-private attachment-private private-file
        render-private callback-private after-callback-private transport-private queued-private auxiliary-private collector-private].each { |text| refute_includes json, text }
      mail_events.each do |event|
        assert_empty event.fetch("properties").keys & %w[to from cc bcc subject body mail message_id args params attachments]
      end
    end
end
