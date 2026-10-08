require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "generators/rails_mind/agent/agent_generator"

class AgentGeneratorTest < SDKTest
  def setup
    super
    @root = Dir.mktmpdir("agent setup ")
    @previous = ENV.to_h.slice("RAILSMIND_API_TOKEN", "RAILS_MIND_ENDPOINT")
    ENV.delete("RAILSMIND_API_TOKEN")
    ENV.delete("RAILS_MIND_ENDPOINT")
  end

  def teardown
    @previous.each { |key, value| ENV[key] = value }
    ( %w[RAILSMIND_API_TOKEN RAILS_MIND_ENDPOINT] - @previous.keys ).each { |key| ENV.delete(key) }
    FileUtils.remove_entry(@root)
    super
  end

  def test_preview_writes_nothing_for_both_modes
    %w[env credentials].each do |auth|
      output = generate("--plan", "--auth=#{auth}")
      assert_empty Dir.children(@root)
      assert_includes output, "Preview mode"
      assert_includes output, "connection has not been tested"
    end
  end

  def test_fresh_env_setup_is_repeatable_and_does_not_echo_secrets
    ENV["RAILSMIND_API_TOKEN"] = "secret-test-token"
    output = generate
    assert_equal 'Bearer ${RAILSMIND_API_TOKEN}', config.dig("mcpServers", "railsmind", "headers", "Authorization")
    assert_includes read("AGENTS.md"), "report_fix"
    refute File.exist?(File.join(@root, "CLAUDE.md"))
    original = read("AGENTS.md")
    generate
    assert_equal original, read("AGENTS.md")
    refute_includes output, "secret-test-token"
    assert_includes output, "No fixes have been started"
  end

  def test_preserves_existing_servers_and_instructions
    File.write(File.join(@root, ".mcp.json"), JSON.generate("extra" => true, "mcpServers" => { "existing" => { "command" => "existing" } }))
    File.write(File.join(@root, "AGENTS.md"), "Keep my rules.\n")
    File.write(File.join(@root, "CLAUDE.md"), "Keep Claude's rules.\n")
    FileUtils.mkdir_p(File.join(@root, ".claude"))
    File.write(File.join(@root, ".claude/CLAUDE.md"), "More rules.\n")
    generate
    generate
    assert config["extra"]
    assert_equal "existing", config.dig("mcpServers", "existing", "command")
    assert read("AGENTS.md").start_with?("Keep my rules.")
    assert_equal 1, read("CLAUDE.md").scan("@AGENTS.md").size
    assert_equal 1, read(".claude/CLAUDE.md").scan("@../AGENTS.md").size
  end

  def test_bad_json_and_existing_railsmind_are_preserved_even_with_force
    [ "{broken", '[]', '{"mcpServers":[]}', '{"mcpServers":{"railsmind":{"headers":{"Authorization":"secret"}}}}' ].each do |existing|
      File.write(File.join(@root, ".mcp.json"), existing)
      output = generate("--force")
      assert_equal existing, read(".mcp.json")
      refute_includes output, '"Authorization": "secret"'
    end
  end

  def test_credentials_setup_is_local_and_does_not_decrypt
    output = generate("--auth=credentials", "--credentials-environment=staging")
    assert_equal "./bin/rails_mind_mcp_headers --environment staging", config.dig("mcpServers", "railsmind", "headersHelper")
    refute config.dig("mcpServers", "railsmind").key?("headers")
    assert File.executable?(File.join(@root, "bin/rails_mind_mcp_headers"))
    assert_includes output, "http_headers_helper"
    assert_includes output, "this trusted project's .codex/config.toml"
    refute_includes output, "RAILSMIND_API_TOKEN is not set"
    File.write(File.join(@root, "bin/rails_mind_mcp_headers"), "custom helper")
    generate("--auth=credentials", "--force")
    assert_equal "custom helper", read("bin/rails_mind_mcp_headers")
  end

  def test_endpoint_override_is_used_and_unsafe_endpoint_does_not_write
    ENV["RAILS_MIND_ENDPOINT"] = "https://example.com/"
    generate
    assert_equal "https://example.com/mcp", config.dig("mcpServers", "railsmind", "url")
    before = read(".mcp.json")
    ENV["RAILS_MIND_ENDPOINT"] = "https://secret@example.com"
    _, errors = capture_io { generate }
    assert_includes errors, "RAILS_MIND_ENDPOINT must be HTTPS"
    assert_equal before, read(".mcp.json")
  end

  private

  def config = JSON.parse(read(".mcp.json"))
  def read(path) = File.read(File.join(@root, path))
  def generate(*args)
    original, $stdout = $stdout, StringIO.new
    RailsMind::Generators::AgentGenerator.start(args, destination_root: @root)
    $stdout.string
  ensure
    $stdout = original
  end
end
