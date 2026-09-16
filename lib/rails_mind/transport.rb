require "net/http"
require "json"

module RailsMind
  class Transport
    Result = Struct.new(:success, :retryable, :retry_after, keyword_init: true)
    TRANSIENT_ERRORS = [ Timeout::Error, IOError, EOFError, SocketError, Errno::ECONNRESET,
      Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::EPIPE, OpenSSL::SSL::SSLError ].freeze

    def initialize(config, http_factory: ->(uri) { Net::HTTP.new(uri.host, uri.port, nil) })
      @config = config
      @http_factory = http_factory
      @uri = URI(config.endpoint)
      @uri.path = "#{@uri.path.sub(%r{/$}, '')}/api/v1/events" unless @uri.path.end_with?("/api/v1/events")
    end

    def send_batch(json)
      Context.suppress do
        request = Net::HTTP::Post.new(@uri)
        request["Authorization"] = "Bearer #{@config.token}"
        request["Content-Type"] = "application/json"
        request["User-Agent"] = "rails_mind/#{VERSION}"
        request.body = json
        http = @http_factory.call(@uri)
        http.use_ssl = @uri.scheme == "https"
        http.open_timeout = @config.open_timeout
        http.read_timeout = @config.read_timeout
        http.write_timeout = @config.read_timeout
        http.max_retries = 0
        response = http.start { |connection| connection.request(request) }
        code = response.code.to_i
        Result.new(success: (200..299).cover?(code), retryable: code == 429 || code >= 500,
          retry_after: retry_after(response["Retry-After"]))
      end
    rescue *TRANSIENT_ERRORS
      Result.new(success: false, retryable: true)
    end

    private

    def retry_after(value)
      return nil unless value
      seconds = value.match?(/\A\d+\z/) ? value.to_i : Time.httpdate(value) - Time.now
      [ [ seconds, 0 ].max, 30 ].min
    rescue ArgumentError
      nil
    end
  end
end
