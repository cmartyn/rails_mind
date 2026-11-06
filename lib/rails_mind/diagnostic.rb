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
        page_views: @config.page_views,
        visitor_cookie: @config.visitor_cookie,
        link_page_views_to_users: @config.link_page_views_to_users,
        plan: [
          "Add one initializer. No database migrations or Gemfile changes.",
          "Requests: automatic sampling of routine successes; jobs via Rails notifications and errors via Rails.error stay unsampled.",
          "Page views: HTML pages your controllers render are counted with a first-party visitor cookie; config.page_views, config.visitor_cookie and config.link_page_views_to_users turn parts off.",
          ("Ahoy detected: RailsMind no longer reads Ahoy and counts page views itself. Remove any require \"rails_mind/integrations/ahoy\" and RailsMind::Integrations.mirror_ahoy! call, or the app fails at boot; Ahoy keeps its own tables." if detected["ahoy_matey"]),
          detected["opentelemetry-sdk"] ? "OpenTelemetry detected: attach RailsMind exporter after existing SDK setup; preserve sampler and exporters." : "APM traces: optionally add selected OpenTelemetry libraries and explicitly configure one provider.",
          detected["flipper"] ? "Flipper detected: observe notifications only; preserve adapter, groups, targeting and cache." : "Flags: Flipper is optional. No flag configuration is created.",
          "Existing error reporters stay installed. RailsMind deduplicates its own collector only.",
          "Business/error signals are not sampled; routine requests follow the hosted policy. Local opt-out does not disable server sampling or quotas. Inspect RailsMind.stats for queue losses and unconfirmed delivery."
        ].compact,
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
