require_relative "lib/rails_mind/version"

Gem::Specification.new do |spec|
  spec.name = "rails_mind"
  spec.version = RailsMind::VERSION
  spec.authors = [ "RailsMind" ]
  spec.summary = "Bounded Rails telemetry for RailsMind"
  spec.description = "The RailsMind client for Rails request, error, job, and business-event telemetry, " \
    "with optional Ahoy, Flipper, OpenTelemetry, and browser integrations."
  spec.license = "MIT"
  spec.homepage = "https://github.com/cmartyn/rails_mind"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["documentation_uri"] = "#{spec.homepage}/blob/main/docs/sdk.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir["lib/**/*", "javascript/rails_mind.js", "docs/**/*.md", "README.md", "CONTRIBUTING.md", "CHANGELOG.md", "LICENSE"]
  spec.require_paths = [ "lib" ]
  spec.add_dependency "railties", ">= 7.2", "< 9"
  spec.add_dependency "net-http", ">= 0.4", "< 1"
end
