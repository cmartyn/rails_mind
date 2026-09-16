require "rubygems/package"
require "rubygems/installer"
require "bundler"
require "tmpdir"
require "rbconfig"

Dir.chdir(File.expand_path("..", __dir__)) do
  Dir.mktmpdir("rails-mind-package") do |tmp|
    spec = Gem::Specification.load("rails_mind.gemspec")
    package = File.join(tmp, "#{spec.full_name}.gem")
    Gem::Package.build(spec, false, false, package)
    installed = Gem::Installer.at(package, install_dir: tmp, ignore_dependencies: true, wrappers: false).install
    # A fresh process loads the installed gem, without Bundler's checkout override.
    check = <<~'CHECK'
      require "rails_mind"
      loaded = $LOADED_FEATURES.find { |path| path.end_with?("/lib/rails_mind.rb") }
      expected = File.join(ARGV.fetch(0), "lib/rails_mind.rb")
      abort "Loaded SDK from the checkout instead of the package" unless loaded && File.realpath(loaded) == File.realpath(expected)
      require_relative "test/generator_test"
    CHECK
    environment = { "GEM_HOME" => tmp, "GEM_PATH" => ([tmp] + Gem.path).join(File::PATH_SEPARATOR) }
    success = Bundler.with_unbundled_env do
      system(environment, RbConfig.ruby, "-I", "test", "-e", check, installed.full_gem_path)
    end
    abort "Packaged SDK installer check failed" unless success
  end
end
