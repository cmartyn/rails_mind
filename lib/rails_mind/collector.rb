module RailsMind
  class Collector
    def initialize(config, transport: Transport.new(config), autostart: true)
      @config, @transport, @autostart = config, transport, autostart
      reset_process
    end

    def push(event)
      check_process
      event = event.transform_keys(&:to_s)
      @mutex.synchronize do
        if @closed
          drop(event["kind"], :closed)
          return false
        end
        selected, observation = @sampling.consider(event)
        unless selected
          start_worker if @autostart
          return false
        end
        json = JSON.generate(event)
        reason = if json.bytesize > @config.max_event_bytes || json.bytesize + 13 > @config.max_batch_bytes then :oversize
        elsif @queue.size + @in_flight >= @config.queue_capacity then :overflow
        end
        if reason
          @sampling.queue_dropped(observation)
          drop(event["kind"], reason)
          start_worker if @autostart
          return false
        end
        @queue << [ json.freeze, event["kind"] ]
        @stats[:enqueued] += 1
        start_worker if @autostart
        @condition.broadcast if @queue.size >= @config.batch_size
        true
      end
    end

    def stats
      check_process
      @mutex.synchronize { @stats.merge(queued: @queue.size, in_flight: @in_flight, losses: @losses.dup, sampling: @sampling.stats) }
    end

    def flush(timeout: @config.shutdown_timeout)
      check_process
      deadline = monotonic + timeout
      @mutex.synchronize do
        start_worker
        @force_flush = @force_report = true
        @condition.broadcast
        while @queue.any? || @in_flight.positive? || @active_report || @sampling.pending?
          remaining = deadline - monotonic
          return false if remaining <= 0
          @condition.wait(@mutex, remaining)
        end
        true
      end
    end

    def shutdown(timeout: @config.shutdown_timeout)
      check_process
      @mutex.synchronize { @closed = true }
      success = flush(timeout: timeout)
      @mutex.synchronize { @stopping = true; @condition.broadcast }
      @worker&.join(0.05)
      unless success
        @worker&.kill
        @worker&.join
        @mutex.synchronize do
          @queue.each { |_, kind| drop(kind, :shutdown) }
          @queue.clear
          @active_batch.to_a.each { |_, kind| unconfirmed(kind) }
          @active_batch = @active_report = nil
          @in_flight = 0
          @sampling.discard!
        end
      end
      success
    end

    private

    def reset_process
      @pid = Process.pid
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @queue, @losses = [], Hash.new(0)
      @stats = { enqueued: 0, delivered: 0, dropped: 0, delivery_unconfirmed: 0, retried: 0 }
      @sampling = Sampling.new(@config)
      @in_flight = 0
      @worker = @active_batch = @active_report = nil
      @closed = @stopping = @force_flush = @force_report = false
    end

    # No inherited observations, report IDs, policies or locked mutexes survive
    # a Puma/worker fork. Each child refreshes the same environment-wide policy.
    def check_process
      reset_process if @pid != Process.pid
    end
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def start_worker
      return if @worker&.alive?
      @worker = Thread.new { run }
      @worker.name = "rails_mind"
      @worker.report_on_exception = false
    end

    def run
      loop do
        refresh = @mutex.synchronize do
          @condition.wait(@mutex, @config.flush_interval) if @queue.size < @config.batch_size && !@force_flush && !@stopping
          return if @stopping && @queue.empty?
          due = @sampling.policy_due? && @transport.respond_to?(:fetch_sampling_policy)
          @sampling.policy_requested! if due
          due
        end
        refresh_policy if refresh
        batch, body = @mutex.synchronize { take_batch }
        next unless body
        result = deliver(body, report_id: @active_report)
        @mutex.synchronize do
          if result
            @stats[:delivered] += batch.size
          else
            batch.each { |_, kind| unconfirmed(kind) }
          end
          @in_flight = 0
          @active_batch = @active_report = nil
          @force_flush = false if @queue.empty? && !@sampling.pending?
          @condition.broadcast
        end
      end
    end

    def take_batch
      @sampling.rotate(force: @force_report, byte_budget: @config.max_batch_bytes - 64)
      report = @sampling.report(force: @force_report)
      @force_report = false if @sampling.supported?
      batch = []
      report_json = report && JSON.generate(report)
      bytes = 13 + (report_json ? 19 + report_json.bytesize : 0)
      while batch.size < @config.batch_size && @queue.any?
        entry = @queue.first
        break if bytes + entry.first.bytesize + (batch.empty? ? 0 : 1) > @config.max_batch_bytes
        bytes += entry.first.bytesize + (batch.empty? ? 0 : 1)
        batch << @queue.shift
      end
      if batch.empty? && !report
        @force_flush = false
        @condition.broadcast
        return [ [], nil ]
      end
      @in_flight = batch.size
      @active_batch = batch
      @active_report = report && report["id"]
      @sampling.report_sent! if report
      body = '{"events":[' + batch.map(&:first).join(",") + ']'
      body += ',"sampling_report":' + report_json if report_json
      [ batch, (body + '}').freeze ]
    end

    def refresh_policy
      result = @transport.fetch_sampling_policy
      @mutex.synchronize { @sampling.apply_policy(result.sampling_policy) }
    rescue StandardError
      nil # Missing/expired controls fall back to unsampled collection.
    end

    def deliver(body, report_id:)
      attempts = 0
      loop do
        result = @transport.send_batch(body)
        @mutex.synchronize do
          @sampling.apply_policy(result.sampling_policy) if result.respond_to?(:sampling_policy)
          @sampling.acknowledge(result.sampling_report_ack) if report_id && result.respond_to?(:sampling_report_ack) && result.sampling_report_ack == report_id
        end
        return true if result.success
        return false unless result.retryable && attempts < @config.max_retries
        delay = result.retry_after || @config.retry_base * (2**attempts) * (0.75 + rand * 0.5)
        attempts += 1
        @mutex.synchronize { @stats[:retried] += 1 }
        sleep(delay) if delay.positive?
      end
    rescue StandardError
      false
    end

    def unconfirmed(kind)
      @stats[:delivery_unconfirmed] += 1
      @losses["#{kind}.delivery_unconfirmed"] += 1
    end

    def drop(kind, reason)
      @stats[:dropped] += 1
      @losses["#{kind}.#{reason}"] += 1
    end
  end
end
