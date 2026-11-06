require_relative "test_helper"
require "minitest/mock"
require "active_support"
require "active_support/key_generator"
require "rack"
require "rails_mind/integrations/rails"

class VisitorTest < SDKTest
  VISITOR = "0b6f2f8e-1c2d-4e5f-9a0b-1c2d3e4f5a6b".freeze
  BROWSER_ACCEPT = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8".freeze
  KEY = ("k" * 32).freeze

  def setup
    super
    RailsMind::Integrations::RailsNotifications.install!
  end

  def teardown
    RailsMind::Integrations::RailsNotifications.uninstall!
    super
  end

  def test_only_a_lowercase_version_4_uuid_cookie_is_accepted
    assert_equal VISITOR, RailsMind::Visitor.from_cookie("_rails_mind_visitor=#{VISITOR}")
    assert_equal VISITOR, RailsMind::Visitor.from_cookie("theme=dark; _rails_mind_visitor=#{VISITOR}; other=1")
    assert_equal VISITOR, RailsMind::Visitor.from_cookie("_rails_mind_visitor=junk; _rails_mind_visitor=#{VISITOR}")
    [ nil, "", "theme=dark", "_rails_mind_visitor=", "_rails_mind_visitor=#{VISITOR.upcase}",
      "_rails_mind_visitor=#{VISITOR}x", "_rails_mind_visitor=#{VISITOR.delete('-')}",
      "_rails_mind_visitor=0b6f2f8e-1c2d-1e5f-9a0b-1c2d3e4f5a6b", "_rails_mind_visitor='; DROP TABLE visitors",
      "x_rails_mind_visitor=#{VISITOR}" ].each do |header|
      assert_nil RailsMind::Visitor.from_cookie(header), header.inspect
    end
  end

  def test_minted_ids_are_lowercase_version_4_uuids
    ids = Array.new(20) { RailsMind::Visitor.mint }
    ids.each { |id| assert_match RailsMind::Visitor::ID, id }
    assert_equal 20, ids.uniq.size
  end

  def test_daily_hash_is_stable_per_local_day_and_never_contains_the_ip
    day = Date.new(2026, 11, 6)
    RailsMind::Visitor.stub(:key, KEY) do
      first = RailsMind::Visitor.daily_hash("203.0.113.9", "Mozilla/5.0", day)
      assert_match(/\A\h{32}\z/, first)
      assert_equal first.downcase, first
      assert_equal OpenSSL::HMAC.hexdigest("SHA256", KEY, "2026-11-06\n203.0.113.9\nMozilla/5.0")[0, 32], first
      assert_equal first, RailsMind::Visitor.daily_hash("203.0.113.9", "Mozilla/5.0", day)
      refute_equal first, RailsMind::Visitor.daily_hash("203.0.113.9", "Mozilla/5.0", day + 1)
      refute_equal first, RailsMind::Visitor.daily_hash("203.0.113.10", "Mozilla/5.0", day)
      refute_equal first, RailsMind::Visitor.daily_hash("203.0.113.9", "Mozilla/6.0", day)
      refute_includes first, "203"
      assert_nil RailsMind::Visitor.daily_hash(nil, "Mozilla/5.0", day)
      assert_nil RailsMind::Visitor.daily_hash("", "Mozilla/5.0", day)
    end
    RailsMind::Visitor.stub(:key, nil) do
      assert_nil RailsMind::Visitor.daily_hash("203.0.113.9", "Mozilla/5.0", day)
    end
  end

  def test_the_hash_key_comes_from_secret_key_base_never_the_ingest_key
    generator = ActiveSupport::CachingKeyGenerator.new(ActiveSupport::KeyGenerator.new("app-secret-key-base", iterations: 1000))
    application = Struct.new(:key_generator).new(generator)
    Rails.stub(:application, application) do
      assert_equal generator.generate_key("rails_mind visitor v1", 32), RailsMind::Visitor.derive_key
    end
    refute_equal ActiveSupport::KeyGenerator.new(@config.token, iterations: 1000).generate_key("rails_mind visitor v1", 32),
      generator.generate_key("rails_mind visitor v1", 32)
    Rails.stub(:application, nil) { assert_nil RailsMind::Visitor.derive_key }
    broken = Object.new
    def broken.key_generator = raise(ArgumentError, "Missing secret_key_base")
    Rails.stub(:application, broken) { assert_nil RailsMind::Visitor.derive_key }
  end

  def test_the_hash_date_is_the_local_day_of_the_apps_time_zone
    zone = ActiveSupport::TimeZone["Pacific/Auckland"]
    Time.stub(:zone_default, zone) { assert_equal zone.now.to_date, RailsMind::Visitor.today }
    Time.stub(:zone_default, nil) { assert_equal Time.now.utc.to_date, RailsMind::Visitor.today }
  end

  def test_a_get_without_a_cookie_gets_a_fresh_id_that_track_events_carry
    seen = nil
    app = ->(env) do
      seen = RailsMind::Context.snapshot[:visitor_id]
      RailsMind.track("Viewed pricing")
      [ 200, {}, [ "ok" ] ]
    end
    _status, headers, _body = RailsMind::Integrations::RequestContext.new(app).call(request_env)
    assert_match RailsMind::Visitor::ID, seen
    assert_equal seen, @memory.events.last["visitor_id"]
    assert_nil headers["set-cookie"], "only a counted page view sets the cookie"
    assert_empty RailsMind::Context.snapshot
  end

  def test_a_valid_cookie_is_used_and_an_invalid_one_is_replaced
    assert_equal VISITOR, visitor_inside(request_env("HTTP_COOKIE" => "_rails_mind_visitor=#{VISITOR}"))
    replaced = visitor_inside(request_env("HTTP_COOKIE" => "_rails_mind_visitor=not-a-uuid"))
    assert_match RailsMind::Visitor::ID, replaced
    refute_equal "not-a-uuid", replaced
  end

  def test_requests_that_can_never_set_the_cookie_mint_nothing
    assert_nil visitor_inside(request_env("REQUEST_METHOD" => "POST"))
    assert_nil visitor_inside(request_env("REQUEST_METHOD" => "HEAD"))
    assert_equal VISITOR, visitor_inside(request_env("REQUEST_METHOD" => "POST", "HTTP_COOKIE" => "_rails_mind_visitor=#{VISITOR}"))
  end

  def test_requests_that_cannot_become_a_page_view_mint_nothing
    [
      { "HTTP_ACCEPT" => "application/json" },
      { "HTTP_ACCEPT" => "*/*" },
      { "HTTP_ACCEPT" => nil },
      { "HTTP_TURBO_FRAME" => "comments" },
      { "HTTP_X_REQUESTED_WITH" => "XMLHttpRequest" },
      { "HTTP_SEC_PURPOSE" => "prefetch" },
      { "HTTP_X_SEC_PURPOSE" => "prefetch" }
    ].each do |extra|
      assert_nil visitor_inside(request_env(extra).compact), "minted for #{extra}"
    end
    turbo_drive = "text/vnd.turbo-stream.html, text/html, application/xhtml+xml"
    assert_match RailsMind::Visitor::ID, visitor_inside(request_env("HTTP_ACCEPT" => turbo_drive))
    assert_equal VISITOR, visitor_inside(request_env("HTTP_ACCEPT" => "application/json", "HTTP_COOKIE" => "_rails_mind_visitor=#{VISITOR}"))
  end

  def test_an_id_the_app_already_set_wins
    inside = nil
    RailsMind.with_context(visitor_id: "app-visitor") do
      inside = visitor_inside(request_env("HTTP_COOKIE" => "_rails_mind_visitor=#{VISITOR}"))
    end
    assert_equal "app-visitor", inside
  end

  def test_no_visitor_id_when_page_views_or_the_cookie_are_off
    [ :page_views, :visitor_cookie, :analytics ].each do |switch|
      @config.public_send("#{switch}=", false)
      assert_nil visitor_inside(request_env("HTTP_COOKIE" => "_rails_mind_visitor=#{VISITOR}")), switch
      @config.public_send("#{switch}=", true)
    end
    off = @config.dup
    off.token = nil
    RailsMind.client = RailsMind::Client.new(off)
    assert_nil RailsMind.client.collector
    assert_nil visitor_inside(request_env)
  end

  def test_a_marked_response_gets_the_cookie_with_the_contract_attributes
    app = ->(env) do
      env[RailsMind::Visitor::WRITE] = { secure: true }
      [ 200, Rack::Headers.new.merge("content-type" => "text/html", "set-cookie" => "theme=dark"), [ "ok" ] ]
    end
    _status, headers, _body = RailsMind::Integrations::RequestContext.new(app).call(request_env("HTTP_COOKIE" => "_rails_mind_visitor=#{VISITOR}"))
    cookies = Array(headers["set-cookie"])
    assert_equal "theme=dark", cookies.first
    cookie = cookies.last
    assert cookie.start_with?("_rails_mind_visitor=#{VISITOR}; path=/; expires="), cookie
    expires = Time.httpdate(cookie[/expires=([^;]+)/, 1])
    assert_in_delta Time.now + (2 * 365 * 24 * 60 * 60), expires, 5
    assert_includes cookie, "; secure"
    assert_includes cookie, "; httponly"
    assert_includes cookie, "; samesite=lax"

    app = ->(env) { env[RailsMind::Visitor::WRITE] = { secure: false }; [ 200, {}, [ "ok" ] ] }
    _status, headers, _body = RailsMind::Integrations::RequestContext.new(app).call(request_env)
    assert_match(/\A_rails_mind_visitor=\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}; path=\/; expires=[^;]+; httponly; samesite=lax\z/, headers["set-cookie"])
  end

  def test_a_publicly_cacheable_response_never_gets_the_cookie
    [ "public, max-age=3600", "max-age=60,public", "PUBLIC" ].each do |cache_control|
      app = ->(env) { env[RailsMind::Visitor::WRITE] = { secure: false }; [ 200, { "cache-control" => cache_control }, [ "ok" ] ] }
      _status, headers, _body = RailsMind::Integrations::RequestContext.new(app).call(request_env)
      assert_nil headers["set-cookie"], cache_control
    end
    app = ->(env) { env[RailsMind::Visitor::WRITE] = { secure: false }; [ 200, { "cache-control" => "private, no-public-caching" }, [ "ok" ] ] }
    _status, headers, _body = RailsMind::Integrations::RequestContext.new(app).call(request_env)
    refute_nil headers["set-cookie"]
  end

  def test_cookie_trouble_never_reaches_the_app
    app = ->(env) { env[RailsMind::Visitor::WRITE] = { secure: false }; [ 200, {}.freeze, [ "ok" ] ] }
    status, headers, _body = RailsMind::Integrations::RequestContext.new(app).call(request_env)
    assert_equal 200, status
    assert_empty headers
    odd = Object.new
    assert_same odd, RailsMind::Integrations::RequestContext.new(->(env) { env[RailsMind::Visitor::WRITE] = { secure: false }; odd }).call(request_env)
    RailsMind::Visitor.stub(:from_cookie, ->(_header) { raise "broken" }) do
      status, _headers, _body = RailsMind::Integrations::RequestContext.new(->(_env) { [ 204, {}, [] ] }).call(request_env)
      assert_equal 204, status
    end
  end

  private

  def request_env(extra = {})
    { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/pricing", "HTTP_ACCEPT" => BROWSER_ACCEPT,
      "action_dispatch.request_id" => "request-1" }.merge(extra)
  end

  def visitor_inside(env)
    seen = :not_called
    app = ->(_env) { seen = RailsMind::Context.snapshot[:visitor_id]; [ 200, {}, [ "ok" ] ] }
    RailsMind::Integrations::RequestContext.new(app).call(env)
    seen
  end
end
