require_relative "test_helper"
require "minitest/mock"
require "tmpdir"
require "rails_mind/diagnostic"

class ConfigurationTest < Minitest::Test
  def test_only_the_key_is_required_for_hosted_delivery
    Dir.mktmpdir do |root|
      config = RailsMind::Configuration.new(env: { "RAILS_MIND_KEY" => "test-only" }, root: root)
      assert_equal "https://railsmind.com", config.endpoint
      assert config.enabled?
      assert_same config, config.validate!
      assert_nil config.release
      collector = MemoryCollector.new
      assert RailsMind::Client.new(config, collector: collector).emit(:event, "Example")
      refute collector.events.sole.key?("release")
      [ nil, "", " \n" ].each do |key|
        refute RailsMind::Configuration.new(env: { "RAILS_MIND_KEY" => key }, root: root).enabled?
      end
    end
  end

  def test_endpoint_overrides_skip_blank_values_and_keep_transport_validation
    [ nil, "", " \n" ].each do |endpoint|
      config = RailsMind::Configuration.new(env: { "RAILS_MIND_ENDPOINT" => endpoint })
      assert_equal "https://railsmind.com", config.endpoint
    end
    config = RailsMind::Configuration.new(env: { "RAILS_MIND_KEY" => "test-only", "RAILS_MIND_ENDPOINT" => " http://127.0.0.1:3000 \n" })
    assert_equal "http://127.0.0.1:3000", config.endpoint
    config.validate!
    config.endpoint = "http://example.com"
    assert_raises(ArgumentError) { config.validate! }
    config.endpoint = "https://user:secret@example.com"
    assert_raises(ArgumentError) { config.validate! }
  end

  def test_platform_release_metadata_is_detected_without_an_sdk_override
    {
      "GIT_REVISION" => "git-commit", "RENDER_GIT_COMMIT" => "render-commit",
      "RAILWAY_GIT_COMMIT_SHA" => "railway-commit", "HEROKU_BUILD_COMMIT" => "heroku-build",
      "HEROKU_SLUG_COMMIT" => "heroku-slug", "KAMAL_VERSION" => "a" * 40
    }.each do |name, release|
      config = RailsMind::Configuration.new(env: { name => " #{release}\n" })
      assert_equal release, config.release, name
    end
  end

  def test_release_precedence_and_blank_overrides
    env = { "RAILS_MIND_RELEASE" => "explicit", "GIT_REVISION" => "existing",
      "RENDER_GIT_COMMIT" => "render", "RAILWAY_GIT_COMMIT_SHA" => "railway",
      "HEROKU_BUILD_COMMIT" => "heroku-build", "HEROKU_SLUG_COMMIT" => "heroku-slug",
      "KAMAL_VERSION" => "a" * 40 }
    env.each do |name, release|
      assert_equal release, RailsMind::Configuration.new(env: env).release
      env[name] = " \n"
    end
  end

  def test_non_git_deployment_ids_do_not_become_checkout_references
    Dir.mktmpdir do |root|
      env = { "HEROKU_RELEASE_VERSION" => "v42", "FLY_IMAGE_REF" => "registry.fly.io/app:deployment-123",
        "KAMAL_VERSION" => "custom-version", "GITHUB_SHA" => "ci-commit" }
      assert_nil RailsMind::Configuration.new(env: env, root: root).release
      File.write(File.join(root, "REVISION"), "deployed-commit\n")
      assert_equal "deployed-commit", RailsMind::Configuration.new(env: env, root: root).release
      env["KAMAL_VERSION"] = "b" * 64
      assert_equal "b" * 64, RailsMind::Configuration.new(env: env, root: root).release
    end
  end

  def test_revision_file_is_a_fallback_and_never_comes_from_the_working_directory
    Dir.mktmpdir do |root|
      File.write(File.join(root, "REVISION"), "deployed-commit\n")
      Dir.mktmpdir do |cwd|
        File.write(File.join(cwd, "REVISION"), "wrong-application\n")
        Dir.chdir(cwd) do
          Rails.stub(:root, Pathname.new(root)) do
            assert_equal "deployed-commit", RailsMind::Configuration.new(env: {}).release
            assert_equal "override", RailsMind::Configuration.new(env: { "RAILS_MIND_RELEASE" => "override" }).release
          end
          Rails.stub(:root, nil) do
            assert_nil RailsMind::Configuration.new(env: {}).release
          end
        end
      end
      assert_equal "env-commit", RailsMind::Configuration.new(env: { "GIT_REVISION" => "env-commit" }, root: root).release
    end
  end

  def test_missing_blank_oversized_and_unreadable_revision_files_are_optional
    Dir.mktmpdir do |root|
      path = File.join(root, "REVISION")
      assert_nil RailsMind::Configuration.new(env: {}, root: root).release
      [ " \n", "x" * 501, "\xff".b ].each do |contents|
        File.binwrite(path, contents)
        assert_nil RailsMind::Configuration.new(env: {}, root: root).release
      end
      File.stub(:read, ->(*) { raise Errno::EACCES }) do
        assert_nil RailsMind::Configuration.new(env: {}, root: root).release
      end
    end
  end

  def test_doctor_reports_effective_configuration_without_exposing_the_key
    Dir.mktmpdir do |root|
      config = RailsMind::Configuration.new(env: { "RAILS_MIND_KEY" => "private-test-key", "RENDER_GIT_COMMIT" => "commit" }, root: root)
      report = RailsMind::Diagnostic.new(root: root, config: config).report
      assert report[:credential_present]
      assert report[:endpoint_present]
      assert report[:release_present]
      assert report[:enabled]
      refute_includes report.to_json, "private-test-key"
      config.token = nil
      refute RailsMind::Diagnostic.new(root: root, config: config).report[:enabled]
    end
  end
end
