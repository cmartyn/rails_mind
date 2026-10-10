require "json"
require "securerandom"
require "time"
require "digest"

module RailsMind
  # Called under Collector's mutex. Decisions and queue-loss accounting share
  # the same critical section as report rotation; reports are immutable once cut.
  class Sampling
    REPORT_INTERVAL = 60
    POLICY_INTERVAL = 60
    MAX_POLICY_TTL = 600
    MAX_ENDPOINTS = 100
    MAX_PENDING = 5
    MAX_COUNT = 1_000_000_000
    MAX_REPORT_AGE = 7 * 86_400
    ENDPOINT = /\A[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*#[A-Za-z_][A-Za-z0-9_!?]*\z/
    UUID = /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i

    def initialize(config, clock: -> { Time.now.utc }, monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @config, @clock, @monotonic = config, clock, monotonic
      @counts, @reports = {}, []
      @from = @clock.call
      @last_rotation = @monotonic.call
      @next_policy_at = @next_report_at = 0
      @policy = nil
      @activated = false
      @limited = false
      @policy_ids = []
      @stats = { observed: 0, retained: 0, sampled_out: 0, queue_dropped: 0, unreported: 0, reports_lost: 0 }
    end

    def consider(event)
      return [ true, nil ] unless event["kind"] == "request"
      @activated = true
      rate, state, policy_id = effective_policy
      name = event["name"]
      unless eligible?(event) && name.is_a?(String) && name.bytesize <= 200 && name.match?(ENDPOINT)
        annotate(event, 1.0, "protected", policy_id)
        return [ true, nil ]
      end
      if !@counts.key?(name) && @counts.size >= MAX_ENDPOINTS
        @stats[:unreported] += 1
        @limited = true
        annotate(event, 1.0, "unavailable", policy_id)
        return [ true, nil ]
      end
      count = @counts[name] ||= { "name" => name, "observed" => 0, "retained" => 0, "sampled_out" => 0, "queue_dropped" => 0 }
      if count["observed"] >= MAX_COUNT
        @stats[:unreported] += 1
        @limited = true
        annotate(event, 1.0, "unavailable", policy_id)
        return [ true, nil ]
      end
      rate = @policy[:endpoints].fetch(name, rate) if state == "active"
      selected = rate >= 1 || (rate.positive? && fraction(event["id"]) < rate)
      count["observed"] += 1
      count[selected ? "retained" : "sampled_out"] += 1
      @stats[:observed] += 1
      @stats[selected ? :retained : :sampled_out] += 1
      @policy_ids << (policy_id || state) unless @policy_ids.include?(policy_id || state) || @policy_ids.size >= 2
      annotate(event, rate, state, policy_id) if selected
      [ selected, count ]
    end

    def queue_dropped(count)
      return unless count
      count["queue_dropped"] += 1
      @stats[:queue_dropped] += 1
    end

    def apply_policy(value)
      return false unless value.is_a?(Hash) && value["version"] == 1 && boolean?(value["enabled"])
      id = value["id"]
      return false unless id.is_a?(String) && id.bytesize.between?(1, 200) && !id.match?(/\p{Cc}/)
      issued = parse_time(value["issued_at"])
      expires = parse_time(value["expires_at"])
      now = @clock.call
      return false unless issued && expires && issued <= now + 300 && expires > now && expires > issued && expires - issued <= MAX_POLICY_TTL
      return false if @policy && issued < @policy[:issued_at]
      rate = value["default_rate"]
      rows = value["endpoints"]
      return false unless valid_rate?(rate) && rows.is_a?(Array) && rows.size <= MAX_ENDPOINTS
      endpoints = {}
      rows.each do |row|
        return false unless row.is_a?(Hash) && row["name"].is_a?(String) && row["name"].bytesize.between?(1, 800) && row["name"].length <= 200 && !row["name"].match?(/\p{Cc}/) && valid_rate?(row["rate"])
        return false if endpoints.key?(row["name"])
        endpoints[row["name"]] = row["rate"].to_f
      end
      @policy = { id: id, issued_at: issued, expires_at: expires, deadline: @monotonic.call + [ expires - now, MAX_POLICY_TTL ].min,
        enabled: value["enabled"], default_rate: rate.to_f, endpoints: endpoints }
      true
    rescue ArgumentError, EncodingError
      false
    end

    def policy_due?
      @activated && @monotonic.call >= @next_policy_at
    end

    def policy_requested!
      @next_policy_at = @monotonic.call + POLICY_INTERVAL
    end

    def rotate(force: false, byte_budget:)
      return unless supported?
      now = @clock.call
      while @reports.first && Time.iso8601(@reports.first.fetch("from")) < now - MAX_REPORT_AGE
        @reports.shift
        @stats[:reports_lost] += 1
        @limited = true
      end
      return if @counts.empty? || (!force && @monotonic.call - @last_rotation < REPORT_INTERVAL)
      if now < @from || now - @from > 86_400
        @stats[:unreported] += @counts.values.sum { |entry| entry["observed"] }
        @limited = true
      else
        rows = []
        template = { "version" => 1, "limited" => @limited, "id" => SecureRandom.uuid, "from" => @from.iso8601(6), "to" => now.iso8601(6),
          "enabled" => @config.automatic_sampling, "policy_id" => @policy_ids.size == 1 ? @policy_ids.first : "mixed", "endpoints" => rows }
        @counts.each_value do |entry|
          candidate = template.merge("endpoints" => rows + [ entry ])
          if JSON.generate(candidate).bytesize > byte_budget
            store_report(template.merge("endpoints" => rows)) if rows.any?
            rows = []
            template = template.merge("id" => SecureRandom.uuid)
          end
          if JSON.generate(template.merge("endpoints" => [ entry ])).bytesize <= byte_budget
            rows << entry.dup
          else
            @stats[:unreported] += entry["observed"]
            @limited = true
          end
        end
        store_report(template.merge("endpoints" => rows)) if rows.any?
      end
      @counts, @policy_ids = {}, []
      @from, @last_rotation = now, @monotonic.call
    end

    def report(force: false)
      @reports.first if force || @monotonic.call >= @next_report_at
    end

    def report_sent!
      @next_report_at = @monotonic.call + REPORT_INTERVAL
    end

    def acknowledge(id)
      return unless id.is_a?(String) && id.match?(UUID)
      removed = @reports.reject! { |report| report["id"] == id }
      @next_report_at = 0 if removed && @reports.any?
    end

    def discard!
      @stats[:reports_lost] += @reports.size
      @stats[:unreported] += @counts.values.sum { |entry| entry["observed"] }
      @reports, @counts = [], {}
    end

    def supported? = !@policy.nil?
    def pending? = supported? && (@reports.any? || @counts.any?)
    def stats = @stats.merge(limited: @limited, pending_reports: @reports.size, policy_state: effective_policy[1], policy_id: @policy&.fetch(:id))

    private

    def eligible?(event)
      status, duration = event["status"], event["duration_ms"]
      repeated = event.fetch("properties", {})["repeated_query_count"]
      status.is_a?(String) && status.match?(/\A[23][0-9]{2}\z/) && duration.is_a?(Numeric) && duration.finite? && duration >= 0 && duration < 1000 && !(repeated.is_a?(Numeric) && repeated >= 3)
    end

    def effective_policy
      return [ 1.0, "disabled", @policy&.fetch(:id) ] unless @config.automatic_sampling
      return [ 1.0, "unavailable", nil ] unless @policy
      return [ 1.0, "expired", @policy[:id] ] if @monotonic.call >= @policy[:deadline] || @clock.call >= @policy[:expires_at]
      return [ 1.0, "disabled", @policy[:id] ] unless @policy[:enabled]
      [ @policy[:default_rate], "active", @policy[:id] ]
    end

    def annotate(event, rate, state, policy_id)
      event["properties"] = event.fetch("properties", {}).merge("rails_mind_sampling" => {
        "version" => 1, "policy_id" => policy_id, "rate" => rate, "state" => state })
    end

    def store_report(report)
      if @reports.size >= MAX_PENDING
        @reports.shift
        @stats[:reports_lost] += 1
        @limited = true
      end
      report["limited"] ||= @limited
      @reports << deep_freeze(JSON.parse(JSON.generate(report)))
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, child| deep_freeze(key); deep_freeze(child) }
      when Array then value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end

    def fraction(id) = Digest::SHA256.digest("rails_mind:sampling:v1:#{id.to_s.downcase}").unpack1("Q>") / (2.0**64)
    def boolean?(value) = value == true || value == false
    def valid_rate?(value) = (value.is_a?(Float) || value.is_a?(Integer)) && value.finite? && value.between?(0, 1)
    def parse_time(value)
      Time.iso8601(value) if value.is_a?(String) && value.bytesize <= 40
    end
  end
end
