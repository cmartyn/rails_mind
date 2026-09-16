require "benchmark"
require_relative "lib/rails_mind"

class DiscardTransport
  def send_batch(_body) = RailsMind::Transport::Result.new(success: true)
end

config = RailsMind::Configuration.new
config.endpoint = "http://127.0.0.1:3000"
config.token = "benchmark-only"
config.queue_capacity = 1000
collector = RailsMind::Collector.new(config, transport: DiscardTransport.new)
client = RailsMind::Client.new(config, collector: collector)
count = 10_000
elapsed = Benchmark.realtime do
  count.times { |n| client.emit(:event, "Invoice paid", properties: { invoice_id: n, amount_cents: 4500 }) }
end
collector.flush
puts JSON.pretty_generate(events: count, seconds: elapsed.round(4), microseconds_per_enqueue: (elapsed * 1_000_000 / count).round(2), collector: collector.stats)
collector.shutdown
