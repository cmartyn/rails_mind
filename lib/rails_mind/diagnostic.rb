require "json"
require "bundler"

module RailsMind
  class Diagnostic
    GEMS = %w[rails ahoy_matey flipper opentelemetry-sdk opentelemetry-instrumentation-rails
      opentelemetry-instrumentation-pg opentelemetry-instrumentation-net_http good_job sidekiq
      solid_queue delayed_job sentry-rails honeybadger bugsnag rollbar bullet prosopite field_test].freeze

    def initialize(root: Dir.pwd, config: RailsMind.configuration)
      @root, @config = root, config
    end

    def report
      lockfile = File.join(@root, "Gemfile.lock")
      versions = File.exist?(lockfile) ? Bundler::LockfileParser.new(File.read(lockfile)).specs.to_h { |spec| [ spec.name, spec.version.to_s ] } : {}
      detected = GEMS.to_h { |name| [ name, versions[name] ] }
      {
        sdk: VERSION, ruby: RUBY_VERSION, detected: detected.compact,
        credential_present: !@config.token.to_s.strip.empty?,
        endpoint_present: !@config.endpoint.to_s.strip.empty?,
        release_present: !@config.release.to_s.strip.empty?,
        enabled: @config.enabled?,
        plan: [
          "Add one initializer. No database migrations or Gemfile changes.",
          "Requests and jobs: unsampled measurements via Rails notifications; errors via Rails.error.",
          detected["ahoy_matey"] ? "Ahoy detected: keep current store; explicitly opt into mirror mode after review." : "Analytics: optionally add ahoy_matey; choose hosted-only store or existing database store.",
          detected["opentelemetry-sdk"] ? "OpenTelemetry detected: attach RailsMind exporter after existing SDK setup; preserve sampler and exporters." : "APM traces: optionally add selected OpenTelemetry libraries and explicitly configure one provider.",
          detected["flipper"] ? "Flipper detected: observe notifications only; preserve adapter, groups, targeting and cache." : "Flags: Flipper is optional. No flag configuration is created.",
          "Existing error reporters stay installed. RailsMind deduplicates its own collector only.",
          "Browser: optional Ahoy adapter; enable only after checking existing pageview handlers.",
          "Business/request/error signals are not sampled; bounded queue losses remain possible. Inspect RailsMind.stats."
        ],
        limitations: [ "Compatibility applies to tested versions only; this is not a historical import.",
          "No network check is performed and credential values are never printed." ]
      }
    end
  end
end
