require_relative "test_helper"

class ClientTest < SDKTest
  def test_identity_restores_across_request_boundaries_and_is_fiber_local
    RailsMind.with_context(request_id: "request-1", visitor_id: "visitor-1") do
      RailsMind.identify(user_id: 21, account_id: 7, visitor_id: "visitor-1")
      Fiber.new { assert_empty RailsMind::Context.snapshot }.resume
      assert RailsMind.track("Invoice paid", amount_cents: 1000)
      assert_equal "21", @memory.events.last["user_id"]
      assert_equal "7", @memory.events.last["account_id"]
      assert_equal 1000, @memory.events.last.dig("properties", "amount_cents")
      assert_raises(RuntimeError) do
        RailsMind.with_context(account_id: "other") { raise "failure" }
      end
      assert_equal "7", RailsMind::Context.current[:account_id]
    end
    assert_empty RailsMind::Context.snapshot
  end

  def test_deep_redaction_and_untrusted_objects_never_inspected
    object = Object.new
    def object.inspect = raise("must never inspect")
    assert @client.emit(:event, "Signed up", properties: {
      password: "secret", nested: [ { email: "a@example.com", note: "Bearer token123" } ],
      url: "https://example.com/path?token=secret", object: object, arguments: [ "secret" ]
    })
    event = @memory.events.last
    assert_equal "[FILTERED]", event.dig("properties", "password")
    assert_equal "[FILTERED]", event.dig("properties", "nested", 0, "email")
    assert_equal "Bearer [FILTERED]", event.dig("properties", "nested", 0, "note")
    assert_equal "https://example.com/path", event.dig("properties", "url")
    assert_nil event.dig("properties", "object")
    refute_includes JSON.generate(event), "secret"
  end

  def test_stable_custom_ids_and_signal_controls
    @client.emit(:event, "Paid", id: "01J9CUSTOMULID")
    first = @memory.events.last["id"]
    @client.emit(:event, "Paid", id: "01J9CUSTOMULID")
    assert_equal first, @memory.events.last["id"]
    assert_match RailsMind::Client::UUID, first
    @config.apm = false
    refute @client.emit(:request, "Invoices#index")
    assert @client.emit(:error, "RuntimeError")
    @config.analytics = false
    refute @client.emit(:event, "Paid")
  end

  def test_exception_messages_scrubbed_by_default_omitted_on_opt_out_and_same_object_deduplicated
    error = RuntimeError.new("private balance 1000 password=swordfish for ann@example.com")
    error.set_backtrace([ "/Users/private/app/controllers/invoices_controller.rb:12:in 'show'" ])
    assert @client.capture_exception(error)
    refute @client.capture_exception(error)
    assert_equal 1, @memory.events.size
    assert_equal "private balance 1000 password=[FILTERED] for [EMAIL]", @memory.events.last.dig("properties", "message")
    assert_equal "app/controllers/invoices_controller.rb:12:in 'show'", @memory.events.last.dig("properties", "backtrace", 0)
    refute_includes JSON.generate(@memory.events), "swordfish"
    assert @client.capture_exception(RuntimeError.new("second occurrence"))

    @config.capture_exception_message = false
    assert @client.capture_exception(RuntimeError.new("kept at home"))
    assert_equal "[Message omitted]", @memory.events.last.dig("properties", "message")
    refute_includes JSON.generate(@memory.events), "kept at home"
  end

  def test_gem_and_ruby_frames_keep_their_origin_so_they_never_pass_for_application_code
    error = RuntimeError.new("boom")
    error.set_backtrace([
      "/Users/private/app/controllers/invoices_controller.rb:12:in 'show'",
      "/Users/private/.rvm/gems/ruby-4.0.7/gems/activerecord-8.1.4/lib/active_record/relation.rb:10:in 'load'",
      "/Users/private/.rvm/rubies/ruby-4.0.7/lib/ruby/4.0.0/monitor.rb:31:in 'synchronize'",
      "/srv/app/vendor/bundle/ruby/4.0.0/bundler/gems/rails-abc123def/actionpack/lib/action_controller/metal.rb:5:in 'dispatch'",
      "<internal:kernel>:187:in 'loop'"
    ])
    assert @client.capture_exception(error)
    assert_equal [
      "app/controllers/invoices_controller.rb:12:in 'show'",
      "gems/activerecord-8.1.4/lib/active_record/relation.rb:10:in 'load'",
      "ruby/4.0.0/monitor.rb:31:in 'synchronize'",
      "gems/rails-abc123def/actionpack/lib/action_controller/metal.rb:5:in 'dispatch'",
      "<internal:kernel>:187:in 'loop'"
    ], @memory.events.last.dig("properties", "backtrace")
    refute_includes JSON.generate(@memory.events), "private"

    other = RuntimeError.new("boom")
    other.set_backtrace([ "/srv/shop/app/models/gems/catalog/importer.rb:4:in 'run'",
      "/usr/lib/ruby/vendor_ruby/3.3.0/json/common.rb:9:in 'parse'" ])
    assert @client.capture_exception(other)
    assert_equal [ "app/models/gems/catalog/importer.rb:4:in 'run'", "ruby/vendor_ruby/3.3.0/json/common.rb:9:in 'parse'" ],
      @memory.events.last.dig("properties", "backtrace")
  end

  module ProbeDatabase
    class StatementInvalid < StandardError; end
  end

  def test_database_errors_and_printed_hashes_lose_their_values
    [
      [ ProbeDatabase::StatementInvalid.new("PG::NotNullViolation: ERROR:  null value in column \"plan\" violates not-null constraint\nDETAIL:  Failing row contains (42, Jane Customer, $2a$12$Kq0bX, 9f86d081, null)."),
        "PG::NotNullViolation: ERROR:  null value in column \"plan\" violates not-null constraint\nDETAIL:  Failing row contains (…)." ],
      [ ProbeDatabase::StatementInvalid.new("PG::UniqueViolation: ERROR:  duplicate key value violates unique constraint \"index_users_on_api_token\"\nDETAIL:  Key (api_token)=(tok_live_9f8e7d6c5b4a) already exists."),
        "PG::UniqueViolation: ERROR:  duplicate key value violates unique constraint \"index_users_on_api_token\"\nDETAIL:  Key (api_token)=(…) already exists." ],
      [ ProbeDatabase::StatementInvalid.new("Mysql2::Error: Duplicate entry 'tok_live_9f8e' for key 'users.index_users_on_api_token'"),
        "Mysql2::Error: Duplicate entry ? for key ?" ],
      [ ProbeDatabase::StatementInvalid.new("PG::InvalidTextRepresentation: ERROR:  invalid input syntax for type uuid: \"5f3e-secret\"\nLINE 1: SELECT * FROM users WHERE token = 'abc123' AND id = '5f3e-secret'"),
        "PG::InvalidTextRepresentation: ERROR:  invalid input syntax for type uuid: \"…\"\nLINE 1: SELECT * FROM users WHERE token = [FILTERED] AND id = ?" ],
      [ ArgumentError.new("bad options {\"password\" => \"hunter2\", \"api_key\" => \"sk_live_51H\", \"plan\" => \"team\"} and {access_token: \"abc\"}"),
        "bad options {\"password\" => \"[FILTERED]\", \"api_key\" => \"[FILTERED]\", \"plan\" => \"team\"} and {access_token: [FILTERED]" ]
    ].each do |error, expected|
      assert @client.capture_exception(error)
      assert_equal expected, @memory.events.last.dig("properties", "message")
    end
  end

  def test_hook_cannot_bypass_redaction_or_invent_protocol_keys
    @config.before_send = ->(event) { event.merge("raw_request" => "secret", "properties" => { token: "secret" }) }
    @client.emit(:event, "Paid")
    refute @memory.events.last.key?("raw_request")
    assert_equal "[FILTERED]", @memory.events.last.dig("properties", "token")
    @config.before_send = ->(_event) { raise "hook failed" }
    refute @client.emit(:event, "Paid")
  end

  def test_credential_key_variants_are_filtered_before_buffering
    properties = %w[api_key apiKey API-KEY access_key accessKey private_key privateKey].to_h { |key| [ key, "secret-value" ] }
    @client.emit(:event, "Privacy check", properties: properties)
    assert @memory.events.last["properties"].values.all? { |value| value == "[FILTERED]" }
    refute_includes JSON.generate(@memory.events), "secret-value"
    RailsMind.with_context(user_id: 123, account_id: 456) do
      @client.emit(:event, "Identity")
      assert_equal "123", @memory.events.last["user_id"]
      assert_equal "456", @memory.events.last["account_id"]
    end
  end

  def test_payload_boundaries_cannot_poison_the_entire_batch
    @client.emit(:event, "🧠" * 1000)
    assert_operator @memory.events.last["name"].bytesize, :<=, 500
    assert @memory.events.last["name"].valid_encoding?
    refute @client.emit(:request, "Index", duration_ms: -1)
    refute @client.emit(:event, "")
    @config.before_send = ->(event) { event.merge("properties" => "wrong shape") }
    refute @client.emit(:event, "Index")
  end

  def test_non_loopback_http_and_credentials_in_url_rejected
    @config.endpoint = "http://example.com"
    assert_raises(ArgumentError) { @config.validate! }
    @config.endpoint = "https://user:password@example.com"
    assert_raises(ArgumentError) { @config.validate! }
  end
end
