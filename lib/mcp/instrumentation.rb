# frozen_string_literal: true

module MCP
  module Instrumentation
    def instrument_call(method, server_context: {}, exception_already_reported: nil, &block)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        @instrumentation_data = {}
        add_instrumentation_data(method: method)

        result = configuration.around_request.call(@instrumentation_data, &block)

        result
      rescue => e
        already_reported = begin
          !!exception_already_reported&.call(e)
        # rubocop:disable Lint/RescueException
        rescue Exception
          # rubocop:enable Lint/RescueException
          # The predicate is expected to be side-effect-free and return a boolean.
          # Any exception raised from it (including non-StandardError such as SystemExit)
          # must not shadow the original exception.
          false
        end

        unless already_reported
          add_instrumentation_data(error: :internal_error) unless @instrumentation_data.key?(:error)
          configuration.exception_reporter.call(e, server_context)
        end

        raise
      ensure
        end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        add_instrumentation_data(duration: end_time - start_time)

        # Backward compatibility: `instrumentation_callback` is soft-deprecated
        # in favor of `around_request`, but existing callers still expect it
        # to fire after every request until it is removed in a future version.
        configuration.instrumentation_callback.call(@instrumentation_data)
      end
    end

    def add_instrumentation_data(**kwargs)
      @instrumentation_data.merge!(kwargs)
    end
  end
end
