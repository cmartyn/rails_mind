require "uri"

module RailsMind
  class Configuration
    DEFAULT_ENDPOINT = "https://railsmind.com".freeze
    RELEASE_ENV_VARS = %w[RAILS_MIND_RELEASE GIT_REVISION RENDER_GIT_COMMIT
      RAILWAY_GIT_COMMIT_SHA HEROKU_BUILD_COMMIT HEROKU_SLUG_COMMIT KAMAL_VERSION].freeze

    attr_accessor :endpoint, :token, :release, :apm, :errors, :analytics, :flags,
      :queue_capacity, :batch_size, :max_batch_bytes, :max_event_bytes, :flush_interval,
      :max_retries, :retry_base, :open_timeout, :read_timeout, :shutdown_timeout,
      :before_send, :capture_exception_message

    def initialize(env: ENV, root: nil)
      @endpoint = nonblank(env["RAILS_MIND_ENDPOINT"]) || DEFAULT_ENDPOINT
      @token = env["RAILS_MIND_KEY"]
      @release = release_from_env(env) || release_from_file(root)
      @apm = @errors = @analytics = @flags = true
      @queue_capacity = 1_000
      @batch_size = 100
      @max_batch_bytes = 256 * 1024
      @max_event_bytes = 16 * 1024
      @flush_interval = 2.0
      @max_retries = 3
      @retry_base = 0.25
      @open_timeout = 1.0
      @read_timeout = 2.0
      @shutdown_timeout = 2.0
      @capture_exception_message = false
    end

    def enabled? = !token.to_s.strip.empty? && !endpoint.to_s.strip.empty?

    def validate!
      return self unless enabled?
      uri = URI(endpoint)
      loopback = %w[localhost 127.0.0.1 ::1].include?(uri.hostname)
      raise ArgumentError, "endpoint must use HTTPS (HTTP only on loopback)" unless uri.is_a?(URI::HTTPS) || (uri.is_a?(URI::HTTP) && loopback)
      raise ArgumentError, "endpoint must not contain credentials, query, or fragment" if uri.userinfo || uri.query || uri.fragment
      raise ArgumentError, "batch_size must be 1..100" unless (1..100).cover?(batch_size)
      raise ArgumentError, "max_batch_bytes must be 1024..262144" unless (1024..262_144).cover?(max_batch_bytes)
      raise ArgumentError, "queue_capacity must be positive" unless queue_capacity.positive?
      raise ArgumentError, "max_retries must be 0..5" unless (0..5).cover?(max_retries)
      [ flush_interval, open_timeout, read_timeout, shutdown_timeout ].each do |value|
        raise ArgumentError, "timeouts must be positive" unless value.positive?
      end
      self
    end

    private

    def nonblank(value)
      value = value.to_s.strip
      value unless value.empty?
    end

    def release_from_env(env)
      RELEASE_ENV_VARS.each do |name|
        value = nonblank(env[name])
        next unless value
        # Kamal permits arbitrary version labels; Assist needs a Git revision.
        next if name == "KAMAL_VERSION" && !value.match?(/\A(?:[a-f0-9]{40}|[a-f0-9]{64})\z/i)
        return value
      end
      nil
    end

    def release_from_file(root)
      root ||= Rails.root if defined?(Rails) && Rails.respond_to?(:root)
      return unless root
      path = File.join(root, "REVISION")
      return unless File.file?(path)
      # Hatchbox/Capistrano deployments may have no Git checkout at runtime.
      value = File.read(path, 501).force_encoding(Encoding::UTF_8)
      return if value.bytesize > 500 || !value.valid_encoding?
      nonblank(value)
    rescue SystemCallError, IOError
      nil
    end
  end
end
