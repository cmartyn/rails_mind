require "minitest/autorun"
require "rails"
require "rails_mind"

class MemoryCollector
  attr_reader :events
  def initialize = @events = []
  def push(event) = (@events << event; true)
end

class ScriptedTransport
  attr_reader :bodies
  def initialize(results = [])
    @results, @bodies = results, []
  end

  def send_batch(body)
    @bodies << body
    @results.shift || RailsMind::Transport::Result.new(success: true, retryable: false)
  end
end

class SDKTest < Minitest::Test
  def setup
    @config = RailsMind::Configuration.new
    @config.endpoint = "http://127.0.0.1:3000"
    @config.token = "test-only"
    @config.release = "abc123"
    @config.retry_base = 0
    @memory = MemoryCollector.new
    @client = RailsMind::Client.new(@config, collector: @memory)
    RailsMind.client = @client
  end

  def teardown
    RailsMind::Context.current.clear
  end
end
