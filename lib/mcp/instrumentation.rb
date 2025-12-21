# frozen_string_literal: true

module MCP
  module Instrumentation
    def instrument_call(method, &block)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        @instrumentation_data = {}
        add_instrumentation_data(method: method)

        result = yield block

        result
      ensure
        end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        add_instrumentation_data(duration: end_time - start_time)

        configuration.instrumentation_callback.call(@instrumentation_data)
      end
    end

    def add_instrumentation_data(**kwargs)
      @instrumentation_data.merge!(kwargs)
    end
  end
end
