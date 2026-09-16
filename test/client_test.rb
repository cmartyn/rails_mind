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

  def test_exception_messages_omitted_and_same_object_deduplicated
    error = RuntimeError.new("private balance 1000 password=swordfish")
    error.set_backtrace([ "/Users/private/app/controllers/invoices_controller.rb:12:in 'show'" ])
    assert @client.capture_exception(error)
    refute @client.capture_exception(error)
    assert_equal 1, @memory.events.size
    assert_equal "[Message omitted]", @memory.events.last.dig("properties", "message")
    assert_equal "app/controllers/invoices_controller.rb:12:in 'show'", @memory.events.last.dig("properties", "backtrace", 0)
    refute_includes JSON.generate(@memory.events), "swordfish"
    assert @client.capture_exception(RuntimeError.new("second occurrence"))
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
