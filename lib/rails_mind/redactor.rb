module RailsMind
  class Redactor
    FILTER = /password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|authorization|cookie|credential|session|email|phone|address|credit|card|body|params|arguments|bind|sql|db\.statement|query\.text/i
    MAX_STRING = 1024
    # Scrubbing reads at most this much of a string; what it sends is still at
    # most MAX_STRING. Every pass below is linear, and the cap bounds the rest.
    INPUT_LIMIT = 8192
    # Identity, correlation and release values are not free text: a numeric
    # account ID that passes the Luhn check is not a card number.
    PLAIN_FIELDS = %w[id kind occurred_at status release trace_id span_id parent_span_id request_id job_id visitor_id user_id account_id].freeze

    def call(value, depth = 0)
      return "[TRUNCATED]" if depth > 5
      case value
      when Hash
        value.first(50).to_h.transform_keys { |key| key.to_s[0, 100] }.each_with_object({}) do |(key, item), clean|
          clean[key] = if key.match?(FILTER) then "[FILTERED]"
          elsif depth.zero? && PLAIN_FIELDS.include?(key) && (item.is_a?(String) || item.is_a?(Symbol)) then scrub(item.to_s, free_text: false)
          else call(item, depth + 1)
          end
        end
      when Array then value.first(50).map { |item| call(item, depth + 1) }
      when String then scrub(value)
      when Integer, TrueClass, FalseClass, NilClass then value
      when Float then value.finite? ? value : nil
      when Symbol then scrub(value.to_s)
      else nil # Never call #inspect on application objects.
      end
    end

    # An authorization scheme names the credential that follows it, so the
    # scheme and the credential go together. Digest and AWS signature headers
    # carry several credential parts, so their whole value goes.
    SCHEME = "(?:bearer|basic|token|negotiate|ntlm|bot|apikey)\\s+".freeze
    WHOLE_VALUE_SCHEME = "(?:digest|aws4-hmac-sha256)\\s[^\\n]*".freeze

    # Exception messages carry what generic scrubbing cannot recognize: database
    # errors quote the row, key or input that failed (and the SQL with its
    # literals), and Ruby prints hashes and keyword arguments with their values,
    # header values wrapped in arrays (Net::HTTP#to_hash) included.
    DATABASE_ERROR = /\A(?:PG|Mysql2|Trilogy|SQLite3)::|StatementInvalid|RecordNotUnique|NotNullViolation|ForeignKeyViolation|ValueTooLong|RangeError\z/
    SENSITIVE_VALUE = /((?:"|:)?(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|authorization|credential|cookie|session|phone|ssn)\w{0,64}"?\s*(?:=>|:)\s*(?:\[(?!FILTERED\]))?)(?:\[FILTERED\]|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|#{WHOLE_VALUE_SCHEME}|(?:#{SCHEME})?[^\s,}\])]+)/i

    # PostgreSQL connections use standard_conforming_strings, where a backslash
    # does not escape the quote of a '...' literal (it does inside E'...');
    # MySQL lets it escape the quote. Text with a backslash is read both ways,
    # and anything either reading takes for a literal goes.
    STANDARD_LITERAL = /(?<!\w)[Ee]'(?:[^'\\]|\\.|'')*'?|'(?:[^']|'')*'?/
    ESCAPED_LITERAL = /'(?:[^'\\]|\\.|'')*'?/

    def scrub_message(error)
      text = bounded(error.message.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�"))
      text = text.gsub(SENSITIVE_VALUE, '\\1"[FILTERED]"')
        .gsub(/(Failing row contains )\([^\n]*\)/, "\\1(…)")
        .gsub(/(Key \([^)\n]*\)=)\([^\n]*\)/, "\\1(…)")
        .gsub(/(invalid input (?:syntax|value) for [^:\n]*: )"[^"\n]*"/, '\\1"…"')
      text = mask_literals(text) if database_error?(error)
      scrub(text)
    end

    # Userinfo runs to the last @ before the path, so an unencoded @ in a
    # password cannot leave its tail behind.
    USERINFO = %r{\b([a-z][a-z0-9+.\-]{0,31}://)[^\s/]*@}i
    EMAIL = /\b[A-Z0-9._%+\-]{1,128}@[A-Z0-9.\-]{1,253}\.[A-Z]{2,}\b/i
    AUTHORIZATION = /((?:proxy-)?authorization["']?\s*(?:=>|[=:])\s*(?:\[(?!FILTERED\]))?\s*["']?)(?:\[FILTERED\]|#{WHOLE_VALUE_SCHEME}|(?:#{SCHEME})?[^\s,;&"']+)/i
    KEY_VALUE = /((?:password|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|authorization)\s*(?:=>|[=:])\s*)(?:#{SCHEME})?[^\s,;&]+/i
    PROVIDER_TOKEN = /\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_\w{22,}|(?:AKIA|ASIA)[A-Z0-9]{16}\b|[sr]k_(?:live|test)_[A-Za-z0-9]{10,}|xox[abposr]-[A-Za-z0-9-]{10,}|sk-(?:proj-|ant-)?[A-Za-z0-9_-]{20,}|eyJ[\w-]{5,512}\.[\w-]{5,}\.[\w-]*)/
    SSN = /\b\d{3}([- ])\d{2}\1\d{4}\b/
    DIGIT_RUN = /(?<!\w)\d(?:[ -]?\d)*(?!\w)/

    def scrub(value, free_text: true)
      text = bounded(value.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�"))
        .gsub(USERINFO, '\\1[FILTERED]@')
        .gsub(EMAIL, "[EMAIL]")
        .gsub(AUTHORIZATION, '\\1[FILTERED]')
        .gsub(/\bBearer\s+\S+/i, "Bearer [FILTERED]")
        .gsub(KEY_VALUE, '\\1[FILTERED]')
      text = text.gsub(PROVIDER_TOKEN, "[FILTERED]").gsub(SSN, "[FILTERED]").gsub(DIGIT_RUN) { |run| mask_cards(run) } if free_text
      text.gsub(%r{https?://\S+}) { |url| url[/\A[^?#]*/] }.slice(0, MAX_STRING)
    end

    private

    def database_error?(error)
      error.class.ancestors.any? { |ancestor| ancestor.name.to_s.match?(DATABASE_ERROR) }
    end

    # A cut string ends at its last whitespace, so no half token is left that a
    # pass could no longer recognize.
    def bounded(text)
      return text if text.length <= INPUT_LIMIT
      text = text[0, INPUT_LIMIT]
      cut = text.rindex(/\s/)
      cut ? text[0, cut] : text
    end

    def mask_literals(text)
      return text.gsub(ESCAPED_LITERAL, "?") unless text.include?("\\")
      spans = [ STANDARD_LITERAL, ESCAPED_LITERAL ].flat_map { |pattern| text.to_enum(:scan, pattern).map { Regexp.last_match.offset(0) } }
      output, position = +"", 0
      merge(spans).each do |start, finish|
        output << text[position...start] << "?"
        position = finish
      end
      output << text[position..]
    end

    def merge(spans)
      spans.sort.each_with_object([]) do |(start, finish), merged|
        if merged.any? && start < merged.last[1]
          merged.last[1] = [ merged.last[1], finish ].max
        else
          merged << [ start, finish ]
        end
      end
    end

    # A card number is 13 to 19 digits, maybe in groups split by spaces or
    # dashes, that pass the Luhn check. A run of digit groups can hold one next
    # to other numbers (an expiry, a quantity), so every span of whole groups
    # with at most 19 digits is tried, and the longest that passes goes.
    def mask_cards(run)
      groups = run.to_enum(:scan, /\d+/).map { Regexp.last_match.offset(0) }
      digits = run.delete(" -")
      return run if digits.length < 13
      bounds, count = [], 0
      groups.each { |start, finish| bounds << [ count, count += finish - start ] }
      plain, doubled = luhn_sums(digits)
      output, position, first = +"", 0, 0
      while first < groups.size
        longest, from = nil, bounds[first][0]
        (first...groups.size).each do |last|
          to = bounds[last][1]
          break if to - from > 19
          next if to - from < 13
          parity = to % 2
          sum = doubled[parity][to] - doubled[parity][from] + plain[1 - parity][to] - plain[1 - parity][from]
          longest = last if (sum % 10).zero?
        end
        if longest
          output << run[position...groups[first][0]] << "[FILTERED]"
          position, first = groups[longest][1], longest + 1
        else
          first += 1
        end
      end
      output << run[position..]
    end

    # Prefix sums of each digit, plain and Luhn-doubled, split by position
    # parity. In a span ending at index `to`, Luhn doubles the digits whose
    # position has the parity of `to`, so any span's checksum is four lookups.
    def luhn_sums(digits)
      plain, doubled = Array.new(2) { [ 0 ] }, Array.new(2) { [ 0 ] }
      digits.each_char.with_index do |char, index|
        value = char.ord - 48
        twice = value * 2
        twice -= 9 if twice > 9
        [ 0, 1 ].each do |parity|
          own = index % 2 == parity
          plain[parity] << plain[parity].last + (own ? value : 0)
          doubled[parity] << doubled[parity].last + (own ? twice : 0)
        end
      end
      [ plain, doubled ]
    end
  end
end
