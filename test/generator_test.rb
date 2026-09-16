require_relative "test_helper"
require "tmpdir"
require "generators/rails_mind/install/install_generator"

class GeneratorTest < SDKTest
  def test_plan_writes_nothing_and_repeat_install_preserves_existing_files
    Dir.mktmpdir("rails-mind-installer") do |root|
      silence do
        RailsMind::Generators::InstallGenerator.start([ "--plan", "--browser" ], destination_root: root)
      end
      assert_empty Dir.children(root)
      silence do
        RailsMind::Generators::InstallGenerator.start([ "--browser" ], destination_root: root)
      end
      initializer = File.join(root, "config/initializers/rails_mind.rb")
      browser = File.join(root, "app/javascript/rails_mind.js")
      assert File.exist?(initializer)
      assert File.exist?(browser)
      assert_includes File.read(initializer), "ENV[\"RAILS_MIND_KEY\"]"
      File.write(initializer, "# customer config\n")
      File.write(browser, "// customer setup\n")
      silence do
        RailsMind::Generators::InstallGenerator.start([ "--browser", "--force" ], destination_root: root)
      end
      assert_equal "# customer config\n", File.read(initializer)
      assert_equal "// customer setup\n", File.read(browser)
      refute File.exist?(File.join(root, "Gemfile"))
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
