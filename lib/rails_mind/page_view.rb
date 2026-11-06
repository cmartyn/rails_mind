require "uri"
require_relative "visitor"

module RailsMind
  # One HTML page a controller rendered for a person: a successful GET, not a
  # Turbo Frame, a prefetch, an XHR, a health check or a known bot. Built from
  # the process_action notification, so it shares the request event's trace
  # and the identity the app set during the action.
  module PageView
    # The wire contract with the hosted app. Every key survives both redactors.
    PROPERTIES = %w[route path host referrer utm_source utm_medium utm_campaign utm_term utm_content ref
      user_agent country visitor_id_kind].freeze
    TAGS = %w[utm_source utm_medium utm_campaign utm_term utm_content ref].freeze
    ROUTE_LIMIT = 500
    PATH_LIMIT = 1_000
    HOST_LIMIT = 255
    REFERRER_LIMIT = 1_000
    TAG_LIMIT = 200
    USER_AGENT_LIMIT = 500
    COUNTRY_HEADERS = %w[HTTP_CF_IPCOUNTRY HTTP_CLOUDFRONT_VIEWER_COUNTRY].freeze
    # Cloudflare's unknown country and Tor.
    NO_COUNTRY = %w[XX T1].freeze
    PREFETCH_HEADERS = %w[HTTP_SEC_PURPOSE HTTP_X_SEC_PURPOSE].freeze
    NO_CONTENT = [ 204, 205 ].freeze
    FRAMEWORK_CONTROLLER = /\A(?:Rails|ActiveStorage)::/
    # Crawlers, link previews, LLM fetchers, monitors and bare HTTP clients. A
    # blank user agent is not counted either. "cloudfront" is what CloudFront
    # sends when a distribution does not forward the caller's user agent.
    BOT = Regexp.new([
      "bot", "crawl", "spider", "slurp", "scrap", "fetch", "monitor", "preview",
      "headless", "phantom", "selenium", "puppeteer", "playwright",
      "curl", "wget", "python-requests", "httpclient", "okhttp", "go-http-client", "java/",
      "facebookexternalhit", "twitterbot", "slackbot", "discordbot", "linkedinbot", "telegrambot", "whatsapp",
      "googlebot", "bingbot", "duckduckbot", "yandex", "baidu", "sogou", "seznam", "petalbot", "applebot",
      "ahrefs", "semrush", "mj12", "dotbot", "sistrix", "barkrowler", "serpstat", "dataforseo", "blexbot", "exabot",
      "gptbot", "chatgpt-user", "oai-searchbot", "claudebot", "claude-web", "anthropic", "cohere-ai",
      "perplexitybot", "amazonbot", "bytespider", "google-extended", "meta-externalagent",
      "cloudfront"
    ].map { |word| Regexp.escape(word) }.join("|"), Regexp::IGNORECASE)

    class << self
      def record(payload, client = RailsMind.client)
        request, response = payload[:request], payload[:response]
        return false unless request && response
        config = client.config
        return false unless counted?(payload, request, response, config)
        properties = properties(request)
        attributes = {}
        settable = settable?(response)
        if cookie_visitor?(request, settable, config)
          properties["visitor_id_kind"] = "cookie"
          request.set_header(Visitor::WRITE, { secure: request.ssl? }) if settable
        else
          properties["visitor_id_kind"] = "daily_hash"
          attributes[:visitor_id] = Visitor.daily_id(request)
        end
        attributes.merge!(user_id: nil, account_id: nil) unless config.link_page_views_to_users
        client.emit(:pageview, "#{payload[:controller]}##{payload[:action]}", properties: properties, **attributes)
      end

      private

      def counted?(payload, request, response, config)
        return false unless (payload[:method] || request.request_method) == "GET"
        return false unless (200..299).cover?(payload[:status].to_i)
        return false unless html?(payload, response)
        return false unless request.get_header("HTTP_TURBO_FRAME").to_s.empty?
        return false if PREFETCH_HEADERS.any? { |header| request.get_header(header).to_s.downcase.include?("prefetch") }
        return false if request.xhr?
        return false if payload[:controller].to_s.match?(FRAMEWORK_CONTROLLER)
        user_agent = request.user_agent.to_s
        return false if user_agent.strip.empty? || user_agent.match?(BOT)
        !ignored?(config, request)
      end

      # Rails types a streamed template only when the response commits, as
      # text/html like any response still untyped. An HTML request answered
      # with content and no type yet is such a page.
      def html?(payload, response)
        type = response.media_type
        return type == "text/html" if type
        payload[:format] == :html && !NO_CONTENT.include?(payload[:status].to_i)
      end

      # The cookie ID the request boundary put in context, unless the response
      # cannot take the cookie and the visitor brought none: a fresh ID there
      # could never be set, so that page view counts by the daily hash.
      def cookie_visitor?(request, settable, config)
        return false unless config.visitor_cookie
        return false if !settable && !request.get_header(Visitor::ENV_COOKIE)
        !Context.current[:visitor_id].to_s.empty?
      end

      # A hook that raises has not said the page view counts.
      def ignored?(config, request)
        hook = config.ignore_page_view
        hook ? hook.call(request) : false
      rescue StandardError
        true
      end

      # Not a response a shared cache may keep, nor one already on its way:
      # ActionController::Live sends the headers at the first write, before
      # the action ends.
      def settable?(response)
        return false if response.respond_to?(:committed?) && response.committed?
        !public?(response)
      end

      def public?(response)
        control = response.cache_control if response.respond_to?(:cache_control)
        return true if control.is_a?(Hash) && control[:public]
        response.get_header("Cache-Control").to_s.match?(Visitor::PUBLIC)
      end

      def properties(request)
        values = {}
        route = route(request)
        values["route"] = route if route
        values["path"] = request.filtered_path.to_s[0, PATH_LIMIT]
        values["host"] = request.host.to_s.downcase[0, HOST_LIMIT]
        referrer = referrer(request.referer)
        values["referrer"] = referrer if referrer
        values.merge!(tags(request))
        values["user_agent"] = request.user_agent.to_s[0, USER_AGENT_LIMIT]
        country = country(request)
        values["country"] = country if country
        values
      end

      # Inside a mounted engine Rails gives the engine's own pattern, so the
      # mount path (the request's script name) goes in front, as in the path.
      def route(request)
        return unless request.respond_to?(:route_uri_pattern)
        pattern = request.route_uri_pattern.to_s.delete_suffix("(.:format)")
        return if pattern.empty?
        pattern = "#{request.script_name}#{pattern}".chomp("/")
        (pattern.empty? ? "/" : pattern)[0, ROUTE_LIMIT]
      rescue StandardError
        nil
      end

      # Scheme, host and path only: a referring URL's query and fragment stay home.
      def referrer(value)
        return unless value.is_a?(String) && !value.strip.empty?
        uri = URI.parse(value.strip)
        return unless uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
        "#{uri.scheme.downcase}://#{uri.host.downcase}#{uri.path}"[0, REFERRER_LIMIT]
      rescue URI::Error
        nil
      end

      # A tag the app's filter_parameters would mask in the path is not sent.
      def tags(request)
        query = request.GET
        raw = TAGS.each_with_object({}) { |key, values| values[key] = query[key] if query[key].is_a?(String) }
        filtered = request.parameter_filter.filter(raw)
        raw.each_with_object({}) do |(key, value), tags|
          next unless filtered[key] == value
          value = value.strip
          tags[key] = value[0, TAG_LIMIT] unless value.empty?
        end
      rescue StandardError
        {}
      end

      def country(request)
        COUNTRY_HEADERS.each do |header|
          code = request.get_header(header).to_s.strip.upcase
          return code if code.match?(/\A[A-Z]{2}\z/) && !NO_COUNTRY.include?(code)
        end
        nil
      end
    end
  end
end
