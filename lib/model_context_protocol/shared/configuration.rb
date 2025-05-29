# frozen_string_literal: true

module ModelContextProtocol
  class Configuration
    DEFAULT_PROTOCOL_VERSION = "2024-11-05"

    attr_writer :exception_reporter, :instrumentation_callback, :protocol_version

    def initialize(exception_reporter: nil, instrumentation_callback: nil, protocol_version: nil)
      @exception_reporter = exception_reporter
      @instrumentation_callback = instrumentation_callback
      @protocol_version = protocol_version
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

      Configuration.new(
        exception_reporter:,
        instrumentation_callback:,
        protocol_version:,
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
