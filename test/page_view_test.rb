require_relative "test_helper"
require "minitest/mock"
require "active_support"
require "action_dispatch"
require "action_controller"
require "action_view"
require "action_view/testing/resolvers"
require "rack/mock"
require "rails_mind/integrations/rails"

class PageViewTest < SDKTest
  # Real controllers, for responses Rails finishes after the action returns.
  class StreamingController < ActionController::Base
    self.view_paths = ActionView::FixtureResolver.new("pages/show.html.erb" => "<p>post</p>",
      "layouts/page.html.erb" => "<html><body><%= yield %></body></html>")
    layout "page"

    def show = render(template: "pages/show", stream: true)
    def empty = head(:no_content)
  end

  class LiveController < ActionController::Base
    include ActionController::Live
    GATE = Queue.new

    # Sends its headers, then waits for the test before the action ends.
    def show
      response.headers["Content-Type"] = "text/html"
      response.stream.write "<p>first</p>"
      GATE.pop(timeout: 5)
      response.stream.write "<p>later</p>"
    ensure
      response.stream.close
    end

    def rendered = render(html: "<p>live</p>".html_safe)
  end

  class MountedPostsController < ActionController::Base
    def show = render(html: "<p>post</p>".html_safe)
  end

  CHROME = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36".freeze
  VISITOR = "0b6f2f8e-1c2d-4e5f-9a0b-1c2d3e4f5a6b".freeze
  KEY = ("k" * 32).freeze
  HTML = { "content-type" => "text/html; charset=utf-8" }.freeze

  def setup
    super
    RailsMind::Integrations::RailsNotifications.install!
  end

  def teardown
    RailsMind::Integrations::RailsNotifications.uninstall!
    super
  end

  def test_a_page_view_carries_the_wire_contract
    status, headers, _body = visit("https://shop.example/posts/7?utm_source=news&utm_medium=email&utm_campaign=launch&utm_term=rails&utm_content=hero&ref=friend",
      env: { "HTTP_REFERER" => "https://News.example/item?id=1#comments", "HTTP_CF_IPCOUNTRY" => "DE" })
    assert_equal 200, status
    view = page_view
    assert_equal "PostsController#show", view["name"]
    assert_equal({
      "route" => "/posts/:id", "path" => "/posts/7?utm_source=news&utm_medium=email&utm_campaign=launch&utm_term=rails&utm_content=hero&ref=friend",
      "host" => "shop.example", "referrer" => "https://news.example/item", "utm_source" => "news", "utm_medium" => "email",
      "utm_campaign" => "launch", "utm_term" => "rails", "utm_content" => "hero", "ref" => "friend",
      "user_agent" => CHROME, "country" => "DE", "visitor_id_kind" => "cookie"
    }, view["properties"])
    assert_equal RailsMind::PageView::PROPERTIES.sort, view["properties"].keys.sort
    assert_match RailsMind::Visitor::ID, view["visitor_id"]
    assert_includes Array(headers["set-cookie"]).join, "_rails_mind_visitor=#{view['visitor_id']}; path=/"
    request = @memory.events.find { |event| event["kind"] == "request" }
    assert_equal "request-1", view["request_id"]
    assert_equal request["request_id"], view["request_id"]
    assert_equal request["trace_id"], view["trace_id"]
    assert_equal "abc123", view["release"]
    refute_includes JSON.generate(@memory.events), "203.0.113.9", "the IP never leaves the app"
  end

  def test_every_contract_key_survives_the_redactor
    redactor = RailsMind::Redactor.new
    RailsMind::PageView::PROPERTIES.each do |key|
      assert_equal "value", redactor.call({ "properties" => { key => "value" } }).dig("properties", key), key
    end
  end

  def test_only_html_gets_from_people_count
    {
      "POST" => -> { visit(method: "POST") },
      "HEAD" => -> { visit(method: "HEAD") },
      "redirect" => -> { visit(status: 302) },
      "not found" => -> { visit(status: 404) },
      "JSON" => -> { visit(response_headers: { "content-type" => "application/json" }) },
      "Turbo Stream" => -> { visit(response_headers: { "content-type" => "text/vnd.turbo-stream.html" }) },
      "Turbo Frame" => -> { visit(env: { "HTTP_TURBO_FRAME" => "comments" }) },
      "Sec-Purpose prefetch" => -> { visit(env: { "HTTP_SEC_PURPOSE" => "prefetch;prerender" }) },
      "X-Sec-Purpose prefetch" => -> { visit(env: { "HTTP_X_SEC_PURPOSE" => "prefetch" }) },
      "XHR" => -> { visit(env: { "HTTP_X_REQUESTED_WITH" => "XMLHttpRequest" }) },
      "health check" => -> { visit(controller: "Rails::HealthController", action: "show") },
      "Rails controller" => -> { visit(controller: "Rails::WelcomeController", action: "index") },
      "Active Storage" => -> { visit(controller: "ActiveStorage::Blobs::RedirectController", action: "show") },
      "Hotwire Native recede stub" => -> { visit(controller: "Turbo::Native::NavigationController", action: "recede") },
      "Accept */* (a poller or script)" => -> { visit(env: { "HTTP_ACCEPT" => "*/*" }) },
      "Accept JSON" => -> { visit(env: { "HTTP_ACCEPT" => "application/json" }) },
      "no Accept header" => -> { visit(env: { "HTTP_ACCEPT" => nil }) },
      "Googlebot" => -> { visit(env: { "HTTP_USER_AGENT" => "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)" }) },
      "GPTBot" => -> { visit(env: { "HTTP_USER_AGENT" => "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2)" }) },
      "curl" => -> { visit(env: { "HTTP_USER_AGENT" => "curl/8.7.1" }) },
      "CloudFront" => -> { visit(env: { "HTTP_USER_AGENT" => "Amazon CloudFront" }) },
      "blank user agent" => -> { visit(env: { "HTTP_USER_AGENT" => " " }) },
      "no user agent" => -> { visit(env: { "HTTP_USER_AGENT" => nil }) }
    }.each do |rule, request|
      @memory.events.clear
      _status, headers, _body = request.call
      assert_nil page_view, rule
      assert_nil headers["set-cookie"], rule
    end
    [ { "content-type" => "text/html" }, HTML ].each do |headers|
      @memory.events.clear
      visit(response_headers: headers, env: { "HTTP_SEC_PURPOSE" => "", "HTTP_TURBO_FRAME" => "" })
      refute_nil page_view
    end
    @memory.events.clear
    visit(status: 203)
    refute_nil page_view, "any 2xx counts"
  end

  def test_a_streamed_template_counts_like_any_html_page
    _status, headers, body = RailsMind::Integrations::RequestContext.new(StreamingController.action(:show)).call(request_env)
    assert_equal "<html><body><p>post</p></body></html>", read(body)
    assert_equal "text/html; charset=utf-8", headers["content-type"]
    view = page_view
    refute_nil view, "Rails types a streamed template only when the response commits"
    assert_equal "PageViewTest::StreamingController#show", view["name"]
    assert_includes Array(headers["set-cookie"]).join, "_rails_mind_visitor=#{view['visitor_id']}"

    @memory.events.clear
    status, headers, body = RailsMind::Integrations::RequestContext.new(StreamingController.action(:empty)).call(request_env)
    read(body)
    assert_equal 204, status
    assert_nil page_view, "no content is no page"
    assert_nil headers["set-cookie"]
  end

  # Live sends the headers at the first write or render, before the action
  # ends and Rails reports it, so no Live response can take the cookie.
  def test_a_live_response_never_counts_a_cookie_it_could_not_set
    RailsMind::Visitor.stub(:key, KEY) do
      [ :show, :rendered ].product([ {}, { "HTTP_COOKIE" => "_rails_mind_visitor=#{VISITOR}" } ]).each do |action, env|
        @memory.events.clear
        status, headers, body = RailsMind::Integrations::RequestContext.new(LiveController.action(action)).call(request_env("https://shop.example/live", env))
        assert_equal 200, status
        LiveController::GATE << true if action == :show
        read(body)
        view = eventually { page_view }
        label = [ action, env ].inspect
        assert_nil headers["set-cookie"], label
        if env.empty?
          assert_equal [ "daily_hash", daily_hash ], [ view.dig("properties", "visitor_id_kind"), view["visitor_id"] ], label
        else
          assert_equal [ "cookie", VISITOR ], [ view.dig("properties", "visitor_id_kind"), view["visitor_id"] ], label
        end
      end
    end
  end

  def test_the_apps_hook_can_ignore_page_views_and_never_breaks_the_request
    @config.ignore_page_view = ->(request) { request.path.start_with?("/admin") }
    visit("https://shop.example/admin/posts")
    assert_nil page_view
    visit("https://shop.example/posts")
    refute_nil page_view

    @memory.events.clear
    @config.ignore_page_view = ->(_request) { raise "broken hook" }
    status, _headers, _body = visit
    assert_equal 200, status
    assert_nil page_view, "a hook that raises has not said the page view counts"
    refute_nil @memory.events.find { |event| event["kind"] == "request" }
  end

  def test_nothing_without_a_response_or_with_page_views_off
    app = ->(env) do
      request = ActionDispatch::Request.new(env)
      ActiveSupport::Notifications.instrument("process_action.action_controller", controller: "PostsController", action: "show",
        request: request, method: "GET", status: 500)
      [ 500, {}, [] ]
    end
    RailsMind::Integrations::RequestContext.new(app).call(request_env("https://shop.example/posts"))
    assert_nil page_view, "an action that raised has no response"

    [ :page_views, :analytics ].each do |switch|
      @memory.events.clear
      @config.public_send("#{switch}=", false)
      _status, headers, _body = visit
      assert_nil page_view, switch
      assert_nil headers["set-cookie"], switch
      @config.public_send("#{switch}=", true)
    end
  end

  def test_the_cookie_is_refreshed_and_a_bad_one_replaced
    _status, headers, _body = visit(env: { "HTTP_COOKIE" => "_rails_mind_visitor=#{VISITOR}" })
    assert_equal VISITOR, page_view["visitor_id"]
    assert_equal "cookie", page_view.dig("properties", "visitor_id_kind")
    assert_match(/\A_rails_mind_visitor=#{VISITOR}; path=\/; expires=[^;]+; secure; httponly; samesite=lax\z/, headers["set-cookie"])

    @memory.events.clear
    _status, headers, _body = visit("http://shop.example/posts/7", env: { "HTTP_COOKIE" => "_rails_mind_visitor=<script>" })
    fresh = page_view["visitor_id"]
    assert_match RailsMind::Visitor::ID, fresh
    assert_match(/\A_rails_mind_visitor=#{fresh}; path=\/; expires=[^;]+; httponly; samesite=lax\z/, headers["set-cookie"], "Secure only over HTTPS")
    refute_includes JSON.generate(@memory.events), "<script>"
  end

  def test_publicly_cached_pages_never_set_the_cookie
    RailsMind::Visitor.stub(:key, KEY) do
      [ ->(response) { response.cache_control[:public] = true }, ->(response) { response.set_header("Cache-Control", "public, max-age=3600") } ].each do |cache|
        @memory.events.clear
        _status, headers, _body = visit(prepare: cache, env: { "HTTP_COOKIE" => "_rails_mind_visitor=#{VISITOR}" })
        assert_equal VISITOR, page_view["visitor_id"], "a valid cookie still names the visitor"
        assert_equal "cookie", page_view.dig("properties", "visitor_id_kind")
        assert_nil headers["set-cookie"]

        @memory.events.clear
        _status, headers, _body = visit(prepare: cache)
        assert_equal "daily_hash", page_view.dig("properties", "visitor_id_kind")
        assert_equal daily_hash, page_view["visitor_id"]
        assert_nil headers["set-cookie"]
      end
    end
  end

  def test_without_the_cookie_page_views_and_events_share_the_daily_hash
    @config.visitor_cookie = false
    RailsMind::Visitor.stub(:key, KEY) do
      _status, headers, _body = visit(env: { "HTTP_COOKIE" => "_rails_mind_visitor=#{VISITOR}" }) { RailsMind.track("Viewed post") }
      assert_nil headers["set-cookie"]
      assert_equal "daily_hash", page_view.dig("properties", "visitor_id_kind")
      assert_equal daily_hash, page_view["visitor_id"]
      assert_match(/\A\h{32}\z/, page_view["visitor_id"])
      assert_equal daily_hash, @memory.events.find { |event| event["name"] == "Viewed post" }["visitor_id"]
      refute_includes JSON.generate(@memory.events), VISITOR
      refute_includes JSON.generate(@memory.events), "203.0.113.9"
    end
    @memory.events.clear
    RailsMind::Visitor.stub(:key, nil) { visit }
    assert_nil page_view["visitor_id"], "no key, no visitor ID"
    assert_equal "daily_hash", page_view.dig("properties", "visitor_id_kind")
  end

  def test_page_views_carry_the_signed_in_user_unless_linking_is_off
    visit { RailsMind.identify(user_id: 21, account_id: 7) }
    assert_equal [ "21", "7" ], page_view.values_at("user_id", "account_id")
    visitor = page_view["visitor_id"]
    assert_match RailsMind::Visitor::ID, visitor, "identify keeps the visitor"

    @memory.events.clear
    @config.link_page_views_to_users = false
    visit do
      RailsMind.identify(user_id: 21, account_id: 7)
      RailsMind.track("Viewed post")
    end
    refute page_view.key?("user_id")
    refute page_view.key?("account_id")
    assert_match RailsMind::Visitor::ID, page_view["visitor_id"]
    assert_equal [ "21", "7" ], @memory.events.find { |event| event["name"] == "Viewed post" }.values_at("user_id", "account_id")
  end

  def test_untrusted_text_is_bounded
    long = "a" * 5_000
    visit("https://#{'h' * 300}.example/#{long}?utm_source=#{long}&utm_medium[]=x&ref=%20%20",
      env: { "HTTP_USER_AGENT" => "Mozilla/5.0 #{long}", "HTTP_REFERER" => "https://news.example/#{long}",
        "action_dispatch.route_uri_pattern" => "/#{long}(.:format)" })
    properties = page_view["properties"]
    assert_equal 500, properties["route"].length
    assert_equal 1_000, properties["path"].length
    assert_equal 255, properties["host"].length
    assert_equal 1_000, properties["referrer"].length
    assert_equal 200, properties["utm_source"].length
    assert_equal 500, properties["user_agent"].length
    refute properties.key?("utm_medium"), "only String values"
    refute properties.key?("ref"), "blank values are absent"
    assert_operator JSON.generate(page_view).bytesize, :<, RailsMind::Configuration.new.max_event_bytes
  end

  def test_referrers_routes_and_countries_are_kept_only_when_well_formed
    [ "ftp://files.example/x", "javascript:alert(1)", "not a url", "//news.example/item", "https://", "" ].each do |referrer|
      @memory.events.clear
      visit(env: { "HTTP_REFERER" => referrer })
      refute page_view["properties"].key?("referrer"), referrer
    end
    @memory.events.clear
    visit(env: { "HTTP_REFERER" => "http://user:secret@Search.Example:8080/results?q=private#top" })
    assert_equal "http://search.example/results", page_view.dig("properties", "referrer")

    @memory.events.clear
    visit(env: { "action_dispatch.route_uri_pattern" => nil })
    refute page_view["properties"].key?("route")

    { { "HTTP_CF_IPCOUNTRY" => "XX", "HTTP_CLOUDFRONT_VIEWER_COUNTRY" => "FR" } => "FR",
      { "HTTP_CF_IPCOUNTRY" => "T1" } => nil, { "HTTP_CF_IPCOUNTRY" => "de" } => "DE",
      { "HTTP_CLOUDFRONT_VIEWER_COUNTRY" => "USA" } => nil, {} => nil }.each do |headers, country|
      @memory.events.clear
      visit(env: headers)
      actual = page_view.dig("properties", "country")
      country ? assert_equal(country, actual, headers.inspect) : assert_nil(actual, headers.inspect)
    end
  end

  def test_a_mounted_engines_route_starts_with_its_mount_path
    engine = ActionDispatch::Routing::RouteSet.new
    engine.draw do
      root to: "page_view_test/mounted_posts#show"
      get "/posts/:id", to: "page_view_test/mounted_posts#show"
    end
    app = ActionDispatch::Routing::RouteSet.new
    app.draw do
      mount engine => "/blog"
      root to: "page_view_test/mounted_posts#show"
      get "/posts/:id", to: "page_view_test/mounted_posts#show"
    end
    { "/blog/posts/3" => "/blog/posts/:id", "/posts/3" => "/posts/:id", "/blog" => "/blog", "/" => "/" }.each do |path, route|
      @memory.events.clear
      _status, _headers, body = RailsMind::Integrations::RequestContext.new(app).call(request_env("https://shop.example#{path}", "action_dispatch.route_uri_pattern" => nil))
      read(body)
      assert_equal route, page_view.dig("properties", "route"), path
      assert_equal path, page_view.dig("properties", "path") if path.include?("posts")
    end
  end

  def test_the_path_is_filtered_by_the_apps_filter_parameters
    visit("https://shop.example/reset?password=hunter2&utm_source=mail", env: { "action_dispatch.parameter_filter" => [ :password ] })
    assert_equal "/reset?password=[FILTERED]&utm_source=mail", page_view.dig("properties", "path")
    refute_includes JSON.generate(@memory.events), "hunter2"
  end

  def test_route_segments_the_apps_filter_parameters_mask_are_masked_in_the_path
    token = "eyJfcmFpbHMiOnsiZGF0YSI6WzFdfX0=--0123456789abcdef0123"
    visit("https://shop.example/passwords/#{token}/edit?token=#{token}&page=2", env: {
      "action_dispatch.parameter_filter" => [ :token ],
      "action_dispatch.route_uri_pattern" => "/passwords/:token/edit(.:format)",
      "action_dispatch.request.path_parameters" => { controller: "passwords", action: "edit", token: token }
    })
    properties = page_view["properties"]
    assert_equal "/passwords/[FILTERED]/edit?token=[FILTERED]&page=2", properties["path"]
    assert_equal "/passwords/:token/edit", properties["route"]
    refute_includes JSON.generate(page_view), "0123456789abcdef0123"

    @memory.events.clear
    visit("https://shop.example/s/ab12/posts/7", env: {
      "action_dispatch.parameter_filter" => [ :token ],
      "action_dispatch.request.path_parameters" => { controller: "shares", action: "show", share_token: "ab12", id: "7" }
    })
    assert_equal "/s/[FILTERED]/posts/7", page_view.dig("properties", "path"), "a short secret goes as a whole segment; other parameters stay"

    @memory.events.clear
    visit("https://shop.example/files/a%2Fb%20c", env: {
      "action_dispatch.parameter_filter" => [ :secret ],
      "action_dispatch.request.path_parameters" => { controller: "files", action: "show", secret: "a/b c" }
    })
    assert_equal "/files/[FILTERED]", page_view.dig("properties", "path"), "an escaped secret is masked too"
  end

  def test_masking_follows_rails_filters_and_never_sends_an_unmasked_path
    token = "abcdefgh1234"
    secret_visit = ->(url, filters, params, extra = {}) do
      @memory.events.clear
      visit(url, env: { "action_dispatch.parameter_filter" => filters,
        "action_dispatch.request.path_parameters" => { controller: "passwords", action: "edit" }.merge(params) }.merge(extra))
      page_view["properties"]
    end
    string_key = [ ->(key, value) { value.replace("[FILTERED]") if key == "token" } ]
    assert_equal "/passwords/[FILTERED]/edit", secret_visit.call("https://shop.example/passwords/#{token}/edit", string_key, { token: token })["path"],
      "a lambda filter gets string keys, as Rails gives them"
    raising = [ ->(key, _value) { raise "no" if key.include?("token") } ]
    assert_equal "[FILTERED]", secret_visit.call("https://shop.example/passwords/#{token}/edit", raising, { token: token })["path"],
      "a filter that raises sends no path, never the unmasked one"
    assert_equal "/s/[FILTERED]", secret_visit.call("https://shop.example/s/ab12.html", [ :token ], { token: "ab12" })["path"], "a short secret with a format"
    assert_equal "/p/[FILTERED]", secret_visit.call("https://shop.example/p/hello-123456", [ :otp ], { slug: "hello", otp: "123456" })["path"], "a secret sharing a segment"
    assert_equal "/files/[FILTERED]", secret_visit.call("https://shop.example/files/ab/cd", [ :secret ], { secret: "ab/cd" })["path"], "a glob secret"
    assert_equal "/passwords/[FILTERED]/edit?back=/passwords/[FILTERED]/edit",
      secret_visit.call("https://shop.example/passwords/#{token}/edit?back=/passwords/#{token}/edit", [ :token ], { token: token })["path"],
      "a long secret repeated in the query"

    assert_equal "/files/[FILTERED]/[FILTERED]", secret_visit.call("https://shop.example/files/q%5B1%5D/x9", [ :secret ], { secret: "q[1]/x9" })["path"],
      "a glob secret the URL helper escaped"
    refute_includes secret_visit.call("https://shop.example/share/abc/abc/hidden", [ :token, :secret ], { share_token: "abc", secret_path: "abc/hidden" })["path"],
      "hidden", "a glob secret another secret overlaps"
    assert_equal "/s/[FILTERED]?back=[FILTERED]&page=2", secret_visit.call("https://shop.example/s/ab12?back=%2Fs%2Fab12&page=2", [ :token ], { token: "ab12" })["path"],
      "a short secret in a back link"
    tagged = secret_visit.call("https://shop.example/s/#{token}?utm_content=#{token}&utm_source=mail", [ :token ], { token: token })
    refute tagged.key?("utm_content"), "a campaign tag holding a masked route value is not sent"
    assert_equal "mail", tagged["utm_source"]

    properties = secret_visit.call("https://shop.example/t/sekr3t-account-token/blog/posts/1", [ :token ], { account_token: "sekr3t-account-token", id: "1" },
      { "SCRIPT_NAME" => "/t/sekr3t-account-token/blog", "PATH_INFO" => "/posts/1", "action_dispatch.route_uri_pattern" => "/posts/:id(.:format)" })
    assert_equal "/t/[FILTERED]/blog/posts/:id", properties["route"], "a mounted engine's masked mount segment"
    refute_includes JSON.generate(page_view), "sekr3t"

    @memory.events.clear
    env = request_env("https://shop.example/s/x", "action_dispatch.parameter_filter" => [ :token ],
      "action_dispatch.request.path_parameters" => { controller: "shares", action: "show", token: "café-secret-token" })
    env["PATH_INFO"] = "/s/café-secret-token".b
    app = ->(inner) do
      request = ActionDispatch::Request.new(inner)
      payload = { controller: "SharesController", action: "show", request: request, method: "GET", path: request.filtered_path }
      ActiveSupport::Notifications.instrument("process_action.action_controller", payload) do
        payload[:status] = 200
        payload[:response] = ActionDispatch::Response.new(200, HTML.dup)
      end
      [ 200, HTML.dup, [ "ok" ] ]
    end
    RailsMind::Integrations::RequestContext.new(app).call(env)
    refute_includes page_view.dig("properties", "path").b, "secret-token".b, "a path in raw bytes is still masked"
  end

  def test_a_link_inside_the_app_sends_only_its_origin_as_referrer
    { "https://shop.example/passwords/secret-token/edit?x=1" => "https://shop.example",
      "https://www.shop.example/posts/3" => "https://www.shop.example",
      "https://news.example/item/42?id=9" => "https://news.example/item/42" }.each do |referrer, sent|
      @memory.events.clear
      visit("https://shop.example/posts/7", env: { "HTTP_REFERER" => referrer })
      assert_equal sent, page_view.dig("properties", "referrer"), referrer
    end
  end

  def test_a_tag_the_apps_filter_parameters_mask_is_not_sent
    visit("https://shop.example/posts/7?utm_source=news&ref=secretref&utm_term=x", env: { "action_dispatch.parameter_filter" => [ :ref, ->(key, value) { value.replace("masked") if key == "utm_term" } ] })
    properties = page_view["properties"]
    assert_equal "/posts/7?utm_source=news&ref=[FILTERED]&utm_term=masked", properties["path"]
    assert_equal "news", properties["utm_source"]
    refute properties.key?("ref"), "masked in the path, so not sent beside it"
    refute properties.key?("utm_term"), "a filter that rewrites the value masks it too"
    refute_includes JSON.generate(@memory.events), "secretref"
  end

  private

  def request_env(url = "https://shop.example/posts/7", env = {})
    Rack::MockRequest.env_for(url, {
      "HTTP_USER_AGENT" => CHROME, "HTTP_ACCEPT" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      "REMOTE_ADDR" => "203.0.113.9", "action_dispatch.request_id" => "request-1",
      "action_dispatch.route_uri_pattern" => "/posts/:id(.:format)"
    }.merge(env)).tap { |result| env.each { |key, value| result.delete(key) if value.nil? } }
  end

  # A controller action as Rails instruments it, inside the SDK's request boundary.
  def visit(url = "https://shop.example/posts/7", method: "GET", status: 200, response_headers: HTML, env: {},
    controller: "PostsController", action: "show", prepare: nil, &work)
    rack_env = request_env(url, env)
    rack_env["REQUEST_METHOD"] = method
    app = ->(inner) do
      request = ActionDispatch::Request.new(inner)
      response = ActionDispatch::Response.new(status, response_headers.dup)
      payload = { controller: controller, action: action, request: request,
        method: request.request_method, path: request.filtered_path }
      ActiveSupport::Notifications.instrument("start_processing.action_controller", payload.dup)
      ActiveSupport::Notifications.instrument("process_action.action_controller", payload) do |event|
        work&.call
        prepare&.call(response)
        event[:response] = response
        event[:status] = response.status
      end
      response.to_a
    end
    RailsMind::Integrations::RequestContext.new(app).call(rack_env)
  end

  def page_view = @memory.events.find { |event| event["kind"] == "pageview" }

  # ActionController::Live finishes the action on its own thread.
  def eventually
    deadline = Time.now + 5
    until (value = yield) || Time.now > deadline
      sleep 0.01
    end
    value
  end

  # The whole body, closed as a server closes it.
  def read(body)
    chunks = +""
    body.each { |chunk| chunks << chunk }
    chunks
  ensure
    body.close if body.respond_to?(:close)
  end

  def daily_hash = OpenSSL::HMAC.hexdigest("SHA256", KEY, "#{RailsMind::Visitor.today.iso8601}\n203.0.113.9\n#{CHROME}")[0, 32]
end
