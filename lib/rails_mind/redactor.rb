module RailsMind
  class Redactor
    FILTER = /password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|authorization|cookie|credential|session|email|phone|address|credit|card|body|params|arguments|bind|sql|db\.statement|query\.text/i
    MAX_STRING = 1024

    def call(value, depth = 0)
      return "[TRUNCATED]" if depth > 5
      case value
      when Hash
        value.first(50).to_h.transform_keys { |key| key.to_s[0, 100] }.each_with_object({}) do |(key, item), clean|
          clean[key] = key.match?(FILTER) ? "[FILTERED]" : call(item, depth + 1)
        end
      when Array then value.first(50).map { |item| call(item, depth + 1) }
      when String then scrub(value)
      when Integer, TrueClass, FalseClass, NilClass then value
      when Float then value.finite? ? value : nil
      when Symbol then scrub(value.to_s)
      else nil # Never call #inspect on application objects.
      end
    end

    def scrub(value)
      value.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
        .gsub(/\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b/i, "[EMAIL]")
        .gsub(/\bBearer\s+\S+/i, "Bearer [FILTERED]")
        .gsub(/((?:password|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|authorization)\s*[=:]\s*)[^\s,;&]+/i, '\\1[FILTERED]')
        .gsub(%r{(https?://)[^\s/@]+:[^\s/@]+@}, '\\1[FILTERED]@')
        .gsub(%r{(https?://[^\s?#]+)[?#][^\s]*}, '\\1')
        .slice(0, MAX_STRING)
    end
  end
end
