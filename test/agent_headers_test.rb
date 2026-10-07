require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "rails_mind/agent_headers"

class AgentHeadersTest < SDKTest
  def setup
    super
    @root = Dir.mktmpdir("agent credentials ")
    @previous = ENV.to_h.slice("RAILSMIND_API_TOKEN", "RAILS_MASTER_KEY", "RAILS_MIND_KEY")
    %w[RAILSMIND_API_TOKEN RAILS_MASTER_KEY RAILS_MIND_KEY].each { |key| ENV.delete(key) }
  end

  def teardown
    %w[RAILSMIND_API_TOKEN RAILS_MASTER_KEY RAILS_MIND_KEY].each { |key| ENV.delete(key) }
    @previous.each { |key, value| ENV[key] = value }
    FileUtils.remove_entry(@root)
    super
  end

  def test_shared_credentials_and_presence_only_check
    encrypted("config/credentials.yml.enc", "config/master.key", "shared-token")
    status, out, err = run_helper
    assert_equal 0, status
    assert_equal({ "Authorization" => "Bearer shared-token" }, JSON.parse(out))
    assert_empty err
    status, out, err = run_helper("--check")
    assert_equal 0, status
    assert_includes out, "Connection has not been tested"
    refute_includes out + err, "shared-token"
  end

  def test_specific_credentials_and_explicit_environment
    encrypted("config/credentials.yml.enc", "config/master.key", "shared-token")
    encrypted("config/credentials/development.yml.enc", "config/credentials/development.key", "dev-token")
    encrypted("config/credentials/staging.yml.enc", "config/credentials/staging.key", "staging-token")
    assert_includes run_helper[1], "dev-token"
    assert_includes run_helper("--environment", "staging")[1], "staging-token"
  end

  def test_env_override_works_without_credentials_or_decryption_key
    ENV["RAILSMIND_API_TOKEN"] = "personal-token"
    ENV["RAILS_MASTER_KEY"] = "invalid"
    assert_equal "Bearer personal-token", JSON.parse(run_helper[1])["Authorization"]
  end

  def test_missing_corrupt_and_incorrect_credentials_fail_without_leaking
    ENV["RAILS_MIND_KEY"] = "ingestion-only-secret"
    assert_failure
    encrypted("config/credentials.yml.enc", "config/master.key", "top-secret")
    File.write(File.join(@root, "config/master.key"), "0" * 32)
    assert_failure
    ENV["RAILSMIND_API_TOKEN"] = "top-secret\nInjected: header"
    assert_failure
  end

  def test_blank_override_uses_credentials_but_missing_api_token_does_not_use_ingestion_key
    encrypted("config/credentials.yml.enc", "config/master.key", "top-secret")
    ENV["RAILSMIND_API_TOKEN"] = " "
    assert_equal 0, run_helper[0]
    encrypted("config/credentials.yml.enc", "config/master.key", nil)
    ENV["RAILS_MIND_KEY"] = "ingestion-only-secret"
    assert_failure
  end

  def test_custom_paths_and_working_directory_do_not_boot_application
    encrypted("secrets/agent.yml.enc", "secrets/agent.key", "custom-token")
    FileUtils.mkdir_p(File.join(@root, "config"))
    File.write(File.join(@root, "config/application.rb"), 'raise "Should not boot"')
    Dir.chdir("/") do
      status, out, = run_helper("--content-path", "secrets/agent.yml.enc", "--key-path", "secrets/agent.key")
      assert_equal 0, status
      assert_includes out, "custom-token"
    end
  end

  private

  def encrypted(content, key, token)
    content, key = File.join(@root, content), File.join(@root, key)
    FileUtils.mkdir_p(File.dirname(content))
    FileUtils.mkdir_p(File.dirname(key))
    File.write(key, ActiveSupport::EncryptedFile.generate_key)
    ActiveSupport::EncryptedFile.new(content_path: content, key_path: key, env_key: "TEST_UNUSED_KEY", raise_if_missing_key: true)
      .write({ "rails_mind" => { "api_token" => token } }.to_yaml)
  end

  def run_helper(*args)
    out, err = StringIO.new, StringIO.new
    status = RailsMind::AgentHeaders.run(args, root: @root, out: out, err: err)
    [ status, out.string, err.string ]
  end

  def assert_failure
    status, out, err = run_helper
    assert_equal 1, status
    assert_empty out
    refute_empty err
    %w[top-secret ingestion-only-secret Injected].each { |value| refute_includes err, value }
  end
end
