# frozen_string_literal: true

module MCP
  class Configuration
    LATEST_STABLE_PROTOCOL_VERSION = "2026-07-28"
    ROOTS_SAMPLING_LOGGING_DEPRECATED_PROTOCOL_VERSION = "2026-07-28"
    SUPPORTED_STABLE_PROTOCOL_VERSIONS = [
      LATEST_STABLE_PROTOCOL_VERSION, "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05",
    ].freeze
    DEFAULT_NEGOTIATED_PROTOCOL_VERSION = "2025-03-26"

    # Protocol versions of the stateless "modern" lifecycle introduced by the MCP 2026-07-28 spec release (SEP-2575),
    # where each request carries its own version in `_meta` and is validated against this list independently,
    # with no handshake. These are reachable only through `server/discover` and the per-request envelope.
    # https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2575
    LATEST_MODERN_PROTOCOL_VERSION = "2026-07-28"
    SUPPORTED_MODERN_PROTOCOL_VERSIONS = [LATEST_MODERN_PROTOCOL_VERSION].freeze

    # Protocol versions reachable through the legacy `initialize` handshake, derived so the era partition
    # (handshake = stable minus modern) cannot drift when a new revision lands.
    # Per the SEP-2575 era model, an era is a property of the protocol version itself: legacy versions establish
    # a session via `initialize` (2025-11-25 and earlier), and modern versions carry the version on every request
    # in `_meta` with no handshake at all. The handshake therefore never negotiates a modern version:
    # a client asking `initialize` for one is counter-offered
    # `LATEST_HANDSHAKE_PROTOCOL_VERSION`, matching the TypeScript and Python SDKs.
    SUPPORTED_HANDSHAKE_PROTOCOL_VERSIONS = (SUPPORTED_STABLE_PROTOCOL_VERSIONS - SUPPORTED_MODERN_PROTOCOL_VERSIONS).freeze
    LATEST_HANDSHAKE_PROTOCOL_VERSION = SUPPORTED_HANDSHAKE_PROTOCOL_VERSIONS.first

    class << self
      def modern_protocol_version?(version)
        SUPPORTED_MODERN_PROTOCOL_VERSIONS.include?(version)
      end

      def handshake_protocol_version?(version)
        SUPPORTED_HANDSHAKE_PROTOCOL_VERSIONS.include?(version)
      end

      # The one statement of the client-side handshake contract, shared by every transport:
      # a modern version cannot ride the legacy `initialize` handshake.
      def reject_modern_handshake_version!(version)
        return unless version && modern_protocol_version?(version)

        raise ArgumentError, "protocol version #{version.inspect} cannot be negotiated through the legacy " \
                             "`initialize` handshake; use `mode: :modern` (or `:auto`) instead"
      end
    end

    attr_writer :exception_reporter, :around_request

    # @deprecated Use {#around_request=} instead. `instrumentation_callback`
    #   fires only after a request completes and cannot wrap execution in a
    #   surrounding block (e.g. for Application Performance Monitoring (APM) spans).
    # @see #around_request=
    attr_writer :instrumentation_callback

    def initialize(exception_reporter: nil, around_request: nil, instrumentation_callback: nil, protocol_version: nil,
      validate_tool_call_arguments: true, validate_tool_call_results: false, instrument_server_context: false)
      @exception_reporter = exception_reporter
      @around_request = around_request
      @instrumentation_callback = instrumentation_callback
      @protocol_version = protocol_version
      if protocol_version
        validate_protocol_version!(protocol_version)
      end
      validate_value_of_validate_tool_call_arguments!(validate_tool_call_arguments)
      validate_value_of_validate_tool_call_results!(validate_tool_call_results)
      validate_value_of_instrument_server_context!(instrument_server_context)

      @validate_tool_call_arguments = validate_tool_call_arguments
      @validate_tool_call_results = validate_tool_call_results
      @instrument_server_context = instrument_server_context
    end

    def protocol_version=(protocol_version)
      validate_protocol_version!(protocol_version)

      @protocol_version = protocol_version
    end

    def validate_tool_call_arguments=(validate_tool_call_arguments)
      validate_value_of_validate_tool_call_arguments!(validate_tool_call_arguments)

      @validate_tool_call_arguments = validate_tool_call_arguments
    end

    # Opt in to exposing the user-defined `server_context` in the
    # `around_request` / `instrumentation_callback` data hash. Off by default:
    # the hash is application-supplied and may hold values a tracing backend
    # should not receive, so surfacing it has to be a deliberate choice.
    def instrument_server_context=(instrument_server_context)
      validate_value_of_instrument_server_context!(instrument_server_context)

      @instrument_server_context = instrument_server_context
    end

    def validate_tool_call_results=(validate_tool_call_results)
      validate_value_of_validate_tool_call_results!(validate_tool_call_results)

      @validate_tool_call_results = validate_tool_call_results
    end

    # The pin scopes the `initialize` handshake, so an unset pin reads as the version that handshake
    # settles on by default. Reading the newest version of any era here would hand back a value
    # the writer rejects, and no caller wants the modern revision: a modern connection carries
    # its version on every request instead of consulting configuration.
    def protocol_version
      @protocol_version || LATEST_HANDSHAKE_PROTOCOL_VERSION
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

    def around_request
      @around_request || default_around_request
    end

    def around_request?
      !@around_request.nil?
    end

    # @deprecated Use {#around_request} instead. `instrumentation_callback`
    #   fires only after a request completes and cannot wrap execution in a
    #   surrounding block (e.g. for Application Performance Monitoring (APM) spans).
    # @see #around_request
    def instrumentation_callback
      @instrumentation_callback || default_instrumentation_callback
    end

    # @deprecated Use {#around_request?} instead.
    # @see #around_request?
    def instrumentation_callback?
      !@instrumentation_callback.nil?
    end

    attr_reader :validate_tool_call_arguments
    attr_reader :validate_tool_call_results

    def instrument_server_context?
      !!@instrument_server_context
    end

    def validate_tool_call_arguments?
      !!@validate_tool_call_arguments
    end

    def validate_tool_call_results?
      !!@validate_tool_call_results
    end

    def merge(other)
      return self if other.nil?

      exception_reporter = if other.exception_reporter?
        other.exception_reporter
      else
        @exception_reporter
      end

      around_request = if other.around_request?
        other.around_request
      else
        @around_request
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
      validate_tool_call_results = other.validate_tool_call_results

      Configuration.new(
        exception_reporter: exception_reporter,
        around_request: around_request,
        instrumentation_callback: instrumentation_callback,
        protocol_version: protocol_version,
        validate_tool_call_arguments: validate_tool_call_arguments,
        validate_tool_call_results: validate_tool_call_results,
        instrument_server_context: other.instrument_server_context?,
      )
    end

    private

    # A pin scopes the `initialize` handshake, so only handshake versions are accepted:
    # a modern version has no handshake to pin (its version rides every request in `_meta`),
    # and accepting one here would configure nothing. Failing at construction beats
    # a setting that silently does not apply.
    def validate_protocol_version!(protocol_version)
      return if SUPPORTED_HANDSHAKE_PROTOCOL_VERSIONS.include?(protocol_version)

      # A version this SDK serves, rejected only for where it was set, deserves the reason and
      # the alternative rather than a list it is missing from: this is the error an upgrade from
      # a release that accepted the value lands on, so it doubles as the migration note.
      if self.class.modern_protocol_version?(protocol_version)
        raise ArgumentError, "protocol_version #{protocol_version.inspect} is a modern protocol version and cannot be pinned here: " \
                             "the pin scopes the `initialize` handshake, which never negotiates a modern version. " \
                             "Modern clients carry their version on every request and need no pin; remove the setting."
      end

      raise ArgumentError, "protocol_version must be #{SUPPORTED_HANDSHAKE_PROTOCOL_VERSIONS[0...-1].join(", ")}, " \
                           "or #{SUPPORTED_HANDSHAKE_PROTOCOL_VERSIONS[-1]}"
    end

    def validate_value_of_validate_tool_call_arguments!(validate_tool_call_arguments)
      unless validate_tool_call_arguments.is_a?(TrueClass) || validate_tool_call_arguments.is_a?(FalseClass)
        raise ArgumentError, "validate_tool_call_arguments must be a boolean"
      end
    end

    def validate_value_of_validate_tool_call_results!(validate_tool_call_results)
      unless validate_tool_call_results.is_a?(TrueClass) || validate_tool_call_results.is_a?(FalseClass)
        raise ArgumentError, "validate_tool_call_results must be a boolean"
      end
    end

    def validate_value_of_instrument_server_context!(instrument_server_context)
      unless instrument_server_context.is_a?(TrueClass) || instrument_server_context.is_a?(FalseClass)
        raise ArgumentError, "instrument_server_context must be a boolean"
      end
    end

    def default_exception_reporter
      @default_exception_reporter ||= ->(exception, server_context) {}
    end

    def default_around_request
      @default_around_request ||= ->(_data, &request_handler) { request_handler.call }
    end

    # @deprecated Use {#default_around_request} instead.
    def default_instrumentation_callback
      @default_instrumentation_callback ||= ->(data) {}
    end
  end
end
