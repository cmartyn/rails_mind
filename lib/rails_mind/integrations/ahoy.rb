require "ahoy"

module RailsMind
  module Integrations
    module AhoyDelivery
      def rails_mind_visit(data)
        RailsMind.client.emit(:visit, "$visit", id: data[:visit_token], occurred_at: data[:started_at],
          visitor_id: data[:visitor_token], user_id: data[:user_id]&.to_s,
          properties: data.slice(:referring_domain, :utm_source, :utm_medium, :utm_campaign, :browser, :os, :device_type))
      rescue StandardError
        false
      end

      def rails_mind_event(data)
        RailsMind.client.emit(:event, data[:name], id: data[:event_id], occurred_at: data[:time],
          visitor_id: ahoy&.visitor_token, user_id: data[:user_id]&.to_s,
          properties: data.fetch(:properties, {}).merge(visit_id: data[:visit_token]))
      rescue StandardError
        false
      end

      def rails_mind_authenticate(data)
        RailsMind.client.emit(:event, "$identify", visitor_id: ahoy&.visitor_token,
          user_id: data[:user_id]&.to_s, properties: { visit_id: data[:visit_token] })
      rescue StandardError
        false
      end
    end

    # Explicit hosted-only option. Set `class Ahoy::Store < ...` in the app.
    # This intentionally has no visit ActiveRecord model or geocoding persistence.
    class AhoyStore < ::Ahoy::BaseStore
      include AhoyDelivery

      def track_visit(data) = rails_mind_visit(data)
      def track_event(data) = rails_mind_event(data)
      def authenticate(data) = rails_mind_authenticate(data)
    end

    # Explicit coexistence option. Prepend once to the customer's existing Store.
    # The existing store runs first; its arguments, exceptions and return value survive.
    module AhoyMirror
      include AhoyDelivery

      def track_visit(data)
        result = super
        rails_mind_visit(data)
        result
      end

      def track_event(data)
        result = super
        rails_mind_event(data)
        result
      end

      def authenticate(data)
        result = super
        rails_mind_authenticate(data)
        result
      end
    end

    def self.mirror_ahoy!(store = ::Ahoy::Store)
      store.prepend(AhoyMirror) unless store.ancestors.include?(AhoyMirror)
    end
  end
end
