require_relative "test_helper"

class ContextTest < SDKTest
  def test_native_trace_is_bounded_and_restores_after_failure
    trace = nil
    assert_raises(RuntimeError) do
      RailsMind::Context.with_trace do
        trace = RailsMind::Context.snapshot[:trace_id]
        assert_match(/\A[0-9a-f]{32}\z/, trace)
        RailsMind::Context.with_trace { assert_equal trace, RailsMind::Context.snapshot[:trace_id] }
        Fiber.new { assert_empty RailsMind::Context.snapshot }.resume
        raise "application failure"
      end
    end
    assert_empty RailsMind::Context.snapshot
    RailsMind::Context.with_trace { refute_equal trace, RailsMind::Context.snapshot[:trace_id] }
  end

  def test_identify_keeps_the_visitor_unless_it_is_named
    RailsMind::Context.with(visitor_id: "visitor-1") do
      RailsMind.identify(user_id: 21, account_id: 7)
      assert_equal({ visitor_id: "visitor-1", user_id: "21", account_id: "7" }, RailsMind::Context.snapshot)
      RailsMind.identify(user_id: 22)
      assert_equal({ visitor_id: "visitor-1", user_id: "22", account_id: nil }, RailsMind::Context.snapshot)
      RailsMind.identify(user_id: 22, visitor_id: "visitor-2")
      assert_equal "visitor-2", RailsMind::Context.snapshot[:visitor_id]
      RailsMind.identify(user_id: 22, visitor_id: nil)
      assert_nil RailsMind::Context.snapshot[:visitor_id]
    end
    assert_empty RailsMind::Context.snapshot
  end

  def test_explicit_trace_identity_is_preserved_without_valid_otel
    RailsMind::Context.with(trace_id: "existing-trace", request_id: "request-1") do
      RailsMind::Context.with_trace do
        assert_equal "existing-trace", RailsMind::Context.snapshot[:trace_id]
        assert_equal "request-1", RailsMind::Context.effective_snapshot[:request_id]
      end
      assert_equal "existing-trace", RailsMind::Context.snapshot[:trace_id]
    end
    assert_empty RailsMind::Context.snapshot
  end
end
