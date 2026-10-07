require "json"
require "optparse"
require "pathname"
require "active_support"
require "active_support/encrypted_configuration"

module RailsMind
  # Machine interface: stdout contains secret-bearing JSON, unless --check is used.
  # Deliberately does not require rails_mind or boot the application.
  class AgentHeaders
    class SetupError < StandardError; end

    def self.run(arguments, root:, out: $stdout, err: $stderr)
      options = { environment: "development" }
      parser = OptionParser.new do |opts|
        opts.on("--environment NAME") { |value| options[:environment] = value }
        opts.on("--content-path PATH") { |value| options[:content_path] = value }
        opts.on("--key-path PATH") { |value| options[:key_path] = value }
        opts.on("--check") { options[:check] = true }
      end
      parser.parse!(arguments.dup)
      token = new(root: root, **options.reject { |key, _| key == :check }).token
      out.puts(options[:check] ? "RailsMind credential ready. Connection has not been tested." : JSON.generate("Authorization" => "Bearer #{token}"))
      0
    rescue SetupError, OptionParser::ParseError
      err.puts "RailsMind needs an API token. Set RAILSMIND_API_TOKEN or rails_mind.api_token in the selected Rails credentials, with its matching decryption key. See docs/agents.md."
      1
    rescue StandardError
      # Exception messages from YAML/decryption can contain secrets. Do not echo them.
      err.puts "RailsMind could not read credentials. Check the selected encrypted file and key; no connection was attempted. See docs/agents.md."
      1
    end

    def initialize(root:, environment: "development", content_path: nil, key_path: nil)
      raise SetupError unless environment.match?(/\A[a-zA-Z0-9_-]+\z/)
      @root = Pathname.new(root).expand_path
      @environment, @content_path, @key_path = environment, content_path, key_path
    end

    def token
      value = ENV["RAILSMIND_API_TOKEN"]
      value = credentials.dig(:rails_mind, :api_token) if value.to_s.strip.empty?
      raise SetupError unless value.is_a?(String) && !value.strip.empty? && !value.match?(/[[:cntrl:]]/)
      value.strip
    end

    private

    def credentials
      # Match Rails' defaults; the content and key fallbacks are independent.
      content = @root.join("config/credentials/#{@environment}.yml.enc")
      content = @root.join("config/credentials.yml.enc") unless content.exist?
      key = @root.join("config/credentials/#{@environment}.key")
      key = @root.join("config/master.key") unless key.exist?
      content = @root.join(@content_path) if @content_path
      key = @root.join(@key_path) if @key_path
      raise SetupError unless content.file?
      ActiveSupport::EncryptedConfiguration.new(config_path: content, key_path: key,
        env_key: "RAILS_MASTER_KEY", raise_if_missing_key: true)
    end
  end
end
