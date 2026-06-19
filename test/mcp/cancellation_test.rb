# frozen_string_literal: true

require "test_helper"

module MCP
  class CancellationTest < ActiveSupport::TestCase
    test "starts not cancelled" do
      cancellation = Cancellation.new

      refute_predicate cancellation, :cancelled?
      assert_nil cancellation.reason
    end

    test "#cancel flips state and stores reason" do
      cancellation = Cancellation.new

      assert cancellation.cancel(reason: "user requested")
      assert_predicate cancellation, :cancelled?
      assert_equal "user requested", cancellation.reason
    end

    test "#cancel is idempotent" do
      cancellation = Cancellation.new

      assert cancellation.cancel(reason: "first")
      refute cancellation.cancel(reason: "second")
      assert_equal "first", cancellation.reason
    end

    test "#on_cancel fires once on cancellation" do
      cancellation = Cancellation.new
      fired = []

      cancellation.on_cancel { |reason| fired << reason }
      cancellation.cancel(reason: "stop")
      cancellation.cancel(reason: "again")

      assert_equal ["stop"], fired
    end

    test "#on_cancel fires immediately when already cancelled" do
      cancellation = Cancellation.new
      cancellation.cancel(reason: "done")
      fired = []

      cancellation.on_cancel { |reason| fired << reason }

      assert_equal ["done"], fired
    end

    test "#raise_if_cancelled! raises CancelledError when cancelled" do
      cancellation = Cancellation.new(request_id: "req-1")
      cancellation.cancel(reason: "abort")

      error = assert_raises(CancelledError) { cancellation.raise_if_cancelled! }
      assert_equal "req-1", error.request_id
      assert_equal "abort", error.reason
    end

    test "#raise_if_cancelled! is a no-op when not cancelled" do
      cancellation = Cancellation.new

      assert_nil cancellation.raise_if_cancelled!
    end
  end
end
