module RailsMind
  module Context
    KEYS = %i[request_id job_id trace_id span_id parent_span_id visitor_id user_id account_id].freeze
    module_function

    # Thread#[] is fiber-local. Every request/job boundary restores its previous context.
    def current = Thread.current[:rails_mind_context] ||= {}
    def snapshot = current.select { |key, _| KEYS.include?(key) }.dup

    def with(values)
      previous = current
      identifiers = values.transform_keys(&:to_sym).slice(*KEYS).transform_values do |value|
        value.to_s if value.is_a?(String) || value.is_a?(Integer) || value.is_a?(Symbol)
      end
      Thread.current[:rails_mind_context] = previous.merge(identifiers)
      yield
    ensure
      Thread.current[:rails_mind_context] = previous
    end

    def identify(user_id: nil, account_id: nil, visitor_id: nil)
      current.merge!(user_id: user_id&.to_s, account_id: account_id&.to_s, visitor_id: visitor_id&.to_s)
    end

    def suppressed? = Thread.current[:rails_mind_suppressed] == true

    def suppress
      previous = Thread.current[:rails_mind_suppressed]
      Thread.current[:rails_mind_suppressed] = true
      yield
    ensure
      Thread.current[:rails_mind_suppressed] = previous
    end
  end
end
