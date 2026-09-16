require_relative "test_helper"

class TransportTest < SDKTest
  class HTTP
    attr_accessor :use_ssl, :open_timeout, :read_timeout, :write_timeout, :max_retries
    attr_reader :request_sent
    def initialize(code, headers = {}) = (@code, @headers = code, headers)
    def start = yield(self)
    def request(request)
      @request_sent = request
      raise Timeout::Error if @code == :timeout
      Struct.new(:code, :headers) { def [](name) = headers[name] }.new(@code.to_s, @headers)
    end
  end

  def test_credentials_path_and_retry_rules
    [ 200, 202, 400, 401, 403, 413, 422, 429, 500, 503 ].each do |code|
      http = HTTP.new(code, "Retry-After" => "600")
      transport = RailsMind::Transport.new(@config, http_factory: ->(_uri) { http })
      result = transport.send_batch('{"events":[]}')
      assert_equal (200..299).cover?(code), result.success
      assert_equal code == 429 || code >= 500, result.retryable
      assert_equal 30, result.retry_after
      assert_equal "/api/v1/events", http.request_sent.path
      assert_equal "Bearer test-only", http.request_sent["Authorization"]
      assert_equal 0, http.max_retries
    end
    assert RailsMind::Transport.new(@config, http_factory: ->(_uri) { HTTP.new(:timeout) }).send_batch("{}").retryable
    refute RailsMind::Context.suppressed?
  end
end
