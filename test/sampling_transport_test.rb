require_relative "test_helper"

class SamplingTransportTest < SDKTest
  class HTTP
    attr_accessor :use_ssl, :open_timeout, :read_timeout, :write_timeout, :max_retries
    attr_reader :sent
    def initialize(code, body) = (@code, @body = code, body)
    def start = yield(self)
    def request(request)
      @sent = request
      Struct.new(:code, :body) { def [](_name) = nil }.new(@code.to_s, @body)
    end
  end

  def test_control_json_and_report_ack_are_read_on_acceptance_and_quota_rejection
    [ 202, 429 ].each do |code|
      packet = { "sampling_policy" => { "version" => 1 }, "sampling_report_ack" => SecureRandom.uuid }
      http = HTTP.new(code, JSON.generate(packet))
      result = RailsMind::Transport.new(@config, http_factory: ->(_) { http }).send_batch("{}")
      assert_equal code == 202, result.success
      assert_equal packet["sampling_policy"], result.sampling_policy
      assert_equal packet["sampling_report_ack"], result.sampling_report_ack
      assert_equal "enabled", http.sent["X-RailsMind-Automatic-Sampling"]
    end
  end

  def test_get_control_uses_same_scoped_key_and_explicit_local_opt_out
    @config.automatic_sampling = false
    http = HTTP.new(200, "{}")
    RailsMind::Transport.new(@config, http_factory: ->(_) { http }).fetch_sampling_policy
    assert_instance_of Net::HTTP::Get, http.sent
    assert_equal "/api/v1/sampling_policy", http.sent.path
    assert_equal "Bearer test-only", http.sent["Authorization"]
    assert_equal "disabled", http.sent["X-RailsMind-Automatic-Sampling"]
    assert_nil http.sent.body
  end

  def test_real_streaming_response_is_drained_but_oversized_control_is_discarded
    http = HTTP.new(202, nil)
    chunks_read = 0
    reply = Struct.new(:code) do
      def [](_name) = nil
    end.new("202")
    reply.define_singleton_method(:read_body) do |&block|
      20.times do
        chunks_read += 1
        block.call("x" * 4096)
      end
    end
    http.define_singleton_method(:request) { |_request, &block| block.call(reply); reply }
    result = RailsMind::Transport.new(@config, http_factory: ->(_) { http }).send_batch("{}")
    assert result.success
    assert_equal 20, chunks_read
    assert_nil result.sampling_policy
    assert_nil result.sampling_report_ack
  end

  def test_malformed_oversized_and_error_response_controls_do_not_change_delivery_status
    [ "not json", "[]", "x" * 65_537 ].each do |body|
      http = HTTP.new(202, body)
      result = RailsMind::Transport.new(@config, http_factory: ->(_) { http }).send_batch("{}")
      assert result.success
      assert_nil result.sampling_policy
      assert_nil result.sampling_report_ack
    end
    [ 401, 403, 500 ].each do |code|
      http = HTTP.new(code, JSON.generate(sampling_policy: { version: 1 }, sampling_report_ack: SecureRandom.uuid))
      result = RailsMind::Transport.new(@config, http_factory: ->(_) { http }).send_batch("{}")
      assert_nil result.sampling_policy
      assert_nil result.sampling_report_ack
    end
  end
end
