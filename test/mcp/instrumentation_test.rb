# frozen_string_literal: true

require "test_helper"
require "mcp/instrumentation"

module MCP
  class InstrumentationTest < ActiveSupport::TestCase
    class Subject
      include Instrumentation
      attr_reader :instrumentation_data_received, :configuration

      def initialize
        @configuration = MCP::Configuration.new
        @configuration.instrumentation_callback = ->(data) { @instrumentation_data_received = data }
      end

      def instrumented_method
        instrument_call("instrumented_method") do
          # nothing to do
        end
      end

      def instrumented_method_with_additional_data
        instrument_call("instrumented_method_with_additional_data") do
          add_instrumentation_data(additional_data: "test")
        end
      end

      def instrumented_method_with_server_context(context)
        instrument_call("instrumented_method_with_server_context", server_context: context) do
          # nothing to do
        end
      end

      def instrumented_method_that_raises_with_error_set
        instrument_call("instrumented_method_that_raises_with_error_set") do
          add_instrumentation_data(error: :custom_error)
          raise "block error"
        end
      end
    end

    test "#instrument_call adds the method name to the instrumentation data" do
      subject = Subject.new

      subject.instrumented_method
      assert_equal({ method: "instrumented_method" }, subject.instrumentation_data_received.tap do |data|
        data.delete(:duration)
      end)
    end

    test "#instrument_call exposes data added via add_instrumentation_data" do
      subject = Subject.new

      subject.instrumented_method_with_additional_data
      assert_equal(
        { method: "instrumented_method_with_additional_data", additional_data: "test" },
        subject.instrumentation_data_received.tap { |data| data.delete(:duration) },
      )
    end

    test "#instrument_call invokes around_request wrapping execution" do
      call_log = []
      subject = Subject.new
      subject.configuration.around_request = ->(_data, &request_handler) {
        call_log << :before
        request_handler.call
        call_log << :after
      }

      subject.instrumented_method

      assert_equal([:before, :after], call_log)
    end

    test "#instrument_call around_request receives method before request_handler.call" do
      received_method = nil
      subject = Subject.new
      subject.configuration.around_request = ->(data, &request_handler) {
        received_method = data[:method]
        request_handler.call
      }

      subject.instrumented_method

      assert_equal("instrumented_method", received_method)
    end

    test "#instrument_call around_request data is populated after request_handler.call" do
      data_after_call = nil
      subject = Subject.new
      subject.configuration.around_request = ->(data, &request_handler) {
        request_handler.call
        data_after_call = data.dup
      }

      subject.instrumented_method_with_additional_data

      assert_equal("instrumented_method_with_additional_data", data_after_call[:method])
      assert_equal("test", data_after_call[:additional_data])
    end

    test "#instrument_call default around_request is pass-through" do
      subject = Subject.new

      subject.instrumented_method_with_additional_data

      assert_equal(
        { method: "instrumented_method_with_additional_data", additional_data: "test" },
        subject.instrumentation_data_received.tap { |data| data.delete(:duration) },
      )
    end

    test "#instrument_call reports exception and sets error when around_request raises before request_handler.call" do
      reported_exception = nil
      reported_context = nil
      subject = Subject.new
      subject.configuration.exception_reporter = ->(e, server_context) {
        reported_exception = e
        reported_context = server_context
      }
      subject.configuration.around_request = ->(_data, &_request_handler) { raise "boom before" }

      error = assert_raises(RuntimeError) { subject.instrumented_method }
      assert_equal("boom before", error.message)
      assert_same(error, reported_exception)
      assert_equal({}, reported_context)
      assert_equal(:internal_error, subject.instrumentation_data_received[:error])
      assert(subject.instrumentation_data_received.key?(:duration))
    end

    test "#instrument_call reports exception and sets error when around_request raises after request_handler.call" do
      reported_exception = nil
      subject = Subject.new
      subject.configuration.exception_reporter = ->(e, _server_context) { reported_exception = e }
      subject.configuration.around_request = ->(_data, &request_handler) {
        request_handler.call
        raise "boom after"
      }

      error = assert_raises(RuntimeError) { subject.instrumented_method }
      assert_equal("boom after", error.message)
      assert_same(error, reported_exception)
      assert_equal(:internal_error, subject.instrumentation_data_received[:error])
    end

    test "#instrument_call preserves block's custom error tag and reports the exception" do
      report_count = 0
      subject = Subject.new
      subject.configuration.exception_reporter = ->(_e, _server_context) { report_count += 1 }

      assert_raises(RuntimeError) { subject.instrumented_method_that_raises_with_error_set }
      assert_equal(1, report_count)
      assert_equal(:custom_error, subject.instrumentation_data_received[:error])
    end

    test "#instrument_call skips reporting when exception_already_reported returns true" do
      reported = []
      subject = Subject.new
      subject.configuration.exception_reporter = ->(e, _server_context) { reported << e.message }

      error = StandardError.new("inner failure")
      subject.define_singleton_method(:instrumented_with_skip) do
        instrument_call("instrumented_with_skip", exception_already_reported: ->(e) { error.equal?(e) }) do
          raise error
        end
      end

      assert_raises(StandardError) { subject.instrumented_with_skip }
      assert_equal([], reported)
    end

    test "#instrument_call reports when exception_already_reported returns false for a new exception" do
      reported = []
      subject = Subject.new
      subject.configuration.exception_reporter = ->(e, _server_context) { reported << e.message }

      target = StandardError.new("inner failure")
      subject.configuration.around_request = ->(_data, &request_handler) do
        request_handler.call
      ensure
        raise "ensure boom"
      end

      subject.define_singleton_method(:instrumented_with_skip) do
        instrument_call("instrumented_with_skip", exception_already_reported: ->(e) { target.equal?(e) }) do
          raise target
        end
      end

      assert_raises(RuntimeError) { subject.instrumented_with_skip }
      assert_equal(["ensure boom"], reported)
    end

    test "#instrument_call falls back to reporting when exception_already_reported itself raises" do
      reported = []
      subject = Subject.new
      subject.configuration.exception_reporter = ->(e, _server_context) { reported << e.message }

      subject.define_singleton_method(:instrumented_with_broken_predicate) do
        instrument_call(
          "instrumented_with_broken_predicate",
          exception_already_reported: ->(_e) { raise "predicate blew up" },
        ) do
          raise "original failure"
        end
      end

      error = assert_raises(RuntimeError) { subject.instrumented_with_broken_predicate }
      assert_equal("original failure", error.message)
      assert_equal(["original failure"], reported)
    end

    test "#instrument_call falls back to reporting when exception_already_reported raises a non-StandardError" do
      reported = []
      subject = Subject.new
      subject.configuration.exception_reporter = ->(e, _server_context) { reported << e.message }

      subject.define_singleton_method(:instrumented_with_system_exit_predicate) do
        instrument_call(
          "instrumented_with_system_exit_predicate",
          exception_already_reported: ->(_e) { raise SystemExit, 9 },
        ) do
          raise "original failure"
        end
      end

      error = assert_raises(RuntimeError) { subject.instrumented_with_system_exit_predicate }
      assert_equal("original failure", error.message)
      assert_equal(["original failure"], reported)
    end

    test "#instrument_call normalizes non-boolean truthy return values from exception_already_reported" do
      reported = []
      subject = Subject.new
      subject.configuration.exception_reporter = ->(e, _server_context) { reported << e.message }

      subject.define_singleton_method(:instrumented_with_truthy_predicate) do
        instrument_call(
          "instrumented_with_truthy_predicate",
          exception_already_reported: ->(_e) { "non-boolean truthy" },
        ) do
          raise "original failure"
        end
      end

      assert_raises(RuntimeError) { subject.instrumented_with_truthy_predicate }
      assert_equal([], reported)
    end

    test "#instrument_call reports when exception_already_reported returns nil" do
      reported = []
      subject = Subject.new
      subject.configuration.exception_reporter = ->(e, _server_context) { reported << e.message }

      subject.define_singleton_method(:instrumented_with_nil_predicate) do
        instrument_call(
          "instrumented_with_nil_predicate",
          exception_already_reported: ->(_e) { nil },
        ) do
          raise "original failure"
        end
      end

      assert_raises(RuntimeError) { subject.instrumented_with_nil_predicate }
      assert_equal(["original failure"], reported)
    end

    test "#instrument_call does not carry reported state across invocations when the same exception is reused" do
      reported = []
      subject = Subject.new
      subject.configuration.exception_reporter = ->(e, _server_context) { reported << e.message }

      shared_error = RuntimeError.new("reused")
      subject.configuration.around_request = ->(_data, &_request_handler) { raise shared_error }

      2.times do
        assert_raises(RuntimeError) { subject.instrumented_method }
      end
      assert_equal(["reused", "reused"], reported)
    end

    test "#instrument_call reports frozen exceptions without mutating them" do
      reported = []
      subject = Subject.new
      subject.configuration.exception_reporter = ->(e, _server_context) { reported << e }

      frozen_error = RuntimeError.new("frozen").freeze
      subject.configuration.around_request = ->(_data, &_request_handler) { raise frozen_error }

      error = assert_raises(RuntimeError) { subject.instrumented_method }
      assert_same(frozen_error, error)
      assert_equal([frozen_error], reported)
      assert_predicate(frozen_error, :frozen?)
    end

    test "#instrument_call nested calls sharing an exception_already_reported predicate report only once" do
      reported = []
      subject = Subject.new
      subject.configuration.exception_reporter = ->(e, _server_context) { reported << e.message }

      reported_exception = nil
      predicate = ->(e) { reported_exception.equal?(e) }

      subject.define_singleton_method(:outer) do
        instrument_call("outer", exception_already_reported: predicate) { inner }
      end

      subject.define_singleton_method(:inner) do
        instrument_call("inner", exception_already_reported: predicate) do
          raise "nested boom"
        rescue => e
          configuration.exception_reporter.call(e, {})
          reported_exception = e
          raise
        end
      end

      assert_raises(RuntimeError) { subject.outer }
      assert_equal(["nested boom"], reported)
    end

    test "#instrument_call keeps reported state isolated across concurrent threads on a shared subject" do
      subject = Subject.new
      reported = Queue.new
      subject.configuration.exception_reporter = ->(e, _server_context) { reported << e.message }

      threads = 10.times.map do |i|
        Thread.new do
          subject.instrument_call("threaded_#{i}") { raise "thread #{i}" }
        rescue RuntimeError
          # Swallow the intentional raise so the thread finishes cleanly.
          # The test verifies side effects via the shared `reported` queue.
        end
      end
      threads.each(&:join)

      messages = []
      messages << reported.pop until reported.empty?

      assert_equal(10.times.map { |i| "thread #{i}" }, messages.sort)
    end

    test "#instrument_call reports each invocation when the same exception instance is raised from multiple threads" do
      subject = Subject.new
      reported = Queue.new
      subject.configuration.exception_reporter = ->(e, _server_context) { reported << e }

      shared_error = RuntimeError.new("shared across threads")
      start_gate = Queue.new

      threads = 10.times.map do
        Thread.new do
          start_gate.pop
          begin
            subject.instrument_call("shared_error_method") { raise shared_error }
          rescue RuntimeError
            # Swallow the intentional raise so the thread finishes cleanly.
            # The test verifies side effects via the shared `reported` queue.
          end
        end
      end
      10.times { start_gate << :go }
      threads.each(&:join)

      collected = []
      collected << reported.pop until reported.empty?

      assert_equal(10, collected.size)
      assert(collected.all? { |e| e.equal?(shared_error) })
    end

    test "#instrument_call forwards server_context to exception_reporter on around_request failure" do
      reported_context = nil
      subject = Subject.new
      subject.configuration.exception_reporter = ->(_e, server_context) { reported_context = server_context }
      subject.configuration.around_request = ->(_data, &_request_handler) { raise "boom" }

      assert_raises(RuntimeError) do
        subject.instrumented_method_with_server_context(request: { id: 42 })
      end
      assert_equal({ request: { id: 42 } }, reported_context)
    end

    test "#instrument_call resets the instrumentation data between calls" do
      subject = Subject.new

      subject.instrumented_method_with_additional_data
      assert_equal(
        { method: "instrumented_method_with_additional_data", additional_data: "test" },
        subject.instrumentation_data_received.tap { |data| data.delete(:duration) },
      )

      subject.instrumented_method
      assert_equal({ method: "instrumented_method" }, subject.instrumentation_data_received.tap do |data|
        data.delete(:duration)
      end)
    end
  end
end
