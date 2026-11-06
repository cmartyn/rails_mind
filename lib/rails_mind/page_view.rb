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
    # Rails' own pages, Active Storage, and the stub pages turbo-rails serves a
    # Hotwire Native app to recede, resume or refresh.
    FRAMEWORK_CONTROLLER = /\A(?:Rails|ActiveStorage|Turbo::Native)::/
    FILTERED = "[FILTERED]".freeze
    # A masked value at least this long is also masked wherever it appears in
    # the query string; a shorter one would mask unrelated values there.
    QUERY_MASK_MIN = 8
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
        # A browser asks for HTML when it loads a page; scripts, pollers and bare
        # HTTP clients that take whatever comes back are not people reading it.
        return false unless request.get_header("HTTP_ACCEPT").to_s.include?("text/html")
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
      # ActionController::Live sends the headers at the first write or render,
      # before the action ends.
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
        values["path"] = path(request)[0, PATH_LIMIT]
        values["host"] = request.host.to_s.downcase[0, HOST_LIMIT]
        referrer = referrer(request.referer, request.host)
        values["referrer"] = referrer if referrer
        values.merge!(tags(request, secret_values(request)))
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
        script = request.script_name.to_s
        secrets = filtered_path_values(request)
        script = mask(script, secrets) unless script.empty? || secrets.empty?
        pattern = "#{script}#{pattern}".chomp("/")
        (pattern.empty? ? "/" : pattern)[0, ROUTE_LIMIT]
      rescue StandardError
        nil
      end

      # The query string goes through the app's filter_parameters, and so do
      # the route's own segments: a token in /passwords/:token/edit is masked
      # like one in ?token=.
      # If masking fails, the path is not sent at all: never the unmasked one.
      def path(request)
        path = request.filtered_path.to_s
        secrets = filtered_path_values(request)
        secrets.empty? ? path : mask(path, secrets)
      rescue StandardError
        FILTERED
      end

      # Each path parameter the app's filter masks, as written and as escaped,
      # compared as bytes so a path in any encoding can be searched. Keys go to
      # the filter as strings, as Rails' own filtered_parameters gives them.
      def filtered_path_values(request)
        params = request.path_parameters.except(:controller, :action, :format).transform_keys(&:to_s)
        return [] if params.empty?
        filtered = request.parameter_filter.filter(params)
        params.each_with_object([]) do |(key, value), secrets|
          next unless value.is_a?(String) && !value.empty? && filtered[key] != value
          secrets.push(value, Rack::Utils.escape_path(value), Rack::Utils.escape(value).gsub("+", "%20"))
        end.map(&:b).uniq
      end

      # Every route segment holding a secret goes whole (with any .format or
      # text around it), a secret spanning segments (a glob route) goes, and a
      # long secret repeated in the query goes too. Masking too much costs a
      # little detail; masking too little sends a credential.
      def mask(text, secrets)
        return text if text.empty?
        route_part, query = text.b.split("?", 2)
        filtered = FILTERED.b
        globs = secrets.select { |secret| secret.include?("/".b) }
        globs.each { |secret| route_part = route_part.gsub(secret, filtered) }
        pieces = (secrets + globs.flat_map { |secret| secret.split("/".b) }).reject(&:empty?).uniq
        masked = route_part.split("/", -1).map { |segment| secret_in?(segment, pieces) ? filtered : segment }.join("/")
        masked = "#{masked}?#{mask_query(query, secrets)}".b if query
        masked.force_encoding(Encoding::UTF_8).scrub
      end

      # A long secret goes wherever it appears; a query value that is, or holds
      # as a path piece, any secret goes whole (a back link to the masked page).
      def mask_query(query, secrets)
        filtered = FILTERED.b
        secrets.each { |secret| query = query.gsub(secret, filtered) if secret.bytesize >= QUERY_MASK_MIN }
        query.split("&".b, -1).map do |pair|
          key, value = pair.split("=".b, 2)
          next pair unless value
          decoded = begin
            Rack::Utils.unescape(value).b
          rescue StandardError
            value
          end
          pieces = decoded.split("/".b)
          secrets.any? { |secret| decoded == secret || pieces.include?(secret) } ? "#{key}=#{filtered}".b : pair
        end.join("&".b)
      end

      # The route's masked values, for the path and the campaign tags.
      def secret_values(request)
        filtered_path_values(request)
      rescue StandardError
        []
      end

      def secret_in?(segment, secrets)
        decoded = begin
          Rack::Utils.unescape_path(segment).b
        rescue StandardError
          segment
        end
        secrets.any? { |secret| segment.include?(secret) || decoded.include?(secret) }
      end

      # Another site's scheme, host and path; its query and fragment stay home.
      # A link inside the app sends only its origin, since its path can hold
      # what the app masks in its own paths (a reset token, for one).
      def referrer(value, host = nil)
        return unless value.is_a?(String) && !value.strip.empty?
        uri = URI.parse(value.strip)
        return unless uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
        origin = "#{uri.scheme.downcase}://#{uri.host.downcase}"
        return origin if same_site?(uri.host, host)
        "#{origin}#{uri.path}"[0, REFERRER_LIMIT]
      rescue URI::Error
        nil
      end

      def same_site?(referrer_host, host)
        return false if host.to_s.empty?
        bare = ->(name) { name.to_s.downcase.delete_prefix("www.") }
        bare.call(referrer_host) == bare.call(host)
      end

      # A tag the app's filter_parameters would mask in the query is not sent,
      # nor one holding a value it masks in the route.
      def tags(request, secrets = [])
        query = request.GET
        raw = TAGS.each_with_object({}) { |key, values| values[key] = query[key] if query[key].is_a?(String) }
        filtered = request.parameter_filter.filter(raw)
        raw.each_with_object({}) do |(key, value), tags|
          next unless filtered[key] == value
          next if secrets.any? { |secret| value.b.include?(secret) }
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
