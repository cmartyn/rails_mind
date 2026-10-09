require "active_support/notifications"
require "securerandom"

module RailsMind
  module Integrations
    # Wrap the public delivery entry points without touching arguments or mail
    # contents. The stored class/action names are the only MessageDelivery state
    # read here; reading .message would prematurely render the lazy message.
    module MailerDeliveryContext
      def deliver_now
        MailerNotifications.observe_delivery(self, forced: false) { super }
      end

      def deliver_now!
        MailerNotifications.observe_delivery(self, forced: true) { super }
      end
    end

    module MailerCallbacks
      def self.included(base)
        base.around_deliver do |mailer, block|
          MailerNotifications.record_delivery_options(mailer)
          block.call
        end
      end
    end

    # Mail#deliver! bypasses ActionMailer's notification handler as well as its
    # delivery flags. Observe that public method only inside a known forced
    # ActionMailer invocation, preserving its return value and exceptions.
    module ForcedMailerTransport
      def deliver!(...)
        MailerNotifications.observe_forced_transport(self) { super }
      end
    end

    module MailerNotifications
      class << self
        def install!
          return if @subscriptions
          @subscriptions = []
          subscribe("process.action_mailer") do |event|
            payload = event.payload
            properties = metadata(payload[:mailer], payload[:action]).merge(operation: "process")
            properties[:attempt_id] = attempt[:attempt_id] if attempt
            emit(event, properties, status: event_error(event) ? "error" : "observed")
          end
          subscribe("deliver.action_mailer") do |event|
            current = attempt
            current[:observed] = true if current
            properties = metadata(event.payload[:mailer], current&.dig(:action)).merge(
              operation: "delivery_attempt_completed", attempt_id: current&.dig(:attempt_id) || SecureRandom.uuid)
            properties.merge!(delivery_options(current[:message])) if current
            properties[:forced] = current[:forced] if current
            properties[:perform_deliveries] = event.payload[:perform_deliveries] if [ true, false ].include?(event.payload[:perform_deliveries])
            status = if event_error(event) then "error"
            elsif properties[:perform_deliveries] == false && properties[:forced] == false then "disabled"
            else "observed"
            end
            emit(event, properties, status: status)
          end
        end

        def uninstall!
          @subscriptions&.each { |subscription| ActiveSupport::Notifications.unsubscribe(subscription) }
          @subscriptions = nil
        end

        def observe_delivery(delivery, forced:)
          current = new_attempt(delivery, forced: forced)
          return yield unless current

          previous = attempt
          Thread.current[:rails_mind_mailer_attempt] = current
          Context.with_trace do
            result = nil
            failure = nil
            begin
              result = yield
            rescue StandardError => error
              failure = error
              raise
            ensure
              finish_unobserved(current, result, failure)
              RailsMind.capture_exception(failure, source: "action_mailer") if failure
            end
          end
        ensure
          Thread.current[:rails_mind_mailer_attempt] = previous if current
        end

        # Configuration describes the attempted transport, never its recipients,
        # credentials, provider responses, or eventual delivery outcome.
        def record_delivery_options(mailer)
          return unless attempt
          attempt[:message] = mailer.message
        rescue StandardError
          nil
        end

        def observe_forced_transport(message)
          current = attempt
          # Callbacks/interceptors can send an unrelated raw Mail::Message while
          # this attempt is active. Only attribute the ActionMailer message that
          # our delivery callback recorded, never another message on the stack.
          return yield unless current && current[:forced] && current[:message].equal?(message)
          current[:observed] = true
          started_at = Time.now
          clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          failure = nil
          begin
            yield
          rescue StandardError => error
            failure = error
            raise
          ensure
            record_forced_transport(current, message, started_at, clock, failure)
          end
        end

        private
          def attempt = Thread.current[:rails_mind_mailer_attempt]

          def new_attempt(delivery, forced:)
            { mailer: delivery.instance_variable_get(:@mailer_class).name,
              action: delivery.instance_variable_get(:@action).to_s,
              forced: forced, attempt_id: SecureRandom.uuid, observed: false,
              started_at: Time.now, started_clock: Process.clock_gettime(Process::CLOCK_MONOTONIC) }
          rescue StandardError
            nil
          end

          def metadata(mailer, action)
            { instrumentation: "action_mailer", schema_version: 1, mailer: mailer, action: action }.reject { |_, value| value.nil? }
          end

          def delivery_options(message)
            return {} unless message.is_a?(::Mail::Message)
            { perform_deliveries: message.perform_deliveries, raise_delivery_errors: message.raise_delivery_errors,
              delivery_method: message.delivery_method.class.name }.reject { |_, value| value.nil? }
          rescue StandardError
            {}
          end

          def record_forced_transport(current, message, started_at, clock, failure)
            properties = metadata(current[:mailer], current[:action]).merge(delivery_options(message)).merge(
              operation: "delivery_attempt_completed", attempt_id: current[:attempt_id], forced: true)
            properties[:exception_class] = failure.class.name if failure
            RailsMind.client.emit(:span, "#{current[:mailer]}##{current[:action]} delivery_attempt_completed",
              occurred_at: started_at, duration_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - clock) * 1000,
              status: failure ? "error" : "observed", properties: properties)
            RailsMind.capture_exception(failure, source: "action_mailer") if failure
          rescue StandardError
            nil
          end

          def finish_unobserved(current, result, failure)
            return if current[:observed]
            properties = metadata(current[:mailer], current[:action]).merge(delivery_options(current[:message])).merge(
              operation: "delivery_not_observed", attempt_id: current[:attempt_id], forced: current[:forced])
            properties[:exception_class] = failure.class.name if failure
            status = failure ? "error" : (result == false ? "aborted" : "unknown")
            RailsMind.client.emit(:span, "#{current[:mailer]}##{current[:action]} delivery_not_observed",
              occurred_at: current[:started_at], duration_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - current[:started_clock]) * 1000,
              status: status, properties: properties)
          rescue StandardError
            nil
          end

          def event_error(event)
            event.payload[:exception_object] || event.payload[:error]
          end

          def emit(event, properties, status:)
            error = event_error(event)
            properties[:exception_class] = error.class.name if error
            Context.with_trace do
              label = [ properties[:mailer], properties[:action] ].compact.join("#")
              RailsMind.client.emit(:span, "#{label} #{properties[:operation]}",
                occurred_at: Time.now - event.duration / 1000, duration_ms: event.duration, status: status, properties: properties)
              RailsMind.capture_exception(error, source: "action_mailer") if error
            end
          end

          def subscribe(name, &callback)
            @subscriptions << ActiveSupport::Notifications.subscribe(name) do |event|
              callback.call(event) unless Context.suppressed?
            rescue StandardError
              nil
            end
          end
      end
    end
  end
end
