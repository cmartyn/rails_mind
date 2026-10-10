require "net/http"
require "json"

module RailsMind
  class Transport
    MAX_RESPONSE_BYTES = 64 * 1024
    Result = Struct.new(:success, :retryable, :retry_after, :sampling_policy, :sampling_report_ack, keyword_init: true)
    TRANSIENT_ERRORS = [ Timeout::Error, IOError, EOFError, SocketError, Errno::ECONNRESET,
      Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::EPIPE, OpenSSL::SSL::SSLError ].freeze

    def initialize(config, http_factory: ->(uri) { Net::HTTP.new(uri.host, uri.port, nil) })
      @config = config
      @http_factory = http_factory
      @uri = URI(config.endpoint)
      @uri.path = "#{@uri.path.sub(%r{/$}, '')}/api/v1/events" unless @uri.path.end_with?("/api/v1/events")
    end

    def send_batch(json)
      request = Net::HTTP::Post.new(@uri)
      request.body = json
      perform(request)
    end

    def fetch_sampling_policy
      uri = @uri.dup
      uri.path = uri.path.sub(%r{/events$}, "/sampling_policy")
      perform(Net::HTTP::Get.new(uri))
    end

    private

    def perform(request)
      Context.suppress do
        request["Authorization"] = "Bearer #{@config.token}"
        request["Content-Type"] = "application/json"
        request["User-Agent"] = "rails_mind/#{VERSION}"
        request["X-RailsMind-Automatic-Sampling"] = @config.automatic_sampling ? "enabled" : "disabled"
        http = @http_factory.call(@uri)
        http.use_ssl = @uri.scheme == "https"
        http.open_timeout = @config.open_timeout
        http.read_timeout = @config.read_timeout
        http.write_timeout = @config.read_timeout
        http.max_retries = 0
        body, streamed, oversized = +"", false, false
        response = http.start do |connection|
          connection.request(request) do |reply|
            streamed = true
            reply.read_body do |chunk|
              if body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES
                oversized = true
              elsif !oversized
                body << chunk
              end
            end
          end
        end
        body = response.body.to_s if !streamed && response.respond_to?(:body)
        code = response.code.to_i
        control = if !oversized && body.bytesize <= MAX_RESPONSE_BYTES && ((200..299).cover?(code) || code == 429)
          parse_control(body)
        else
          {}
        end
        Result.new(success: (200..299).cover?(code), retryable: code == 429 || code >= 500,
          retry_after: retry_after(response["Retry-After"]), sampling_policy: control["sampling_policy"],
          sampling_report_ack: control["sampling_report_ack"])
      end
    rescue *TRANSIENT_ERRORS
      Result.new(success: false, retryable: true)
    end

    def parse_control(body)
      value = JSON.parse(body)
      value.is_a?(Hash) ? value : {}
    rescue JSON::ParserError, EncodingError
      {}
    end

    def retry_after(value)
      return nil unless value
      seconds = value.match?(/\A\d+\z/) ? value.to_i : Time.httpdate(value) - Time.now
      [ [ seconds, 0 ].max, 30 ].min
    rescue ArgumentError
      nil
    end
  end
end
