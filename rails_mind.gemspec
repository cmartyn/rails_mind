require_relative "lib/rails_mind/version"

Gem::Specification.new do |spec|
  spec.name = "rails_mind"
  spec.version = RailsMind::VERSION
  spec.authors = [ "RailsMind" ]
  spec.summary = "Bounded Rails telemetry for RailsMind"
  spec.license = "MIT"
  spec.homepage = "https://github.com/cmartyn/rails_mind"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["documentation_uri"] = "#{spec.homepage}/blob/main/docs/sdk.md"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir["lib/**/*", "javascript/rails_mind.js", "docs/**/*.md", "README.md", "CONTRIBUTING.md", "LICENSE"]
  spec.require_paths = [ "lib" ]
  spec.add_dependency "railties", ">= 7.2", "< 9"
  spec.add_dependency "net-http", ">= 0.4", "< 1"
end
