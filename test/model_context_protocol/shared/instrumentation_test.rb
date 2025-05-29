# frozen_string_literal: true

require "test_helper"

module ModelContextProtocol
  class InstrumentationTest < ActiveSupport::TestCase
    class Subject
      include Instrumentation
      attr_reader :instrumentation_data_received, :configuration

      def initialize
        @configuration = ModelContextProtocol::Configuration.new
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
