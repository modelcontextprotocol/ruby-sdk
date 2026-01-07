# frozen_string_literal: true

module MCP
  class Configuration
    LATEST_STABLE_PROTOCOL_VERSION = "2025-11-25"
    SUPPORTED_STABLE_PROTOCOL_VERSIONS = [
      LATEST_STABLE_PROTOCOL_VERSION, "2025-06-18", "2025-03-26", "2024-11-05",
    ]

    attr_writer :exception_reporter, :instrumentation_callback

    def initialize(exception_reporter: nil, instrumentation_callback: nil, protocol_version: nil,
      validate_tool_call_arguments: true)
      @exception_reporter = exception_reporter
      @instrumentation_callback = instrumentation_callback
      @protocol_version = protocol_version
      if protocol_version
        validate_protocol_version!(protocol_version)
      end
      validate_value_of_validate_tool_call_arguments!(validate_tool_call_arguments)

      @validate_tool_call_arguments = validate_tool_call_arguments
    end

    def protocol_version=(protocol_version)
      validate_protocol_version!(protocol_version)

      @protocol_version = protocol_version
    end

    def validate_tool_call_arguments=(validate_tool_call_arguments)
      validate_value_of_validate_tool_call_arguments!(validate_tool_call_arguments)

      @validate_tool_call_arguments = validate_tool_call_arguments
    end

    def protocol_version
      @protocol_version || LATEST_STABLE_PROTOCOL_VERSION
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
        exception_reporter: exception_reporter,
        instrumentation_callback: instrumentation_callback,
        protocol_version: protocol_version,
        validate_tool_call_arguments: validate_tool_call_arguments,
      )
    end

    private

    def validate_protocol_version!(protocol_version)
      unless SUPPORTED_STABLE_PROTOCOL_VERSIONS.include?(protocol_version)
        message = "protocol_version must be #{SUPPORTED_STABLE_PROTOCOL_VERSIONS[0...-1].join(", ")}, or #{SUPPORTED_STABLE_PROTOCOL_VERSIONS[-1]}"
        raise ArgumentError, message
      end
    end

    def validate_value_of_validate_tool_call_arguments!(validate_tool_call_arguments)
      unless validate_tool_call_arguments.is_a?(TrueClass) || validate_tool_call_arguments.is_a?(FalseClass)
        raise ArgumentError, "validate_tool_call_arguments must be a boolean"
      end
    end

    def default_exception_reporter
      @default_exception_reporter ||= ->(exception, server_context) {}
    end

    def default_instrumentation_callback
      @default_instrumentation_callback ||= ->(data) {}
    end
  end
end
