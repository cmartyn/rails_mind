require "active_support/notifications"
require "digest"

module RailsMind
  module Integrations
    class ErrorSubscriber
      def report(error, handled:, severity:, context:, source: nil, **options)
        RailsMind.capture_exception(error, handled: handled, severity: severity, context: context, source: source)
      end
    end

    class RequestContext
      def initialize(app) = @app = app

      def call(env)
        Context.with(request_id: env["action_dispatch.request_id"] || SecureRandom.uuid) do
          Context.with_trace do
            previous = Thread.current[:rails_mind_queries]
            Thread.current[:rails_mind_queries] = { count: 0, fingerprints: Hash.new(0) }
            @app.call(env)
          rescue StandardError => error
            # Capture identity before this request boundary unwinds. Object
            # dedup still leaves other error reporters unaffected.
            RailsMind.capture_exception(error, source: "rack")
            raise
          ensure
            Thread.current[:rails_mind_queries] = previous
          end
        end
      end
    end

    module JobContext
      def self.included(base)
        base.around_enqueue do |job, block|
          Context.with_trace do
            job.rails_mind_context = Context.effective_snapshot.transform_keys(&:to_s)
            block.call
          end
        end
        base.around_perform do |job, block|
          job.rails_mind_started_at ||= Time.now
          Context.with((job.rails_mind_context || {}).merge("job_id" => job.job_id)) do
            Context.with_trace do
              job.rails_mind_context = Context.effective_snapshot.transform_keys(&:to_s)
              block.call
            end
          end
        end
      end

      attr_accessor :rails_mind_context, :rails_mind_started_at, :rails_mind_execution_timing

      # ActiveJob runs retry/discard handlers after around_perform has unwound.
      # Keep the restored boundary around the entire execution so those handlers
      # and their newly serialized attempts retain the originating trace.
      def perform_now(...)
        self.rails_mind_started_at = nil
        self.rails_mind_execution_timing = nil
        Context.with((rails_mind_context || {}).merge("job_id" => job_id)) do
          Context.with_trace do
            self.rails_mind_context = Context.effective_snapshot.transform_keys(&:to_s)
            super
          end
        end
      end

      def serialize = super.merge("rails_mind_context" => rails_mind_context || {})

      def deserialize(job_data)
        super
        self.rails_mind_context = (job_data["rails_mind_context"] || {}).slice(*Context::KEYS.map(&:to_s))
      end
    end

    module RailsNotifications
      class << self
        def install!
          return if @subscriptions
          @subscriptions = []
          subscribe("process_action.action_controller") do |event|
            payload = event.payload
            queries = Thread.current[:rails_mind_queries]
            counts = queries&.fetch(:fingerprints, {}) || {}
            status = payload[:status] || (payload[:exception] ? 500 : 200)
            RailsMind.client.emit(:request, "#{payload[:controller]}##{payload[:action]}", duration_ms: event.duration,
              status: status.to_s, properties: { controller: payload[:controller], action: payload[:action],
                method: payload[:method], view_runtime: payload[:view_runtime], db_runtime: payload[:db_runtime],
                query_count: queries&.fetch(:count), repeated_query_count: counts.values.sum { |n| [ n - 1, 0 ].max },
                query_fingerprints: counts.sort_by { |_, count| -count }.first(10).to_h })
          end
          subscribe("sql.active_record") do |event|
            queries = Thread.current[:rails_mind_queries]
            next unless queries && !event.payload[:cached] && !%w[SCHEMA TRANSACTION].include?(event.payload[:name])
            queries[:count] += 1
            # Normalize locally, transmit only one-way hashes; never SQL or binds.
            normalized = event.payload[:sql].to_s[0, 16_384].gsub(/'(?:[^']|'')*'/, "?").gsub(/\b\d+\b/, "?").gsub(/\s+/, " ")
            fingerprint = Digest::SHA256.hexdigest(normalized)[0, 24]
            queries[:fingerprints][fingerprint] += 1 if queries[:fingerprints].key?(fingerprint) || queries[:fingerprints].size < 100
          end
          %w[enqueue.active_job enqueue_at.active_job perform_start.active_job perform.active_job enqueue_retry.active_job retry_stopped.active_job discard.active_job].each do |name|
            subscribe(name) do |event|
              job = event.payload[:job]
              next unless job
              operation = name.split(".").first
              enqueue = %w[enqueue enqueue_at].include?(operation)
              error = event.payload[:exception_object] || event.payload[:error] || (job.enqueue_error if enqueue)
              if operation == "perform_start"
                job.rails_mind_started_at = Time.now
                job.rails_mind_execution_timing = { enqueued_at: job.enqueued_at, scheduled_at: job.scheduled_at }
              end
              # A callback may abort before the SDK's around_enqueue is entered.
              values = job.rails_mind_context || Context.effective_snapshot
              Context.with(values.merge("job_id" => job.job_id)) do
                Context.with_trace do
                  job.rails_mind_context = Context.effective_snapshot.transform_keys(&:to_s)
                  status = if error
                    "error"
                  elsif event.payload[:aborted]
                    "aborted"
                  elsif enqueue
                    "enqueued"
                  elsif operation == "perform_start"
                    "started"
                  else
                    operation == "perform" ? "ok" : operation
                  end
                  kind = enqueue || operation == "perform_start" ? :span : :job
                  RailsMind.client.emit(kind, job.class.name, duration_ms: event.duration, status: status,
                    properties: job_properties(job, operation))
                  RailsMind.capture_exception(error, source: "active_job") if error
                end
              end
            end
          end
          subscribe("feature_operation.flipper") do |event|
            payload = event.payload
            operation = payload[:operation].to_s
            result = payload[:result]
            RailsMind.client.emit(:flag, payload[:feature_name].to_s, duration_ms: event.duration,
              properties: { operation: operation, enabled: result == true ? true : (result == false ? false : nil),
                exposure: false })
          end
        end

        def uninstall!
          @subscriptions&.each { |subscription| ActiveSupport::Notifications.unsubscribe(subscription) }
          @subscriptions = nil
        end

        private

        def job_properties(job, operation)
          timing = if %w[perform_start perform].include?(operation)
            job.rails_mind_execution_timing || {}
          else
            { enqueued_at: job.enqueued_at, scheduled_at: job.scheduled_at }
          end
          enqueued_at, scheduled_at = timing.values_at(:enqueued_at, :scheduled_at)
          execution_timing = job.rails_mind_execution_timing || {}
          queued = execution_timing[:enqueued_at]
          scheduled = execution_timing[:scheduled_at]
          started = job.rails_mind_started_at
          properties = { instrumentation: "active_job", schema_version: 1, operation: operation,
            job_class: job.class.name, queue: job.queue_name, executions: job.executions,
            enqueued_at: enqueued_at&.iso8601(6), scheduled_at: scheduled_at&.iso8601(6) }
          unless %w[enqueue enqueue_at].include?(operation)
            properties[:queue_delay_ms] = [ (started.to_f - queued.to_f) * 1000, 0 ].max if started && queued
            if started && queued && scheduled
              properties[:eligible_queue_delay_ms] = [ (started.to_f - [ queued.to_f, scheduled.to_f ].max) * 1000, 0 ].max
            end
          end
          properties.compact
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
