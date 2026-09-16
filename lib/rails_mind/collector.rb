module RailsMind
  class Collector
    def initialize(config, transport: Transport.new(config), autostart: true)
      @config, @transport, @autostart = config, transport, autostart
      reset_process
    end

    def push(event)
      check_process
      json = JSON.generate(event)
      @mutex.synchronize do
        reason = if @closed then :closed
        elsif json.bytesize > @config.max_event_bytes || json.bytesize + 13 > @config.max_batch_bytes then :oversize
        elsif @queue.size + @in_flight >= @config.queue_capacity then :overflow
        end
        if reason
          drop(event[:kind] || event["kind"], reason)
          return false
        end
        @queue << [ json.freeze, event[:kind] || event["kind"] ]
        @stats[:enqueued] += 1
        start_worker if @autostart
        @condition.broadcast if @queue.size >= @config.batch_size
        true
      end
    end

    def stats
      check_process
      @mutex.synchronize { @stats.merge(queued: @queue.size, in_flight: @in_flight, losses: @losses.dup) }
    end

    def flush(timeout: @config.shutdown_timeout)
      check_process
      deadline = monotonic + timeout
      @mutex.synchronize do
        start_worker
        @force_flush = true
        @condition.broadcast
        while @queue.any? || @in_flight.positive?
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
          @active_batch.to_a.each { |_, kind| drop(kind, :shutdown) }
          @active_batch = nil
          @in_flight = 0
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
      @stats = { enqueued: 0, delivered: 0, dropped: 0, retried: 0 }
      @in_flight = 0
      @worker = @active_batch = nil
      @closed = @stopping = @force_flush = false
    end

    # Never resend a parent's inherited queue after Puma/worker forks.
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
        batch = @mutex.synchronize do
          @condition.wait(@mutex, @config.flush_interval) if @queue.size < @config.batch_size && !@force_flush && !@stopping
          return if @stopping && @queue.empty?
          take_batch
        end
        next if batch.empty?
        result = deliver(batch)
        @mutex.synchronize do
          if result
            @stats[:delivered] += batch.size
          else
            batch.each { |_, kind| drop(kind, :delivery) }
          end
          @in_flight = 0
          @active_batch = nil
          @force_flush = false if @queue.empty?
          @condition.broadcast
        end
      end
    end

    def take_batch
      batch = []
      bytes = 13
      while batch.size < @config.batch_size && @queue.any?
        entry = @queue.first
        break if bytes + entry.first.bytesize + (batch.empty? ? 0 : 1) > @config.max_batch_bytes
        bytes += entry.first.bytesize + (batch.empty? ? 0 : 1)
        batch << @queue.shift
      end
      @in_flight = batch.size
      @active_batch = batch
      batch
    end

    def deliver(batch)
      body = '{"events":[' + batch.map(&:first).join(",") + ']}'
      attempts = 0
      loop do
        result = @transport.send_batch(body)
        return true if result.success
        return false unless result.retryable && attempts < @config.max_retries
        delay = result.retry_after || @config.retry_base * (2**attempts) * (0.75 + rand * 0.5)
        attempts += 1
        @mutex.synchronize { @stats[:retried] += 1 }
        sleep(delay) if delay.positive?
      end
    rescue StandardError
      false # Telemetry errors cannot escape into the customer app.
    end

    def drop(kind, reason)
      @stats[:dropped] += 1
      @losses["#{kind}.#{reason}"] += 1
    end
  end
end
