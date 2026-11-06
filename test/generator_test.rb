require_relative "test_helper"
require "minitest/mock"
require "tmpdir"
require "generators/rails_mind/install/install_generator"

class GeneratorTest < SDKTest
  def test_generated_initializer_preserves_the_resolved_endpoint_and_release
    Dir.mktmpdir("rails-mind-installer") do |root|
      silence { RailsMind::Generators::InstallGenerator.start([], destination_root: root) }
      [ { "RENDER_GIT_COMMIT" => "host-commit" },
        { "RAILS_MIND_ENDPOINT" => "https://custom.example.com", "RAILS_MIND_RELEASE" => "explicit-release" } ].each do |env|
        config = RailsMind::Configuration.new(env: env, root: root)
        endpoint, release = config.endpoint, config.release
        RailsMind.stub(:configure, ->(&block) { block.call(config) }) do
          load File.join(root, "config/initializers/rails_mind.rb")
        end
        assert_equal endpoint, config.endpoint
        assert_equal release, config.release
      end
    end
  end

  def test_plan_writes_nothing_and_repeat_install_preserves_existing_files
    Dir.mktmpdir("rails-mind-installer") do |root|
      silence do
        RailsMind::Generators::InstallGenerator.start([ "--plan" ], destination_root: root)
      end
      assert_empty Dir.children(root)
      silence do
        RailsMind::Generators::InstallGenerator.start([], destination_root: root)
      end
      initializer = File.join(root, "config/initializers/rails_mind.rb")
      assert File.exist?(initializer)
      assert_includes File.read(initializer), "ENV[\"RAILS_MIND_KEY\"]"
      refute_includes File.read(initializer), "Ahoy"
      File.write(initializer, "# customer config\n")
      silence do
        RailsMind::Generators::InstallGenerator.start([ "--force" ], destination_root: root)
      end
      assert_equal "# customer config\n", File.read(initializer)
      refute File.exist?(File.join(root, "Gemfile"))
      refute File.exist?(File.join(root, "app/javascript/rails_mind.js")), "there is no browser adapter to copy"
    end
  end

  private

  def silence
    previous = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = previous
  end
end
