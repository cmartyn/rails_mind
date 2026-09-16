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
          previous = Thread.current[:rails_mind_queries]
          Thread.current[:rails_mind_queries] = { count: 0, fingerprints: Hash.new(0) }
          @app.call(env)
        rescue StandardError => error
          # Preserve identity before this request boundary unwinds. The Rails
          # reporter may observe the same exception later; object dedup prevents
          # a second RailsMind event while other reporters remain unaffected.
          RailsMind.capture_exception(error, source: "rack")
          raise
        ensure
          Thread.current[:rails_mind_queries] = previous
        end
      end
    end

    module JobContext
      def self.included(base)
        base.around_enqueue do |job, block|
          job.rails_mind_context = Context.snapshot.transform_keys(&:to_s)
          block.call
        end
        base.around_perform do |job, block|
          job.rails_mind_started_at = Time.now
          Context.with((job.rails_mind_context || {}).merge("job_id" => job.job_id)) { block.call }
        end
      end

      attr_accessor :rails_mind_context, :rails_mind_started_at

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
          %w[perform.active_job enqueue_retry.active_job retry_stopped.active_job discard.active_job].each do |name|
            subscribe(name) do |event|
              job = event.payload[:job]
              next unless job
              error = event.payload[:exception_object] || event.payload[:error]
              Context.with((job.rails_mind_context || {}).merge("job_id" => job.job_id)) do
                RailsMind.client.emit(:job, job.class.name, duration_ms: event.duration,
                  status: error ? "error" : (name == "perform.active_job" ? "ok" : name.split(".").first),
                  properties: { operation: name.split(".").first, queue: job.queue_name, executions: job.executions,
                    queue_delay_ms: job.enqueued_at && job.rails_mind_started_at ? [ (job.rails_mind_started_at.to_f - job.enqueued_at.to_f) * 1000, 0 ].max : nil })
                RailsMind.capture_exception(error, source: "active_job") if error
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
