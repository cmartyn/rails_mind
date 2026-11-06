require "date"
require "openssl"
require "securerandom"
require "time"
require "rack/utils"

module RailsMind
  # Who is looking at a page before they sign in. By default a random ID kept in
  # a first-party cookie; when no cookie can be set, a hash of the day, the IP
  # and the user agent that changes every local day. The IP never leaves the app.
  module Visitor
    COOKIE = "_rails_mind_visitor".freeze
    # The gem mints lowercase version 4 UUIDs. Anything else in the cookie came
    # from somewhere else and is replaced, so hostile values never travel.
    ID = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    COOKIE_LIFETIME = 2 * 365 * 24 * 60 * 60
    # Purpose-specific, derived from secret_key_base. Never the ingest key:
    # RailsMind receives that with every batch and could brute-force the IPs.
    KEY_SALT = "rails_mind visitor v1".freeze

    # Rack env keys shared by the request boundary and the page-view subscriber.
    ENV_ID = "rails_mind.visitor_id".freeze
    ENV_COOKIE = "rails_mind.visitor_cookie".freeze
    ENV_DAILY = "rails_mind.daily_visitor_id".freeze
    WRITE = "rails_mind.write_visitor_cookie".freeze
    PUBLIC = /(?:\A|[,\s])public(?:\z|[,\s=])/i

    class << self
      def mint = SecureRandom.uuid

      # The first valid ID among the request's cookies of that name.
      def from_cookie(header)
        return unless header.is_a?(String)
        header.split(";").each do |pair|
          name, value = pair.split("=", 2)
          next unless name.to_s.strip == COOKIE
          value = value.to_s.strip
          return value if value.match?(ID)
        end
        nil
      end

      def daily_hash(remote_ip, user_agent, date = today)
        ip = remote_ip.to_s
        secret = key
        return if ip.empty? || secret.nil? || secret.empty?
        OpenSSL::HMAC.hexdigest("SHA256", secret, "#{date.iso8601}\n#{ip}\n#{user_agent}")[0, 32]
      end

      # One request keeps one hash, even across local midnight.
      def daily_id(request)
        env = request.env
        return env[ENV_DAILY] if env.key?(ENV_DAILY)
        env[ENV_DAILY] = daily_hash(request.remote_ip, request.user_agent)
      end

      # The local day in the app's time zone, the day RailsMind counts in.
      def today
        zone = Time.zone_default if Time.respond_to?(:zone_default)
        (zone ? zone.now : Time.now.utc).to_date
      end

      def key = @key ||= derive_key

      def derive_key
        return unless defined?(::Rails) && ::Rails.respond_to?(:application)
        ::Rails.application&.key_generator&.generate_key(KEY_SALT, 32)
      rescue StandardError
        nil
      end

      # At the request boundary: the visitor's cookie ID, or a fresh one for a GET
      # that may become a counted page view, goes into context so every event of
      # the request carries it. Only a GET can set the cookie, so other requests
      # without one get no ID.
      def start(env)
        client = RailsMind.client
        config = client.config
        return unless client.collector && config.analytics && config.page_views && config.visitor_cookie
        incoming = from_cookie(env["HTTP_COOKIE"])
        env[ENV_COOKIE] = incoming if incoming
        context = Context.current
        return unless context[:visitor_id].to_s.empty?
        id = incoming || (mint if env["REQUEST_METHOD"] == "GET")
        return unless id
        env[ENV_ID] = id
        context[:visitor_id] = id
      rescue StandardError
        nil
      end

      # After the app: a counted page view marked the request, so the cookie is
      # set or refreshed, unless the final response may be cached publicly.
      def finish(env, response)
        write = env[WRITE]
        id = env[ENV_ID]
        return unless write && id
        headers = response[1]
        return if (headers["cache-control"] || headers["Cache-Control"]).to_s.match?(PUBLIC)
        Rack::Utils.set_cookie_header!(headers, COOKIE, value: id, path: "/", expires: Time.now + COOKIE_LIFETIME,
          httponly: true, same_site: :lax, secure: write[:secure] == true)
      rescue StandardError
        nil
      end
    end
  end
end
