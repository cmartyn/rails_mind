require_relative "test_helper"
require "active_support"
require "rails_mind/integrations/rails"

# Adversarial inputs that must lose every secret before an event is buffered.
# Each entry pairs a text with the secret fragments it carries; none of them
# may survive in an exception message, an event property or a query shape.
class RedactionCorpusTest < SDKTest
  module ProbeDatabase
    class StatementInvalid < StandardError; end
  end

  # Token-shaped fixtures are assembled at runtime, so the repository never holds a
  # literal that secret scanning treats as a live provider key.
  GITHUB_CLASSIC = [ "ghp", "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8" ].join("_")
  GITHUB_OAUTH = [ "gho", "16C7e42F292c6912E7710c838347Ae178B4a" ].join("_")
  GITHUB_PAT = [ "github", "pat", "11ABCDEFG0123456789", "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOP" ].join("_")
  AWS_KEY = [ "AKIA", "IOSFODNN7EXAMPLE" ].join
  STRIPE_LIVE = [ "sk", "live", "51Habcdefghijklmnopqrstuv" ].join("_")
  STRIPE_TEST = [ "sk", "test", "4eC39HqLyjWDarjtT1zdp7dc" ].join("_")
  SLACK_BOT = [ "xoxb", "1234567890", "0987654321", "abcdefghijklmnopqrstuvwx" ].join("-")
  SLACK_USER = [ "xoxp", "1234567890", "1234567890", "1234567890", "abcdef0123456789abcdef0123456789" ].join("-")
  JWT_PARTS = [ "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
    "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ",
    "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c" ].freeze

  CREDENTIALS = {
    "Authorization: Bearer abc.def-ghi_123456789" => %w[abc.def-ghi_123456789],
    "Authorization: Basic dXNlcjpwYXNzd29yZA==" => %w[dXNlcjpwYXNzd29yZA==],
    "Authorization: Token tok_8d7f6e5c4b3a2190" => %w[tok_8d7f6e5c4b3a2190],
    "authorization: bearer lowercase-credential-0001" => %w[lowercase-credential-0001],
    "authorization: basic bG93ZXI6Y2FzZQ==" => %w[bG93ZXI6Y2FzZQ==],
    "authorization=Basic Zm9vOmJhcg==" => %w[Zm9vOmJhcg==],
    "Authorization=Token token-with-equals-0002" => %w[token-with-equals-0002],
    "AUTHORIZATION:Bearer nospace-credential-0005" => %w[nospace-credential-0005],
    "Proxy-Authorization: Basic cHJveHk6c2VjcmV0" => %w[cHJveHk6c2VjcmV0],
    "request failed {\"Authorization\" => \"Bearer quoted-credential-0003\"}" => %w[quoted-credential-0003],
    "request failed {\"Authorization\" => \"Basic cXVvdGVkOmJhc2lj\"}" => %w[cXVvdGVkOmJhc2lj],
    "headers {authorization: \"Token symbol-credential-0004\"}" => %w[symbol-credential-0004],
    "headers {authorization: Token bare-symbol-credential-0018}" => %w[bare-symbol-credential-0018],
    "{\"authorization\":\"Bearer json-credential-0006\"}" => %w[json-credential-0006],
    # Net::HTTP#to_hash wraps each header value in an array (old and Ruby 3.4+ inspect forms).
    "{\"authorization\"=>[\"Basic YXJyYXk6Y3JlZGVudGlhbA==\"]}" => %w[YXJyYXk6Y3JlZGVudGlhbA==],
    "{\"authorization\" => [\"Basic c3BhY2VkOmFycmF5\"]}" => %w[c3BhY2VkOmFycmF5],
    "{\"Authorization\" => [\"Bearer array-bearer-credential-0021\"]}" => %w[array-bearer-credential-0021],
    "{authorization: [\"Token array-symbol-credential-0022\"]}" => %w[array-symbol-credential-0022],
    "Authorization: Digest username=\"ann\", realm=\"api\", nonce=\"dcd98b7102dd2f0e\", response=\"6629fae49393a05397450978507c4ef1\"" =>
      %w[dcd98b7102dd2f0e 6629fae49393a05397450978507c4ef1],
    "Authorization: AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261013/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-date, Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7" =>
      %w[AKIDEXAMPLE 5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7],
    "Error connecting to redis://:redispassword0007@cache.internal:6379/0" => %w[redispassword0007],
    "rediss://default:tlsredispass0008@cache.example.com:6380" => %w[tlsredispass0008],
    "amqp://guest:amqppassword0009@rabbit:5672/vhost" => %w[amqppassword0009],
    "could not connect to postgres://app:pgpassword0010@db.internal:5432/app_production" => %w[pgpassword0010],
    "postgresql://app:pgpassword0011@db/app" => %w[pgpassword0011],
    "mysql2://root:mysqlpassword0012@127.0.0.1/app" => %w[mysqlpassword0012],
    "mysql://user:p%40ssword0019@host/db" => %w[p%40ssword0019],
    "mongodb+srv://admin:mongopassword0013@cluster0.example.net/db" => %w[mongopassword0013],
    "mongodb://admin:p4$$w0rd!0020@mongo:27017" => %w[p4$$w0rd!0020],
    "could not connect to postgres://app:Sup3r@Secret!0023@10.0.0.5/db" => %w[Sup3r Secret!0023],
    "GitHub rejected #{GITHUB_CLASSIC}" => [ GITHUB_CLASSIC ],
    "oauth #{GITHUB_OAUTH}" => [ GITHUB_OAUTH ],
    "pat #{GITHUB_PAT}" => [ GITHUB_PAT ],
    "AWS denied #{AWS_KEY} for s3:GetObject" => [ AWS_KEY ],
    "Stripe::AuthenticationError: Invalid API Key provided: #{STRIPE_LIVE}" => [ STRIPE_LIVE ],
    "using #{STRIPE_TEST}" => [ STRIPE_TEST ],
    "Slack #{SLACK_BOT}" => [ SLACK_BOT ],
    "Slack #{SLACK_USER}" => [ SLACK_USER ],
    "JWT::ExpiredSignature #{JWT_PARTS.join(".")}" => JWT_PARTS,
    "card 4111 1111 1111 1111 declined" => [ "4111 1111 1111 1111", "1111 1111" ],
    "card 5555-5555-5555-4444 declined" => %w[5555-5555-5555-4444 5555-4444],
    "amex 378282246310005" => %w[378282246310005],
    "charge {:number=>\"4242424242424242\"}" => %w[4242424242424242],
    "short visa 4222222222222" => %w[4222222222222],
    "maestro 6304 0000 0000 0000 000" => [ "6304 0000 0000 0000 000" ],
    "card 4111 1111 1111 1111 12/28 declined" => [ "4111 1111 1111 1111" ],
    "qty 2 4111-1111-1111-1111" => %w[4111-1111-1111-1111],
    "cards #{'4111 1111 1111 1111 ' * 300}" => [ "4111 1111 1111 1111" ],
    "applicant SSN 123-45-6789 rejected" => %w[123-45-6789],
    "{ssn: \"078-05-1120\"}" => %w[078-05-1120],
    "contact {phone: \"+1 415 555 0100\"}" => [ "415 555 0100" ]
  }.freeze

  def test_no_credential_or_personal_data_survives_in_an_exception_message
    CREDENTIALS.each do |text, secrets|
      assert @client.capture_exception(RuntimeError.new(text)), text
      message = @memory.events.last.dig("properties", "message")
      secrets.each { |secret| refute_includes message, secret, "#{text.inspect} became #{message.inspect}" }
    end
  end

  def test_no_credential_or_personal_data_survives_in_an_event_property
    CREDENTIALS.each do |text, secrets|
      next if text.include?("phone:") # a phone number is recognized only by its printed key
      @client.emit(:event, "Corpus", properties: { note: text, nested: [ { detail: text } ] })
      event = JSON.generate(@memory.events.last)
      secrets.each { |secret| refute_includes event, secret, "#{text.inspect} became #{event}" }
    end
  end

  def test_context_around_a_secret_stays_readable
    {
      "Authorization: Bearer abc.def-ghi_123456789" => "Authorization: [FILTERED]",
      "authorization=Basic Zm9vOmJhcg==" => "authorization=[FILTERED]",
      "Error connecting to redis://:redispassword0007@cache.internal:6379/0" => "Error connecting to redis://[FILTERED]@cache.internal:6379/0",
      "applicant SSN 123-45-6789 rejected" => "applicant SSN [FILTERED] rejected",
      "card 4111 1111 1111 1111 declined" => "card [FILTERED] declined",
      "order 1234567812345678 shipped at 1760000000" => "order 1234567812345678 shipped at 1760000000",
      "AWS denied #{AWS_KEY} for s3:GetObject" => "AWS denied [FILTERED] for s3:GetObject",
      "Basic authentication failed for Token expired" => "Basic authentication failed for Token expired"
    }.each do |text, expected|
      assert @client.capture_exception(RuntimeError.new(text))
      assert_equal expected, @memory.events.last.dig("properties", "message")
    end
  end

  # Events are redacted again after before_send, so scrubbed text must stay put.
  def test_scrubbing_scrubbed_text_changes_nothing
    redactor = RailsMind::Redactor.new
    [ "Authorization: [FILTERED]", "{\"authorization\" => [FILTERED]}", "{\"authorization\"=>[\"[FILTERED]\"]}",
      "Authorization => [FILTERED] keep these words", "redis://[FILTERED]@cache:6379", "card [FILTERED] 12/28" ].each do |text|
      assert_equal text, redactor.scrub(text)
    end
    message = redactor.scrub_message(RuntimeError.new("{authorization: [FILTERED], plan: \"team\"}"))
    assert_equal "{authorization: [FILTERED], plan: \"team\"}", message
  end

  # Card, SSN and provider-token rules are for free text. A numeric identity or
  # a timestamp release that happens to pass the Luhn check is not a card.
  def test_identity_and_release_values_are_not_mistaken_for_cards
    @config.release = "20261013123405"
    RailsMind.with_context(user_id: 4_100_000_000_000_001, account_id: "4111111111111111", visitor_id: "378282246310005", request_id: "123-45-6789") do
      @client.emit(:event, "Signed up", properties: { note: "card 4111111111111111" })
    end
    event = @memory.events.last
    assert_equal "4100000000000001", event["user_id"]
    assert_equal "4111111111111111", event["account_id"]
    assert_equal "378282246310005", event["visitor_id"]
    assert_equal "123-45-6789", event["request_id"]
    assert_equal "20261013123405", event["release"]
    assert_equal "card [FILTERED]", event.dig("properties", "note")
    RailsMind.with_context(user_id: "ann@example.com") { @client.emit(:event, "Signed up") }
    assert_equal "[EMAIL]", @memory.events.last["user_id"]
  end

  # Every pass is linear in its input; long hostile strings stay cheap.
  def test_hostile_inputs_scrub_quickly
    redactor = RailsMind::Redactor.new
    database_error = ProbeDatabase::StatementInvalid.new("PG::SyntaxError: #{"'a\\' " * 10_000}")
    {
      "digit groups" => -> { redactor.scrub("1 " * 50_000) },
      "URL scheme" => -> { redactor.scrub("a." * 50_000 + "://") },
      "JWT prefix" => -> { redactor.scrub("eyJab-" * 16_000) },
      "key word" => -> { redactor.scrub_message(RuntimeError.new("token" * 20_000)) },
      "quoted key values" => -> { redactor.scrub_message(RuntimeError.new("password: \"" * 10_000)) },
      "URL queries" => -> { redactor.scrub("http://" * 10_000) },
      "email local parts" => -> { redactor.scrub("a." * 50_000) },
      "ambiguous literals" => -> { redactor.scrub_message(database_error) },
      "ambiguous SQL" => -> { RailsMind::Integrations::RailsNotifications.normalize(("a = 'x\\' -- c\n" * 2_000)[0, 16_384]) }
    }.filter_map do |name, scrub|
      elapsed = 3.times.map do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        scrub.call
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end.min
      "#{name} took #{(elapsed * 1000).round} ms" if elapsed >= 0.1
    end.then { |slow| assert_empty slow }
  end

  # PostgreSQL connections use standard_conforming_strings: a backslash does not
  # escape the quote of a '...' literal, but does inside E'...'. MySQL lets a
  # backslash escape it. Neither reading may let the next literal out.
  SQL = {
    "SELECT * FROM users WHERE name = 'trailing\\' AND reset_digest = 'pgsecret0015' LIMIT 1" => %w[pgsecret0015],
    "SELECT * FROM users WHERE name = 'C:\\' OR name = 'second-literal-secret' OR token = 'third-literal-secret'" =>
      %w[second-literal-secret third-literal-secret],
    "SELECT * FROM notes WHERE body = E'it\\'s ok' AND tag = 'esecret0016'" => %w[esecret0016],
    "SELECT * FROM users WHERE last_name = 'O\\'Brien' AND api_token = 'tok_live_9f8e7d'" => %w[tok_live_9f8e7d],
    "SELECT * FROM \"users\\\" WHERE note = 'quoted-identifier-secret'\" LIMIT 1" => %w[quoted-identifier-secret],
    "SELECT * FROM users WHERE a = 'x\\' -- ' AND b = 'comment-adjacent-secret'" => %w[comment-adjacent-secret]
  }.freeze

  def test_no_literal_survives_a_query_shape_whatever_the_quoting_rules
    SQL.each do |sql, secrets|
      [ false, true ].each do |mysql|
        shape = RailsMind::Integrations::RailsNotifications.normalize(sql, mysql: mysql)
        secrets.each { |secret| refute_includes shape, secret, "#{sql.inspect} (mysql: #{mysql}) became #{shape.inspect}" }
      end
    end
  end

  def test_no_literal_survives_a_database_error_message
    SQL.each do |sql, secrets|
      error = ProbeDatabase::StatementInvalid.new("PG::SyntaxError: ERROR:  syntax error at or near \"AND\"\nLINE 1: #{sql}")
      assert @client.capture_exception(error)
      message = @memory.events.last.dig("properties", "message")
      secrets.each { |secret| refute_includes message, secret, "#{sql.inspect} became #{message.inspect}" }
    end
  end

  def test_a_trailing_backslash_literal_keeps_the_query_structure_before_it
    sql = "SELECT * FROM users WHERE name = 'trailing\\' AND reset_digest = 'pgsecret0015' LIMIT 1"
    assert_equal "SELECT * FROM users WHERE name = ?", RailsMind::Integrations::RailsNotifications.normalize(sql)
    plain = "SELECT * FROM users WHERE name = 'ann' AND id = 7 /* app:shop */ LIMIT 1"
    assert_equal "SELECT * FROM users WHERE name = ? AND id = ? LIMIT ?", RailsMind::Integrations::RailsNotifications.normalize(plain)
  end
end
