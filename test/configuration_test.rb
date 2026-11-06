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

  def test_exception_messages_and_query_shapes_default_on_and_require_booleans
    config = RailsMind::Configuration.new(env: { "RAILS_MIND_KEY" => "test-only" })
    assert_equal true, config.capture_exception_message
    assert_equal true, config.capture_query_shapes
    config.capture_exception_message = false
    config.capture_query_shapes = false
    assert_same config, config.validate!
    config.capture_query_shapes = "false"
    assert_raises(ArgumentError) { config.validate! }
    config.capture_query_shapes = true
    config.capture_exception_message = "false" # 0.3.0 never validated this flag, so an upgrade must still boot.
    assert_same config, config.validate!
  end

  def test_automatic_sampling_defaults_on_and_requires_a_boolean
    config = RailsMind::Configuration.new(env: { "RAILS_MIND_KEY" => "test-only" })
    assert_equal true, config.automatic_sampling
    config.automatic_sampling = false
    assert_same config, config.validate!
    config.automatic_sampling = "false"
    assert_raises(ArgumentError) { config.validate! }
  end

  def test_page_view_switches_default_on_and_require_booleans
    config = RailsMind::Configuration.new(env: { "RAILS_MIND_KEY" => "test-only" })
    %i[page_views visitor_cookie link_page_views_to_users].each do |flag|
      assert_equal true, config.public_send(flag), flag
      config.public_send("#{flag}=", false)
      assert_same config, config.validate!
      config.public_send("#{flag}=", "false")
      error = assert_raises(ArgumentError) { config.validate! }
      assert_includes error.message, flag.to_s
      config.public_send("#{flag}=", true)
    end
  end

  def test_switches_are_never_read_from_the_environment
    env = { "RAILS_MIND_KEY" => "test-only", "RAILS_MIND_PAGE_VIEWS" => "false", "RAILS_MIND_VISITOR_COOKIE" => "false",
      "RAILS_MIND_LINK_PAGE_VIEWS_TO_USERS" => "false" }
    config = RailsMind::Configuration.new(env: env)
    assert_equal [ true, true, true ], [ config.page_views, config.visitor_cookie, config.link_page_views_to_users ]
  end

  def test_ignore_page_view_must_be_callable
    config = RailsMind::Configuration.new(env: { "RAILS_MIND_KEY" => "test-only" })
    assert_nil config.ignore_page_view
    config.ignore_page_view = ->(request) { request.path.start_with?("/admin") }
    assert_same config, config.validate!
    config.ignore_page_view = "/admin"
    error = assert_raises(ArgumentError) { config.validate! }
    assert_includes error.message, "ignore_page_view"
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

  def test_doctor_tells_an_ahoy_app_what_to_remove
    Dir.mktmpdir do |root|
      config = RailsMind::Configuration.new(env: { "RAILS_MIND_KEY" => "test-only" }, root: root)
      plan = RailsMind::Diagnostic.new(root: root, config: config).report[:plan]
      refute plan.any? { |line| line.include?("Ahoy") }
      refute plan.any? { |line| line.start_with?("Browser") }
      File.write(File.join(root, "Gemfile.lock"), <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            ahoy_matey (5.5.0)

        PLATFORMS
          ruby

        DEPENDENCIES
          ahoy_matey

        BUNDLED WITH
           2.5.0
      LOCK
      report = RailsMind::Diagnostic.new(root: root, config: config).report
      assert_equal "5.5.0", report[:detected]["ahoy_matey"]
      hint = report[:plan].find { |line| line.start_with?("Ahoy detected") }
      assert_includes hint, "rails_mind/integrations/ahoy"
      assert_includes hint, "mirror_ahoy!"
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
      assert_equal true, report[:automatic_sampling]
      assert_equal true, report[:page_views]
      assert_equal true, report[:visitor_cookie]
      assert_equal true, report[:link_page_views_to_users]
      config.page_views = false
      assert_equal false, RailsMind::Diagnostic.new(root: root, config: config).report[:page_views]
      refute_includes report.to_json, "private-test-key"
      config.token = nil
      refute RailsMind::Diagnostic.new(root: root, config: config).report[:enabled]
    end
  end
end
