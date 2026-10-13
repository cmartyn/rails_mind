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
        automatic_sampling: @config.automatic_sampling,
        plan: [
          "Add one initializer. No database migrations or Gemfile changes.",
          "Requests: automatic sampling of routine successes; jobs via Rails notifications and errors via Rails.error stay unsampled.",
          detected["ahoy_matey"] ? "Ahoy detected: keep current store; explicitly opt into mirror mode after review." : "Analytics: optionally add ahoy_matey; choose hosted-only store or existing database store.",
          detected["opentelemetry-sdk"] ? "OpenTelemetry detected: attach RailsMind exporter after existing SDK setup; preserve sampler and exporters." : "APM traces: optionally add selected OpenTelemetry libraries and explicitly configure one provider.",
          detected["flipper"] ? "Flipper detected: observe notifications only; preserve adapter, groups, targeting and cache." : "Flags: Flipper is optional. No flag configuration is created.",
          "Existing error reporters stay installed. RailsMind deduplicates its own collector only.",
          "Browser: optional Ahoy adapter; enable only after checking existing pageview handlers.",
          "Business/error signals are not sampled; routine requests follow the hosted policy. Local opt-out does not disable server sampling or quotas. Inspect RailsMind.stats for queue losses and unconfirmed delivery."
        ],
        limitations: [ "Compatibility applies to tested versions only; this is not a historical import.",
          "No network check is performed and credential values are never printed." ]
      }
    end

    # What keeps collection off, one sentence each, naming the setting to change.
    def problems
      [].tap do |found|
        if @config.token.to_s.strip.empty?
          found << "RAILS_MIND_KEY is not set, so collection is off. Set it in this app's environment to the ingest key from RailsMind Setup, restart, then run bin/rails rails_mind:verify."
        end
        if @config.endpoint.to_s.strip.empty?
          found << "The RailsMind endpoint is blank, so collection is off. Leave config.endpoint and RAILS_MIND_ENDPOINT unset to use #{Configuration::DEFAULT_ENDPOINT}, or set your RailsMind instance's URL."
        end
      end
    end
  end
end
