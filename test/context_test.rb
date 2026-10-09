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
