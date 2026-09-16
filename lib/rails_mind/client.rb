require "securerandom"
require "time"
require "digest"

module RailsMind
  class Client
    KINDS = %w[request span error event visit flag job check].freeze
    FIELDS = %i[id kind occurred_at name duration_ms status release trace_id span_id parent_span_id request_id job_id visitor_id user_id account_id properties].freeze
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
    attr_reader :config, :collector

    def initialize(config, collector: nil)
      @config = config.validate!
      @redactor = Redactor.new
      @collector = collector || (Collector.new(config) if config.enabled?)
      @error_mutex = Mutex.new
      @reported_errors = ObjectSpace::WeakMap.new
    end

    def emit(kind, name, properties: {}, **attributes)
      return false if !collector || Context.suppressed? || !enabled_signal?(kind)
      event = Context.snapshot.merge(otel_context).merge(attributes.slice(*FIELDS))
      event.merge!(kind: kind.to_s, name: name.to_s, properties: properties,
        id: stable_id(attributes[:id]), occurred_at: timestamp(attributes[:occurred_at]), release: config.release)
      event = event.reject { |_, value| value.nil? }
      check_id = event[:id] if kind.to_s == "check"
      event = @redactor.call(event)
      event = config.before_send.call(event) if config.before_send
      return false unless event.is_a?(Hash)
      # Hooks cannot add protocol keys or bypass the final redaction pass.
      event = @redactor.call(event.transform_keys(&:to_s).slice(*FIELDS.map(&:to_s)))
      if check_id
        return false unless event["kind"] == "check" && event["id"] == check_id
        event = event.slice("id", "kind", "occurred_at", "name", "properties")
        event["properties"] = event["properties"].slice("sdk_version") if event["properties"].is_a?(Hash)
      end
      return false unless valid_event?(event)
      collector.push(event)
    rescue StandardError
      false
    end

    def capture_exception(error, handled: false, severity: :error, context: {}, source: nil, **_options)
      return false unless config.errors
      # Rails reports an exception through more than one boundary. A weak key map
      # avoids retaining exceptions; identity dedup applies only to this object.
      @error_mutex.synchronize do
        return false if @reported_errors.key?(error)
        @reported_errors[error] = true
      end
      message = config.capture_exception_message ? @redactor.scrub(error.message.to_s) : "[Message omitted]"
      frames = Array(error.backtrace).first(40).map { |frame| safe_frame(frame) }
      Context.with(context.slice(*Context::KEYS)) do
        emit(:error, error.class.name, status: "error", properties: {
          exception_class: error.class.name, message: message, backtrace: frames,
          handled: handled, severity: severity.to_s, source: source
        })
      end
    rescue StandardError
      false
    end

    def stable_id(value = nil)
      return SecureRandom.uuid unless value
      return value.to_s.downcase if value.to_s.match?(UUID)
      # Deterministic UUID-shaped ID for existing Ahoy installations using ULIDs.
      hex = Digest::SHA256.hexdigest("rails_mind:#{value}")[0, 32]
      hex[12] = "8"
      hex[16] = "8"
      [ hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12] ].join("-")
    end

    private

    def valid_event?(event)
      return false unless KINDS.include?(event["kind"]) && event["id"].to_s.match?(UUID) && event["properties"].is_a?(Hash)
      return false unless event["name"].is_a?(String) && !event["name"].empty?
      # One malformed field must not poison a whole batch at the hosted boundary.
      (FIELDS - %i[duration_ms properties]).each do |field|
        key = field.to_s
        next if event[key].nil?
        return false unless event[key].is_a?(String)
        event[key] = event[key].byteslice(0, 500).scrub("")
      end
      event["name"] = event["name"][0, 200]
      Time.iso8601(event["occurred_at"])
      duration = event["duration_ms"]
      duration.nil? || ((duration.is_a?(Integer) || duration.is_a?(Float)) && duration.finite? && duration >= 0 && duration < 86_400_000)
    end

    def enabled_signal?(kind)
      case kind.to_s
      when "check" then true
      when "request", "span", "job" then config.apm
      when "error" then config.errors
      when "event", "visit" then config.analytics
      when "flag" then config.flags
      else false
      end
    end

    def timestamp(value)
      time = value.respond_to?(:iso8601) ? value : (value ? Time.iso8601(value.to_s) : Time.now)
      time.iso8601(6)
    end

    def safe_frame(frame)
      frame = frame.to_s
      frame = frame.delete_prefix("#{Rails.root}/") if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
      # Remove machine/user home paths, retaining source filename + line + method.
      frame = frame.sub(%r{\A.*?/(app|lib|config|test|spec)/}, '\\1/')
      frame = frame.sub(%r{\A/(?:[^/:]+/)*([^/:]+:\d+)}, '\\1')
      @redactor.scrub(frame)
    end

    def otel_context
      return {} unless defined?(::OpenTelemetry::Trace)
      context = ::OpenTelemetry::Trace.current_span.context
      return {} unless context.valid?
      { trace_id: context.hex_trace_id, span_id: context.hex_span_id }
    end
  end
end
