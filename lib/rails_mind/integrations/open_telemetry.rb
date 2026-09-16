require "opentelemetry/sdk"

module RailsMind
  module Integrations
    module OpenTelemetry
      SAFE_ATTRIBUTES = %w[http.request.method http.method http.response.status_code http.status_code http.route
        db.system db.system.name db.operation db.operation.name server.address server.port
        code.function code.namespace code.filepath code.lineno messaging.system messaging.destination.name].freeze

      # A local exporter: export only enqueues sanitized data in the shared bounded
      # collector. SimpleSpanProcessor therefore performs no application-thread I/O.
      class Exporter
        def export(spans, timeout: nil)
          return success if Context.suppressed?
          spans.each do |span|
            attributes = span.attributes || {}
            safe = attributes.slice(*SAFE_ATTRIBUTES)
            context = Context::KEYS.each_with_object({}) do |key, values|
              value = attributes["rails_mind.#{key}"]
              values[key] = value if value
            end
            RailsMind.client.emit(:span, safe_name(span, attributes), occurred_at: Time.at(Rational(span.start_timestamp, 1_000_000_000)).utc,
              duration_ms: (span.end_timestamp - span.start_timestamp) / 1_000_000.0,
              status: span.status.code == ::OpenTelemetry::Trace::Status::ERROR ? "error" : "ok",
              trace_id: span.trace_id.unpack1("H*"), span_id: span.span_id.unpack1("H*"),
              parent_span_id: span.parent_span_id.unpack1("H*"), properties: safe, **context.except(:trace_id, :span_id, :parent_span_id))
          end
          success
        rescue StandardError
          ::OpenTelemetry::SDK::Trace::Export::FAILURE
        end

        def force_flush(timeout: nil)
          RailsMind.flush(timeout: timeout || RailsMind.configuration.shutdown_timeout) ? success : ::OpenTelemetry::SDK::Trace::Export::TIMEOUT
        end

        # The SDK owns the collector lifetime; never shut down another provider.
        def shutdown(timeout: nil) = force_flush(timeout: timeout)

        private

        def success = ::OpenTelemetry::SDK::Trace::Export::SUCCESS

        def safe_name(span, attributes)
          if attributes["db.system"] || attributes["db.system.name"]
            "db.#{attributes['db.operation'] || attributes['db.operation.name'] || 'query'}"
          elsif attributes["http.route"]
            "#{attributes['http.request.method'] || attributes['http.method']} #{attributes['http.route']}"
          elsif attributes["http.method"] || attributes["http.request.method"]
            "http.#{attributes['http.request.method'] || attributes['http.method']}"
          else
            # Span names can contain URLs, SQL, or user strings. Scope is bounded
            # library metadata; customers can add reviewed code attributes instead.
            span.instrumentation_scope&.name || "span"
          end
        end
      end

      class ContextProcessor < ::OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor
        def on_start(span, parent_context)
          Context.snapshot.each { |key, value| span.set_attribute("rails_mind.#{key}", value.to_s) if value }
        rescue StandardError
          nil
        end
      end

      def self.attach!(provider: ::OpenTelemetry.tracer_provider)
        raise ArgumentError, "Configure an OpenTelemetry SDK provider first; RailsMind never replaces an existing provider" unless provider.respond_to?(:add_span_processor)
        return provider if provider.instance_variable_defined?(:@rails_mind_processor)
        processor = ContextProcessor.new(Exporter.new)
        provider.add_span_processor(processor)
        provider.instance_variable_set(:@rails_mind_processor, processor)
        provider
      end
    end
  end
end
