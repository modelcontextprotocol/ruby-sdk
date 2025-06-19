# frozen_string_literal: true

module MCP
  class Configuration
    DEFAULT_PROTOCOL_VERSION = "2024-11-05"

    attr_writer :exception_reporter, :instrumentation_callback, :protocol_version, :validate_tool_call_arguments

    def initialize(exception_reporter: nil, instrumentation_callback: nil, protocol_version: nil,
      validate_tool_call_arguments: true)
      @exception_reporter = exception_reporter
      @instrumentation_callback = instrumentation_callback
      @protocol_version = protocol_version
      unless validate_tool_call_arguments.is_a?(TrueClass) || validate_tool_call_arguments.is_a?(FalseClass)
        raise ArgumentError, "validate_tool_call_arguments must be a boolean"
      end

      @validate_tool_call_arguments = validate_tool_call_arguments
    end

    def protocol_version
      @protocol_version || DEFAULT_PROTOCOL_VERSION
    end

    def protocol_version?
      !@protocol_version.nil?
    end

    def exception_reporter
      @exception_reporter || default_exception_reporter
    end

    def exception_reporter?
      !@exception_reporter.nil?
    end

    def instrumentation_callback
      @instrumentation_callback || default_instrumentation_callback
    end

    def instrumentation_callback?
      !@instrumentation_callback.nil?
    end

    attr_reader :validate_tool_call_arguments

    def validate_tool_call_arguments?
      !!@validate_tool_call_arguments
    end

    def merge(other)
      return self if other.nil?

      exception_reporter = if other.exception_reporter?
        other.exception_reporter
      else
        @exception_reporter
      end
      instrumentation_callback = if other.instrumentation_callback?
        other.instrumentation_callback
      else
        @instrumentation_callback
      end
      protocol_version = if other.protocol_version?
        other.protocol_version
      else
        @protocol_version
      end
      validate_tool_call_arguments = other.validate_tool_call_arguments

      Configuration.new(
        exception_reporter:,
        instrumentation_callback:,
        protocol_version:,
        validate_tool_call_arguments:,
      )
    end

    private

    def default_exception_reporter
      @default_exception_reporter ||= ->(exception, server_context) {}
    end

    def default_instrumentation_callback
      @default_instrumentation_callback ||= ->(data) {}
    end
  end
end
