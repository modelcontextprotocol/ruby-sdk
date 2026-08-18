# frozen_string_literal: true

require "securerandom"

require_relative "../json_rpc_handler"
require_relative "cancellation"
require_relative "cancelled_error"
require_relative "instrumentation"
require_relative "methods"
require_relative "logging_message_notification"
require_relative "progress"
require_relative "protocol_deprecations"
require_relative "server_context"
require_relative "server/capabilities"
require_relative "server/input_required_result"
require_relative "server/pagination"
require_relative "server/pending_response"
require_relative "server/request_state_security"
require_relative "server/transports"

module MCP
  class ToolNotUnique < StandardError
    def initialize(duplicated_tool_names)
      super(<<~MESSAGE)
        Tool names should be unique. Use `tool_name` to assign unique names to:
        #{duplicated_tool_names.join(", ")}
      MESSAGE
    end
  end

  class Server
    DEFAULT_VERSION = "0.1.0"

    UNSUPPORTED_PROPERTIES_UNTIL_2025_06_18 = [:description, :icons].freeze
    UNSUPPORTED_PROPERTIES_UNTIL_2025_03_26 = [:title, :websiteUrl].freeze

    DEFAULT_COMPLETION_RESULT = { completion: { values: [], hasMore: false } }.freeze

    # Servers return an array of completion values ranked by relevance, with maximum 100 items per response.
    # https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/completion#completion-results
    MAX_COMPLETION_VALUES = 100

    class RequestHandlerError < StandardError
      attr_reader :error_type, :original_error, :error_code, :error_data

      def initialize(message, request, error_type: :internal_error, original_error: nil, error_code: nil, error_data: nil)
        super(message)
        @request = request
        @error_type = error_type
        @original_error = original_error
        @error_code = error_code
        @error_data = error_data
      end
    end

    class URLElicitationRequiredError < RequestHandlerError
      def initialize(elicitations)
        super(
          "URL elicitation required",
          nil,
          error_type: :url_elicitation_required,
          error_code: -32042,
          error_data: { elicitations: elicitations },
        )
      end
    end

    # Raised when a request carries a protocol version the server does not support under the stateless lifecycle of
    # MCP 2026-07-28 (SEP-2575). Maps to JSON-RPC error `-32022` with `data: { supported: [...], requested: "..." }`
    # so the client can select a mutually supported version and retry.
    #
    # https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2575
    class UnsupportedProtocolVersionError < RequestHandlerError
      # No keyword parameters here: with one present, Ruby 2.7 would split a trailing symbol-keyed `request` Hash
      # into keywords and fail with "unknown keywords".
      def initialize(requested, request = nil)
        super(
          "Unsupported protocol version",
          request,
          error_type: :unsupported_protocol_version,
          error_code: ErrorCodes::UNSUPPORTED_PROTOCOL_VERSION,
          error_data: { supported: Configuration::SUPPORTED_MODERN_PROTOCOL_VERSIONS, requested: requested || "unknown" },
        )
      end
    end

    # Raised when processing a request requires a client capability the request did not declare in `_meta`
    # (`io.modelcontextprotocol/clientCapabilities`). Per SEP-2575, servers MUST NOT rely on capabilities
    # the client has not declared. Maps to JSON-RPC error `-32021` with `data: { requiredCapabilities: {...} }`
    # listing the missing capabilities.
    #
    # https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2575
    class MissingRequiredClientCapabilityError < RequestHandlerError
      def initialize(required_capabilities, request = nil)
        super(
          "Missing required client capability",
          request,
          error_type: :missing_required_client_capability,
          error_code: ErrorCodes::MISSING_REQUIRED_CLIENT_CAPABILITY,
          error_data: { requiredCapabilities: required_capabilities },
        )
      end
    end

    # Raised when a requested resource URI does not exist. Per SEP-2164,
    # resource-not-found errors use the standard JSON-RPC Invalid Params code (-32602)
    # with the requested URI in the error `data` member. Raise this from
    # a `resources_read_handler` block for unknown URIs:
    #
    #   server.resources_read_handler do |params|
    #     raise MCP::Server::ResourceNotFoundError.new(params[:uri], params) unless known?(params[:uri])
    #     do_something(params[:uri])
    #   end
    #
    # https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2164
    class ResourceNotFoundError < RequestHandlerError
      def initialize(uri, request = nil)
        # The explicit `error_code` keeps the descriptive message in the JSON-RPC
        # error response; `error_type: :invalid_params` alone would replace it
        # with the generic "Invalid params" string.
        super(
          "Resource not found: #{uri}",
          request,
          error_type: :invalid_params,
          error_code: JsonRpcHandler::ErrorCode::INVALID_PARAMS,
          error_data: { uri: uri },
        )
      end
    end

    # Raised when a server-to-client request (sampling, elicitation, `roots/list`, `ping`) goes unanswered past its timeout.
    # The spec asks implementations to bound every sent request so a peer that never answers cannot exhaust the sender's resources,
    # and to cancel the request on expiry; the transport sends `notifications/cancelled` before raising this.
    # These requests exist only on connections speaking 2025-11-25 or earlier, since the modern lifecycle forbids them.
    #
    # Left uncaught in a handler, this answers the client's originating request with `-32001` rather than a generic
    # internal error, so the peer that failed to answer can tell a timeout apart from a server fault. The code is not
    # spec-allocated: it sits in the implementation-defined server range and is the value the Python SDK reports for
    # this condition, so a client that already recognizes it there reads the same meaning here.
    #
    # https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle#timeouts
    class RequestTimeoutError < RequestHandlerError
      attr_reader :request_id, :timeout

      def initialize(message, request_id:, timeout:)
        super(message, nil, error_type: :request_timeout, error_code: -32001)
        @request_id = request_id
        @timeout = timeout
      end
    end

    class MethodAlreadyDefinedError < StandardError
      attr_reader :method_name

      def initialize(method_name)
        super("Method #{method_name} already defined")
        @method_name = method_name
      end
    end

    # Raised when a client response fails server-side validation, e.g., a success response
    # whose `result` field is missing or has the wrong type. This is distinct from a
    # client-returned JSON-RPC error.
    class ValidationError < StandardError; end

    include Instrumentation
    include Pagination

    # Allowed values for the SEP-2549 `cacheScope` cache hint.
    CACHE_SCOPES = ["public", "private"].freeze

    # Methods whose results are cacheable per SEP-2549.
    # On the modern wire (2026-07-28) the `ttlMs`/`cacheScope` hints are REQUIRED on these results,
    # so unset hints get the spec defaults there; on stable protocol versions emission stays opt-in
    # via `apply_cache_metadata`.
    CACHEABLE_RESULT_METHODS = [
      Methods::TOOLS_LIST,
      Methods::PROMPTS_LIST,
      Methods::RESOURCES_LIST,
      Methods::RESOURCES_TEMPLATES_LIST,
      Methods::RESOURCES_READ,
    ].freeze

    attr_accessor :description, :icons, :name, :title, :version, :website_url, :instructions, :tools, :prompts, :resource_templates, :server_context, :configuration, :capabilities, :transport, :logging_message_notification
    attr_reader :resources, :page_size, :client_capabilities, :ttl_ms, :cache_scope, :request_state_security

    def initialize(
      description: nil,
      icons: [],
      name: "model_context_protocol",
      title: nil,
      version: DEFAULT_VERSION,
      website_url: nil,
      instructions: nil,
      tools: [],
      prompts: [],
      resources: [],
      resource_templates: [],
      server_context: nil,
      configuration: nil,
      capabilities: nil,
      page_size: nil,
      ttl_ms: nil,
      cache_scope: nil,
      request_state_security: nil,
      input_required_legacy_shim: true,
      transport: nil
    )
      @description = description
      @icons = icons
      @name = name
      @title = title
      @version = version
      @website_url = website_url
      @instructions = instructions
      @tool_names = tools.map(&:name_value)
      @tools = tools.to_h { |t| [t.name_value, t] }
      @prompts = prompts.to_h { |p| [p.name_value, p] }
      @resources = resources
      @resource_templates = resource_templates
      @resource_index = index_resources_by_uri(resources)
      @server_context = server_context
      self.page_size = page_size
      self.ttl_ms = ttl_ms
      self.cache_scope = cache_scope
      @request_state_security = request_state_security

      # Dual-era authoring (SEP-2322): on the legacy wire, an `input_required` result is fulfilled
      # through real server-to-client requests and the handler re-runs, so handlers written
      # in the 2026 style serve both eras. `false` restores the strict rejection of `input_required`
      # on legacy requests. Matches the TypeScript SDK's default-on legacy shim.
      @input_required_legacy_shim = input_required_legacy_shim
      @configuration = MCP.configuration.merge(configuration)
      @client = nil
      @client_protocol_version = nil

      validate!

      # Accept either a plain Hash or an `MCP::Server::Capabilities` builder.
      @capabilities = if capabilities.is_a?(Capabilities)
        capabilities.to_h
      else
        capabilities || default_capabilities
      end
      @client_capabilities = nil
      @logging_message_notification = nil

      @handlers = {
        Methods::RESOURCES_LIST => method(:list_resources),
        Methods::RESOURCES_READ => method(:read_resource),
        Methods::RESOURCES_TEMPLATES_LIST => method(:list_resource_templates),
        Methods::RESOURCES_SUBSCRIBE => ->(_) { {} },
        Methods::RESOURCES_UNSUBSCRIBE => ->(_) { {} },
        Methods::TOOLS_LIST => method(:list_tools),
        Methods::TOOLS_CALL => method(:call_tool),
        Methods::PROMPTS_LIST => method(:list_prompts),
        Methods::PROMPTS_GET => method(:get_prompt),
        Methods::INITIALIZE => method(:init),
        Methods::SERVER_DISCOVER => method(:discover),
        Methods::PING => ->(_) { {} },
        Methods::NOTIFICATIONS_INITIALIZED => ->(_) {},
        Methods::NOTIFICATIONS_PROGRESS => ->(_) {},
        Methods::NOTIFICATIONS_ROOTS_LIST_CHANGED => ->(_) {},
        Methods::COMPLETION_COMPLETE => ->(_) { DEFAULT_COMPLETION_RESULT },
        Methods::LOGGING_SET_LEVEL => method(:configure_logging_level),
      }
      @transport = transport
    end

    # Processes a parsed JSON-RPC request and returns the response as a Hash.
    #
    # @param request [Hash] A parsed JSON-RPC request.
    # @param session [ServerSession, nil] Per-connection session. Passed by
    #   `ServerSession#handle` for session-scoped notification delivery.
    #   When `nil`, progress and logging notifications from tool handlers are silently skipped.
    # @return [Hash, nil] The JSON-RPC response, or `nil` for notifications.
    def handle(request, session: nil)
      JsonRpcHandler.handle(request) do |method, request_id|
        handle_request(request, method, session: session, related_request_id: request_id)
      end
    end

    # Processes a JSON-RPC request string and returns the response as a JSON string.
    #
    # @param request [String] A JSON-RPC request as a JSON string.
    # @param session [ServerSession, nil] Per-connection session. Passed by
    #   `ServerSession#handle_json` for session-scoped notification delivery.
    #   When `nil`, progress and logging notifications from tool handlers are silently skipped.
    # @return [String, nil] The JSON-RPC response as JSON, or `nil` for notifications.
    def handle_json(request, session: nil)
      JsonRpcHandler.handle_json(request) do |method, request_id|
        handle_request(request, method, session: session, related_request_id: request_id)
      end
    end

    def define_tool(name: nil, title: nil, description: nil, input_schema: nil, output_schema: nil, annotations: nil, meta: nil, &block)
      tool = Tool.define(name: name, title: title, description: description, input_schema: input_schema, output_schema: output_schema, annotations: annotations, meta: meta, &block)
      tool_name = tool.name_value

      @tool_names << tool_name
      @tools[tool_name] = tool

      validate!
    end

    def define_prompt(name: nil, title: nil, description: nil, arguments: [], &block)
      prompt = Prompt.define(name: name, title: title, description: description, arguments: arguments, &block)
      @prompts[prompt.name_value] = prompt

      validate!
    end

    def define_resource(uri: nil, name: nil, title: nil, description: nil, icons: [], mime_type: nil, annotations: nil, size: nil, meta: nil, &block)
      resource = Resource.define(
        uri: uri, name: name, title: title, description: description, icons: icons,
        mime_type: mime_type, annotations: annotations, size: size, meta: meta,
        &block
      )
      @resources << resource
      @resource_index[resource.uri] = resource

      validate!
    end

    def define_resource_template(uri_template: nil, name: nil, title: nil, description: nil, icons: [], mime_type: nil, annotations: nil, meta: nil, &block)
      resource_template = ResourceTemplate.define(
        uri_template: uri_template, name: name, title: title, description: description, icons: icons,
        mime_type: mime_type, annotations: annotations, meta: meta,
        &block
      )
      @resource_templates << resource_template

      validate!
    end

    def resources=(resources)
      @resources = resources
      @resource_index = index_resources_by_uri(resources)
    end

    def define_custom_method(method_name:, &block)
      if @handlers.key?(method_name)
        raise MethodAlreadyDefinedError, method_name
      end

      @handlers[method_name] = block
    end

    def page_size=(page_size)
      unless page_size.nil? || (page_size.is_a?(Integer) && page_size > 0)
        raise ArgumentError, "page_size must be nil or a positive integer"
      end

      @page_size = page_size
    end

    # SEP-2549 cache hint: freshness lifetime in milliseconds for list and read results
    # (max-age semantics; 0 means do not cache). Emission is opt-in: when both `ttl_ms`
    # and `cache_scope` are nil, results are serialized exactly as before.
    def ttl_ms=(ttl_ms)
      unless ttl_ms.nil? || (ttl_ms.is_a?(Integer) && ttl_ms >= 0)
        raise ArgumentError, "ttl_ms must be nil or a non-negative integer"
      end

      @ttl_ms = ttl_ms
    end

    # SEP-2549 cache hint: whether shared intermediaries may cache the result ("public")
    # or only the requesting client ("private").
    def cache_scope=(cache_scope)
      unless cache_scope.nil? || CACHE_SCOPES.include?(cache_scope)
        raise ArgumentError, "cache_scope must be nil, \"public\", or \"private\""
      end

      @cache_scope = cache_scope
    end

    def notify_tools_list_changed
      return unless @transport

      @transport.send_notification(Methods::NOTIFICATIONS_TOOLS_LIST_CHANGED)
    rescue => e
      report_exception(e, { notification: "tools_list_changed" })
    end

    def notify_prompts_list_changed
      return unless @transport

      @transport.send_notification(Methods::NOTIFICATIONS_PROMPTS_LIST_CHANGED)
    rescue => e
      report_exception(e, { notification: "prompts_list_changed" })
    end

    def notify_resources_list_changed
      return unless @transport

      @transport.send_notification(Methods::NOTIFICATIONS_RESOURCES_LIST_CHANGED)
    rescue => e
      report_exception(e, { notification: "resources_list_changed" })
    end

    # @deprecated MCP Logging (`logging/setLevel` and `notifications/message`)
    #   is deprecated as of MCP protocol version 2026-07-28 (SEP-2577).
    #   Use stderr or OpenTelemetry instead.
    def notify_log_message(data:, level:, logger: nil)
      return unless @transport
      return unless logging_message_notification&.should_notify?(level)

      params = { "data" => data, "level" => level }
      params["logger"] = logger if logger

      @transport.send_notification(Methods::NOTIFICATIONS_MESSAGE, params)
    rescue => e
      report_exception(e, { notification: "log_message" })
    end

    # Sets a handler for `notifications/roots/list_changed` notifications.
    # Called when a client notifies the server that its filesystem roots have changed.
    #
    # @yield [params] The notification params (typically `nil`).
    # @deprecated MCP Roots (`roots/list` and
    #   `notifications/roots/list_changed`) is deprecated as of MCP protocol
    #   version 2026-07-28 (SEP-2577). Use tool parameters, resource URIs,
    #   server configuration, or environment variables instead.
    def roots_list_changed_handler(&block)
      @handlers[Methods::NOTIFICATIONS_ROOTS_LIST_CHANGED] = block
    end

    # Sets a custom handler for `resources/read` requests.
    # The block receives the parsed request params and should return resource
    # contents. The return value is set as the `contents` field of the response.
    #
    # @yield [params] The request params containing `:uri`.
    # @yieldreturn [Array<Hash>, Hash] Resource contents.
    def resources_read_handler(&block)
      @handlers[Methods::RESOURCES_READ] = block
    end

    # Sets a custom handler for `completion/complete` requests.
    # The block receives the parsed request params and should return completion values.
    #
    # @yield [params] The request params containing `:ref`, `:argument`, and optionally `:context`.
    # @yieldreturn [Hash] A hash with `:completion` key containing `:values`, optional `:total`, and `:hasMore`.
    def completion_handler(&block)
      @handlers[Methods::COMPLETION_COMPLETE] = block
    end

    # Sets a custom handler for `resources/subscribe` requests.
    # The block receives the parsed request params. The return value is
    # ignored; the response is always an empty result `{}` per the MCP specification.
    #
    # @yield [params] The request params containing `:uri`.
    def resources_subscribe_handler(&block)
      @handlers[Methods::RESOURCES_SUBSCRIBE] = block
    end

    # Sets a custom handler for `resources/unsubscribe` requests.
    # The block receives the parsed request params. The return value is
    # ignored; the response is always an empty result `{}` per the MCP specification.
    #
    # @yield [params] The request params containing `:uri`.
    def resources_unsubscribe_handler(&block)
      @handlers[Methods::RESOURCES_UNSUBSCRIBE] = block
    end

    def build_sampling_params(
      capabilities,
      messages:,
      max_tokens:,
      system_prompt: nil,
      model_preferences: nil,
      include_context: nil,
      temperature: nil,
      stop_sequences: nil,
      metadata: nil,
      tools: nil,
      tool_choice: nil
    )
      unless capabilities&.dig(:sampling)
        raise "Client does not support sampling."
      end

      if tools && !capabilities.dig(:sampling, :tools)
        raise "Client does not support sampling with tools."
      end

      if tool_choice && !capabilities.dig(:sampling, :tools)
        raise "Client does not support sampling with tool_choice."
      end

      {
        messages: messages,
        maxTokens: max_tokens,
        systemPrompt: system_prompt,
        modelPreferences: model_preferences,
        includeContext: include_context,
        temperature: temperature,
        stopSequences: stop_sequences,
        metadata: metadata,
        tools: tools,
        toolChoice: tool_choice,
      }.compact
    end

    private

    def validate!
      validate_tool_name!

      # NOTE: The draft protocol version is the next version after 2025-11-25.
      if @configuration.protocol_version <= "2025-06-18"
        if server_info.key?(:description)
          message = "Error occurred in server_info. `description` is not supported in protocol version 2025-06-18 or earlier"
          raise ArgumentError, message
        end

        tools_with_ref = @tools.each_with_object([]) do |(tool_name, tool), names|
          names << tool_name if schema_contains_ref?(tool.input_schema_value.to_h)
        end
        unless tools_with_ref.empty?
          message = "Error occurred in #{tools_with_ref.join(", ")}. `$ref` in input schemas is supported by protocol version 2025-11-25 or higher"
          raise ArgumentError, message
        end
      end

      if @configuration.protocol_version <= "2025-03-26"
        if server_info.key?(:title) || server_info.key?(:websiteUrl)
          message = "Error occurred in server_info. `title` or `website_url` are not supported in protocol version 2025-03-26 or earlier"
          raise ArgumentError, message
        end

        primitive_titles = [@tools.values, @prompts.values, @resources, @resource_templates].flatten.map(&:title)

        if primitive_titles.any?
          message = "Error occurred in #{primitive_titles.join(", ")}. `title` is not supported in protocol version 2025-03-26 or earlier"
          raise ArgumentError, message
        end
      end

      if @configuration.protocol_version == "2024-11-05"
        if @instructions
          message = "`instructions` supported by protocol version 2025-03-26 or higher"
          raise ArgumentError, message
        end

        error_tool_names = @tools.each_with_object([]) do |(tool_name, tool), error_tool_names|
          if tool.annotations
            error_tool_names << tool_name
          end
        end
        unless error_tool_names.empty?
          message = "Error occurred in #{error_tool_names.join(", ")}. `annotations` are supported by protocol version 2025-03-26 or higher"
          raise ArgumentError, message
        end
      end
    end

    def validate_tool_name!
      duplicated_tool_names = @tool_names.tally.filter_map { |name, count| name if count >= 2 }

      raise ToolNotUnique, duplicated_tool_names unless duplicated_tool_names.empty?
    end

    def schema_contains_ref?(schema)
      case schema
      when Hash
        schema.any? { |key, value| key.to_s == "$ref" || schema_contains_ref?(value) }
      when Array
        schema.any? { |element| schema_contains_ref?(element) }
      else
        false
      end
    end

    def handle_request(request, method, session: nil, related_request_id: nil)
      # A well-formed notification carries no JSON-RPC id and receives no response.
      # If a client erroneously sends a notification-only method with an id, the message
      # is framed as a request; since notification methods have no request handler,
      # returning `nil` here makes `JsonRpcHandler` report "Method not found", matching
      # the TypeScript and Python SDKs rather than emitting a spurious `result: null`.
      return if Methods.notification?(method) && !related_request_id.nil?

      # `notifications/cancelled` is dispatched directly: it is a notification (no JSON-RPC id)
      # and intentionally bypasses the `@handlers` lookup, capability check, in-flight registry,
      # and rescue blocks below.
      if method == Methods::NOTIFICATIONS_CANCELLED
        return ->(params) { handle_cancelled_notification(params, session: session) }
      end

      handler = @handlers[method]
      unless handler
        instrument_call("unsupported_method", server_context: { request: request }) do
          client = session&.client || @client
          add_instrumentation_data(client: client) if client
        end
        return
      end

      # SEP-2575 removes these RPCs from the modern lifecycle, so they answer with Method not found
      # there regardless of the server's declared capabilities: in this era the method does not exist
      # at all, which is why the check precedes `ensure_capability!`.
      if Methods::MODERN_REMOVED_METHODS.include?(method) && modern_request?(request, session)
        raise RequestHandlerError.new(
          "Method not found: #{method} is not part of the modern lifecycle (SEP-2575)",
          request,
          error_type: :method_not_found,
          error_code: JsonRpcHandler::ErrorCode::METHOD_NOT_FOUND,
        )
      end

      begin
        Methods.ensure_capability!(method, capabilities)
      rescue Methods::MissingRequiredCapabilityError => e
        # Re-raise through RequestHandlerError, the one channel whose message is
        # deliberately surfaced to clients: `JsonRpcHandler`'s blind `rescue StandardError`
        # no longer echoes exception messages into the error `data` member (CWE-209).
        raise RequestHandlerError.new(e.message, request, error_type: :internal_error, original_error: e)
      end

      # `initialize` MUST NOT be cancelled (MCP spec 2025-11-25, cancellation item 2),
      # so do not track it in the in-flight registry.
      cancellation = nil
      if related_request_id && method != Methods::INITIALIZE && session
        cancellation = session.register_in_flight(related_request_id)

        # The spec puts the uniqueness obligation on the sender - "The request ID MUST NOT have been previously used by
        # the requestor within the same session" - and says nothing about what a receiver does with a duplicate.
        # Answering one is the only option that stays correct: the id routes request-scoped messages back to
        # the request that caused them, and the transport's rule is that those messages "SHOULD relate to
        # the originating client request", which a second live request under the same id makes impossible to honor
        # for either of them. Refused the same way a duplicate `initialize` is, and for the same reason:
        # so that a repeated id cannot silently displace state negotiated by the first one.
        if cancellation.nil?
          raise RequestHandlerError.new(
            "Invalid Request: request id #{related_request_id.inspect} is already in flight",
            request,
            error_type: :invalid_request,
          )
        end
      end

      ->(params) {
        reported_exception = nil
        instrument_call(
          method,
          server_context: { request: request },
          exception_already_reported: ->(e) { reported_exception.equal?(e) },
        ) do
          envelope = lift_request_envelope(params, method: method, session: session)

          # The envelope's `logLevel` member replaces `logging/setLevel` in the modern lifecycle:
          # it authorizes `notifications/message` for this request only (SEP-2575). Without it,
          # `ServerSession#notify_log_message` stays silent on modern-era sessions. An unrecognized level
          # reads as absent, so delivery stays off (the safe direction), matching the Python SDK.
          if envelope&.log_level && session.respond_to?(:configure_logging)
            request_logging = LoggingMessageNotification.new(level: envelope.log_level)
            session.configure_logging(request_logging) if request_logging.valid_level?
          end

          params = unseal_request_state(params, method: method) if @request_state_security

          result = case method
          when Methods::INITIALIZE
            init(params, session: session)
          when Methods::RESOURCES_READ
            contents = read_resource_contents(params, session: session, related_request_id: related_request_id, cancellation: cancellation, envelope: envelope)

            # An SEP-2322 `input_required` result must not be wrapped as `contents` or stamped with SEP-2549 cache hints.
            contents.is_a?(InputRequiredResult) ? contents : build_read_resource_result(contents)
          when Methods::RESOURCES_SUBSCRIBE, Methods::RESOURCES_UNSUBSCRIBE
            validate_resource_subscription_params!(params)
            dispatch_optional_context_handler(@handlers[method], params, session: session, related_request_id: related_request_id, cancellation: cancellation, envelope: envelope)
            {}
          when Methods::TOOLS_CALL
            call_tool(params, session: session, related_request_id: related_request_id, cancellation: cancellation, envelope: envelope)
          when Methods::PROMPTS_GET
            get_prompt(params, session: session, related_request_id: related_request_id, cancellation: cancellation, envelope: envelope)
          when Methods::COMPLETION_COMPLETE
            complete(params, session: session, related_request_id: related_request_id, cancellation: cancellation, envelope: envelope)
          when Methods::LOGGING_SET_LEVEL
            configure_logging_level(params, session: session)
          else
            dispatch_optional_context_handler(@handlers[method], params, session: session, related_request_id: related_request_id, cancellation: cancellation, envelope: envelope)
          end
          client = session&.client || @client
          add_instrumentation_data(client: client) if client

          if cancellation&.cancelled?
            add_instrumentation_data(cancelled: true, cancellation_reason: cancellation.reason)
            next JsonRpcHandler::NO_RESPONSE
          end

          # Runs after the cancellation check so a cancelled request stays suppressed
          # instead of turning into a gate error response.
          if result.is_a?(InputRequiredResult)
            result = if envelope.nil? && @input_required_legacy_shim && session
              run_legacy_input_required_shim(
                result,
                method: method,
                params: params,
                session: session,
                related_request_id: related_request_id,
                cancellation: cancellation,
              )
            else
              serialize_input_required_result(result, envelope: envelope, request: params, method: method)
            end
          end

          # SEP-2322 makes `resultType` REQUIRED on every result a 2026-07-28 server returns;
          # a missing value is only tolerated FROM earlier protocol versions. Results that already carry
          # a discriminator keep it; everything else on the modern wire is the standard shape,
          # `"complete"`. Legacy results stay unstamped: pre-2026 clients do not know the field.
          if envelope && result.is_a?(Hash) && !result.key?(:resultType)
            result = result.merge(resultType: ResultType::COMPLETE)
          end

          # SEP-2549 makes the `ttlMs`/`cacheScope` hints REQUIRED on cacheable results at 2026-07-28,
          # so unconfigured servers get `ttlMs: 0` (do not cache) and `cacheScope: "private"`:
          # the spec names no default scope, and `"private"` is the side that cannot leak
          # a user-dependent result through a shared cache, matching the TypeScript SDK's default
          # and `server/discover`. Values already in the result win.
          # Only complete results are cacheable: an SEP-2322 `input_required` round trip must not be stamped
          # (the stamp above guarantees `resultType` is present on every modern Hash result by this point).
          if envelope && result.is_a?(Hash) && CACHEABLE_RESULT_METHODS.include?(method) &&
              result[:resultType] == ResultType::COMPLETE && !(result.key?(:ttlMs) && result.key?(:cacheScope))
            result = { ttlMs: @ttl_ms || 0, cacheScope: @cache_scope || "private" }.merge(result)
          end

          result
        rescue CancelledError => e
          add_instrumentation_data(cancelled: true, cancellation_reason: e.reason)
          next JsonRpcHandler::NO_RESPONSE
        rescue RequestHandlerError => e
          report_exception(e.original_error || e, { request: request })
          add_instrumentation_data(error: e.error_type)
          reported_exception = e
          raise e
        rescue => e
          report_exception(e, { request: request })
          add_instrumentation_data(error: :internal_error)
          wrapped = RequestHandlerError.new("Internal error handling #{method} request", request, original_error: e)
          reported_exception = wrapped
          raise wrapped
        ensure
          # `cancellation` is non-nil exactly when this request claimed the id above, so this also keeps `initialize`
          # (which never registers) from evicting an in-flight registration under a reused id when the duplicate-`initialize`
          # refusal raises out of the handler.
          session&.unregister_in_flight(related_request_id, cancellation: cancellation) if related_request_id && cancellation
        end
      }
    end

    # Whether this request belongs to the modern lifecycle, used to refuse the RPCs SEP-2575 removed from it.
    # A locked `ServerSession#era` is authoritative; until it locks, the request's own `_meta` envelope is
    # the signal. Both are needed because `StdioTransport` locks the era only after a response succeeds,
    # which would otherwise let the first request of a connection reach a method the modern lifecycle does not have.
    # The Python SDK gates the same way, on the envelope of each request rather than on connection state that
    # is only settled afterwards.
    #
    # A legacy-locked session is deliberately excluded: `lift_request_envelope` answers a modern envelope there
    # with the lifecycle violation, which names the cause better than Method not found.
    def modern_request?(request, session)
      era = session.respond_to?(:era) ? session.era : nil
      return true if era == :modern
      return false unless era.nil?

      RequestEnvelope.modern?(request.is_a?(Hash) ? request[:params] : nil)
    end

    # Lifts the SEP-2575 per-request `_meta` envelope for modern requests. Only a request whose `_meta` carries
    # the full required triple is classified as modern; a partial triple keeps flowing through the legacy path untouched.
    # Notifications carry no envelope (their `_meta` is a `NotificationMetaObject`), and `server/discover` is
    # pre-version discovery, so both are exempt. Era-locked sessions additionally enforce the dual-era rules:
    # on a modern session, `initialize` is rejected with `-32022` (the modern lifecycle has no handshake)
    # and the triple becomes required for every other request; on a legacy session, a modern envelope is rejected as
    # an invalid request because a connection can never change eras.
    def lift_request_envelope(params, method:, session:)
      return if Methods.notification?(method)

      era = session.respond_to?(:era) ? session.era : nil

      # Outside the modern era, `server/discover` stays envelope-exempt so legacy connections can probe capabilities
      # before any negotiation. Under the modern era every request carries the envelope, discovery included:
      # the conformance suite's 2026-07-28 requirements reject an envelope-less `server/discover` with `-32602` (SEP-2575).
      return if method == Methods::SERVER_DISCOVER && era != :modern

      if RequestEnvelope.modern?(params)
        if era == :legacy
          raise RequestHandlerError.new(
            "Invalid Request: the session already negotiated the legacy lifecycle via `initialize`",
            params,
            error_type: :invalid_request,
          )
        end

        RequestEnvelope.parse!(params, request: params)
      elsif era == :modern
        # A claim-less request on a modern session is a malformed envelope, not a malformed request:
        # the spec maps missing required envelope fields to Invalid params (`-32602`),
        # and the reference SDKs answer it naming the missing keys.
        raise RequestHandlerError.new(
          "Invalid params: missing or invalid `#{RequestEnvelope::REQUIRED_META_KEYS.join("`, `")}` in `_meta`",
          params,
          error_type: :invalid_params,
          error_code: JsonRpcHandler::ErrorCode::INVALID_PARAMS,
        )
      end
    end

    # Central gate and serializer for SEP-2322 `input_required` results, run once in the dispatch lambda for
    # whichever handler produced one. The result type exists only in the 2026-07-28 stateless lifecycle,
    # so a legacy request (no envelope) must not receive it: pre-2026 clients treat an unknown `resultType` as
    # a final result. The capability gate enforces the SEP-2575 rule that servers MUST NOT rely on
    # (or embed requests for) capabilities the client did not declare, and reports every missing capability at
    # once so the client sees the full set.
    def serialize_input_required_result(result, envelope:, request:, method:)
      if envelope.nil?
        raise RequestHandlerError.new(
          "input_required results require the 2026-07-28 stateless lifecycle (SEP-2322)",
          request,
          error_type: :internal_error,
        )
      end

      missing = result.missing_client_capabilities(envelope.client_capabilities)
      raise MissingRequiredClientCapabilityError.new(missing, request) unless missing.empty?

      add_instrumentation_data(input_required: true)
      serialized = result.to_h

      if @request_state_security && serialized[:requestState]
        serialized = serialized.merge(requestState: @request_state_security.seal(
          serialized[:requestState],
          method: method,
          target: mrtr_target(request),
          arguments_digest: mrtr_arguments_digest(request),
        ))
      end

      serialized
    end

    # Methods whose results may be `input_required` and whose retried requests carry
    # `inputResponses`/`requestState` (SEP-2322).
    MRTR_METHODS = [Methods::TOOLS_CALL, Methods::PROMPTS_GET, Methods::RESOURCES_READ].freeze

    # Fulfilment rounds the legacy shim runs before giving up, matching the TypeScript SDK's legacy shim default (`maxRounds: 8`).
    LEGACY_INPUT_REQUIRED_MAX_ROUNDS = 8

    # Dual-era authoring shim (SEP-2322): a handler on the legacy wire returned an `input_required` result,
    # which pre-2026 clients cannot understand, so the server fulfills it in place of the client's driver.
    # Every entry of `inputRequests` is sent as the equivalent real server-to-client request (associated with
    # the originating request per SEP-2260), the answers are collected under the same keys, and the handler
    # re-runs with `inputResponses`/`requestState` merged into the original params - the same deterministic replay
    # contract the modern client driver follows. The `requestState` round-trips in-process as the raw value
    # the handler wrote; `RequestStateSecurity` sealing is wire hardening and does not apply.
    def run_legacy_input_required_shim(result, method:, params:, session:, related_request_id:, cancellation:)
      rounds = 0

      loop do
        missing = result.missing_client_capabilities(session.client_capabilities)
        unless missing.empty?
          # The explicit `error_code` keeps the descriptive message in the JSON-RPC error response
          # (the `ResourceNotFoundError` pattern). `-32021` is a 2026-07-28 code, so the legacy wire
          # gets a plain internal error.
          raise RequestHandlerError.new(
            "input_required requires client capabilities the client did not declare: #{missing.to_json}",
            params,
            error_type: :internal_error,
            error_code: JsonRpcHandler::ErrorCode::INTERNAL_ERROR,
          )
        end

        responses = (result.input_requests || {}).each_with_object({}) do |(key, entry), collected|
          collected[key] = session.fulfill_input_request(
            entry[:method],
            legacy_leg_params(entry),
            related_request_id: related_request_id,
          )
        end

        retry_params = params.reject { |key, _| [:inputResponses, :requestState].include?(key.to_sym) }
        retry_params[:inputResponses] = responses unless responses.empty?
        retry_params[:requestState] = result.request_state if result.request_state

        result = redispatch_mrtr_method(
          method,
          retry_params,
          session: session,
          related_request_id: related_request_id,
          cancellation: cancellation,
        )
        return result unless result.is_a?(InputRequiredResult)

        rounds += 1
        next if rounds < LEGACY_INPUT_REQUIRED_MAX_ROUNDS

        raise RequestHandlerError.new(
          "Handler still returned `input_required` after #{LEGACY_INPUT_REQUIRED_MAX_ROUNDS} legacy shim rounds (SEP-2322)",
          params,
          error_type: :internal_error,
          error_code: JsonRpcHandler::ErrorCode::INTERNAL_ERROR,
        )
      end
    end

    # The params an embedded entry sends on its legacy leg. Entries are forwarded verbatim with
    # one exception: the 2025-11-25 wire requires `elicitationId` on URL-mode elicitation requests,
    # a field the 2026-07-28 in-band shape dropped (correlation rides `requestState` there),
    # so a missing one is synthesized for the leg, matching the TypeScript SDK's shim.
    def legacy_leg_params(entry)
      params = entry[:params]
      return params unless entry[:method] == Methods::ELICITATION_CREATE
      return params if params.nil? || (params[:mode] || params["mode"]) != "url"
      return params if params.key?(:elicitationId) || params.key?("elicitationId")

      params.merge(elicitationId: SecureRandom.uuid)
    end

    # Re-runs the handler of one of the three MRTR-capable methods for
    # the legacy shim. Legacy wire, so no envelope is threaded.
    def redispatch_mrtr_method(method, params, session:, related_request_id:, cancellation:)
      case method
      when Methods::TOOLS_CALL
        call_tool(params, session: session, related_request_id: related_request_id, cancellation: cancellation)
      when Methods::PROMPTS_GET
        get_prompt(params, session: session, related_request_id: related_request_id, cancellation: cancellation)
      when Methods::RESOURCES_READ
        contents = read_resource_contents(params, session: session, related_request_id: related_request_id, cancellation: cancellation)
        contents.is_a?(InputRequiredResult) ? contents : build_read_resource_result(contents)
      else
        raise RequestHandlerError.new(
          "input_required results are only supported for #{MRTR_METHODS.join(", ")}",
          params,
          error_type: :internal_error,
        )
      end
    end

    # Replaces a sealed client-echoed `requestState` with its verified plaintext before dispatch,
    # so handlers always read the state they wrote. A tampered, expired, or cross-request token is
    # rejected as invalid params, matching the Python SDK's "Invalid or expired requestState" behavior.
    def unseal_request_state(params, method:)
      return params unless MRTR_METHODS.include?(method)
      return params unless params.is_a?(Hash)

      sealed = params[:requestState] || params["requestState"]
      return params unless sealed

      plaintext = @request_state_security.unseal(
        sealed,
        method: method,
        target: mrtr_target(params),
        arguments_digest: mrtr_arguments_digest(params),
      )
      key = params.key?("requestState") ? "requestState" : :requestState
      params.merge(key => plaintext)
    rescue RequestStateSecurity::InvalidStateError => e
      raise RequestHandlerError.new(
        "Invalid or expired requestState",
        params,
        error_type: :invalid_params,
        error_code: JsonRpcHandler::ErrorCode::INVALID_PARAMS,
        original_error: e,
      )
    end

    def mrtr_target(params)
      return "" unless params.is_a?(Hash)

      params[:name] || params["name"] || params[:uri] || params["uri"] || ""
    end

    # Digest of the originating arguments, binding a sealed state to retries of
    # the same call with the same inputs. Keys are stringified and sorted recursively
    # so symbol/string parses of identical JSON digest identically.
    def mrtr_arguments_digest(params)
      arguments = params.is_a?(Hash) ? params[:arguments] || params["arguments"] : nil
      OpenSSL::Digest::SHA256.hexdigest(canonical_json(arguments || {}))
    end

    def canonical_json(value)
      case value
      when Hash
        pairs = value.map { |key, nested| [key.to_s, nested] }.sort_by(&:first)
        "{#{pairs.map { |key, nested| "#{key.to_json}:#{canonical_json(nested)}" }.join(",")}}"
      when Array
        "[#{value.map { |element| canonical_json(element) }.join(",")}]"
      else
        value.to_json
      end
    end

    # Extracts the SEP-2322 retry fields a client sends when re-issuing a request:
    # `inputResponses` (answers keyed like the earlier `inputRequests`) and the echoed opaque `requestState`.
    # They are params-top-level siblings of `name`/`arguments`/ `uri`, not `_meta` entries.
    def mrtr_retry_fields(params)
      return { input_responses: nil, request_state: nil } unless params.is_a?(Hash)

      {
        input_responses: params[:inputResponses] || params["inputResponses"],
        request_state: params[:requestState] || params["requestState"],
      }
    end

    def handle_cancelled_notification(params, session: nil)
      return unless session
      return unless params.is_a?(Hash)

      request_id = params[:requestId] || params["requestId"]
      return if request_id.nil?

      reason = params[:reason] || params["reason"]
      session.cancel_incoming(request_id: request_id, reason: reason)
    end

    def default_capabilities
      {
        tools: { listChanged: true },
        prompts: { listChanged: true },
        resources: { listChanged: true },
        logging: {},
      }
    end

    def server_info
      @server_info ||= {
        description: description,
        icons: icons&.then { |icons| icons.empty? ? nil : icons.map(&:to_h) },
        name: name,
        title: title,
        version: version,
        websiteUrl: website_url,
      }.compact
    end

    def init(params, session: nil)
      validate_initialize_params!(params)

      # MCP spec: the initialization phase MUST be the first interaction between client and server.
      # Reject duplicate `initialize` on an already-initialized session so the negotiated
      # client identity and capabilities cannot be silently overwritten.
      if session&.initialized?
        raise RequestHandlerError.new("Invalid Request: Server already initialized", params, error_type: :invalid_request)
      end

      if session
        session.store_client_info(client: params[:clientInfo], capabilities: params[:capabilities])
      else
        @client = params[:clientInfo]
        @client_capabilities = params[:capabilities]
      end
      protocol_version = params[:protocolVersion]

      # Per the SEP-2575 era model, `initialize` negotiates legacy protocol versions only: a modern version is
      # defined by carrying its own version on every request in `_meta`, with no handshake,
      # so asking `initialize` for one (or for a version this server does not know) is answered with
      # a counter-offer instead of an echo, matching the TypeScript and Python SDKs. Modern versions
      # stay reachable through `server/discover` and the per-request envelope. The counter-offer is
      # a configured `protocol_version` pin when one is set (`Configuration` only accepts handshake versions there),
      # and the latest handshake version otherwise.
      negotiated_version = if Configuration.handshake_protocol_version?(protocol_version)
        protocol_version
      elsif configuration.protocol_version?
        configuration.protocol_version
      else
        Configuration::LATEST_HANDSHAKE_PROTOCOL_VERSION
      end

      info = server_info.reject do |property|
        negotiated_version <= "2025-06-18" && UNSUPPORTED_PROPERTIES_UNTIL_2025_06_18.include?(property) ||
          negotiated_version <= "2025-03-26" && UNSUPPORTED_PROPERTIES_UNTIL_2025_03_26.include?(property)
      end

      response_instructions = instructions

      if negotiated_version == "2024-11-05"
        response_instructions = nil
      end

      if session
        session.mark_initialized!(protocol_version: negotiated_version)
      else
        @client_protocol_version = negotiated_version
      end

      {
        protocolVersion: negotiated_version,
        capabilities: capabilities,
        serverInfo: info,
        instructions: response_instructions,
      }.compact
    end

    def validate_resource_subscription_params!(params)
      unless params.is_a?(Hash) && params[:uri].is_a?(String)
        raise RequestHandlerError.new("Missing or invalid uri", params, error_type: :invalid_params)
      end
    end

    def validate_initialize_params!(params)
      unless params.is_a?(Hash)
        raise RequestHandlerError.new("Invalid params", params, error_type: :invalid_params)
      end

      unless params[:protocolVersion].is_a?(String)
        raise RequestHandlerError.new("Missing or invalid protocolVersion", params, error_type: :invalid_params)
      end

      unless params[:capabilities].is_a?(Hash)
        raise RequestHandlerError.new("Missing or invalid capabilities", params, error_type: :invalid_params)
      end

      client_info = params[:clientInfo]
      if !client_info.is_a?(Hash) || client_info[:name].nil? || client_info[:version].nil?
        raise RequestHandlerError.new("Missing or invalid clientInfo", params, error_type: :invalid_params)
      end
    end

    # Handles `server/discover` (MCP 2026-07-28, SEP-2575): sessionless capability discovery.
    # Unlike `init`, this is state-free and idempotent: it stores no client info, does not mark
    # the session initialized, and responds regardless of capability declarations or initialization state,
    # so clients can probe a server before (or instead of) `initialize`.
    #
    # `supportedVersions` advertises modern versions only, matching the TypeScript and Python SDKs:
    # legacy versions are negotiated via `initialize`, not selected from discovery. The `ttlMs`/`cacheScope`
    # cache hints are REQUIRED on `DiscoverResult` (unlike the opt-in SEP-2549 hints on list/read results),
    # so the spec defaults (`0` = immediately stale, `"private"` = per-authorization-context caching only)
    # fill in when the server was not configured with `ttl_ms`/`cache_scope`. The server identity rides
    # in the result `_meta` as the optional `io.modelcontextprotocol/serverInfo` stamp per the finalized
    # spec (PR #3002), unfiltered because discovery happens before version negotiation.
    # https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2575
    def discover(_request)
      {
        supportedVersions: Configuration::SUPPORTED_MODERN_PROTOCOL_VERSIONS,
        capabilities: discover_capabilities,
        instructions: instructions,
        _meta: { RequestEnvelope::SERVER_INFO_META_KEY => server_info },
      }.compact.merge(
        ttlMs: ttl_ms || 0,
        cacheScope: cache_scope || "private",
        # `server/discover` is exempt from the `_meta` envelope, so the central modern-result stamping does not see it;
        # `DiscoverResult` is still a 2026-07-28 result and carries the REQUIRED `resultType` directly.
        resultType: ResultType::COMPLETE,
      )
    end

    # Capabilities as advertised by `server/discover`. In the modern lifecycle, `listChanged` and `subscribe` flags
    # promise delivery over `subscriptions/listen` streams, so they are stripped when the transport does not serve that RPC
    # (e.g. stdio), matching the Python SDK's era-aware capability derivation.
    def discover_capabilities
      return capabilities if @transport.respond_to?(:serves_subscriptions_listen?) && @transport.serves_subscriptions_listen?

      capabilities.each_with_object({}) do |(name, value), stripped|
        stripped[name] = if value.is_a?(Hash)
          value.reject { |flag, _| ["listChanged", "subscribe"].include?(flag.to_s) }
        else
          value
        end
      end
    end

    def configure_logging_level(request, session: nil)
      if capabilities[:logging].nil?
        raise RequestHandlerError.new("Server does not support logging", request, error_type: :internal_error)
      end

      logging_message_notification = LoggingMessageNotification.new(level: request[:level])
      unless logging_message_notification.valid_level?
        raise RequestHandlerError.new("Invalid log level #{request[:level]}", request, error_type: :invalid_params)
      end

      session&.configure_logging(logging_message_notification)
      @logging_message_notification = logging_message_notification

      {}
    end

    def list_tools(request)
      page = paginate(@tools.values, cursor: cursor_from(request), page_size: @page_size, request: request, &:to_h)

      apply_cache_metadata({ tools: page[:items], nextCursor: page[:next_cursor] }.compact)
    end

    def call_tool(request, session: nil, related_request_id: nil, cancellation: nil, envelope: nil)
      tool_name = request[:name]

      tool = tools[tool_name]
      unless tool
        add_instrumentation_data(tool_name: tool_name, error: :tool_not_found)

        raise RequestHandlerError.new("Tool not found: #{tool_name}", request, error_type: :invalid_params)
      end

      arguments = request[:arguments] || {}
      add_instrumentation_data(tool_name: tool_name, tool_arguments: arguments)

      if tool.input_schema&.missing_required_arguments?(arguments)
        add_instrumentation_data(error: :missing_required_arguments)

        missing = tool.input_schema.missing_required_arguments(arguments).join(", ")
        return error_tool_response("Missing required arguments: #{missing}")
      end

      if configuration.validate_tool_call_arguments && tool.input_schema
        begin
          tool.input_schema.validate_arguments(arguments)
        rescue Tool::InputSchema::ValidationError => e
          add_instrumentation_data(error: :invalid_schema)

          return error_tool_response(e.message)
        end
      end

      progress_token = request.dig(:_meta, :progressToken)

      response = call_tool_with_args(
        tool,
        arguments,
        server_context_with_meta(request),
        progress_token: progress_token,
        session: session,
        related_request_id: related_request_id,
        cancellation: cancellation,
        envelope: envelope,
        retry_fields: mrtr_retry_fields(request),
      )
      # An SEP-2322 `input_required` result is not a tool result: output schema
      # validation would run against a `nil` `structuredContent` and the structured
      # content fallback does not apply. The dispatch lambda serializes it.
      return response if response.is_a?(InputRequiredResult)

      result = response.to_h
      validate_tool_call_result!(tool, result)
      serialize_structured_content_fallback(
        result,
        content_provided: response.respond_to?(:content_provided?) && response.content_provided?,
      )
    rescue RequestHandlerError, CancelledError
      # CancelledError is intentionally not wrapped so `handle_request` can turn it into
      # `JsonRpcHandler::NO_RESPONSE` per the MCP cancellation spec.
      raise
    rescue => e
      # `e.message` is deliberately not included: it can carry internals (class, method
      # and host names) that must not reach untrusted clients (CWE-209). The original
      # exception still reaches `configuration.exception_reporter` via `original_error`.
      raise RequestHandlerError.new(
        "Internal error calling tool #{tool_name}",
        request,
        error_type: :internal_error,
        original_error: e,
      )
    end

    def list_prompts(request)
      page = paginate(@prompts.values, cursor: cursor_from(request), page_size: @page_size, request: request, &:to_h)

      apply_cache_metadata({ prompts: page[:items], nextCursor: page[:next_cursor] }.compact)
    end

    def get_prompt(request, session: nil, related_request_id: nil, cancellation: nil, envelope: nil)
      prompt_name = request[:name]
      prompt = @prompts[prompt_name]
      unless prompt
        add_instrumentation_data(error: :prompt_not_found)
        # The explicit `error_code` maps an unknown prompt to Invalid Params (-32602) rather than
        # the default Internal Error (-32603), matching the `tools/call`, `resources/read`, and
        # `completion/complete` siblings for the same not-found condition, while `error_type:
        # :prompt_not_found` keeps the descriptive message and instrumentation label.
        raise RequestHandlerError.new(
          "Prompt not found #{prompt_name}",
          request,
          error_type: :prompt_not_found,
          error_code: JsonRpcHandler::ErrorCode::INVALID_PARAMS,
        )
      end

      add_instrumentation_data(prompt_name: prompt_name)

      prompt_args = request[:arguments]
      prompt.validate_arguments!(prompt_args)

      server_context = build_server_context(
        request: request,
        session: session,
        related_request_id: related_request_id,
        cancellation: cancellation,
        envelope: envelope,
      )

      call_prompt_template_with_args(prompt, prompt_args, server_context)
    end

    def list_resources(request)
      page = paginate(@resources, cursor: cursor_from(request), page_size: @page_size, request: request, &:to_h)

      apply_cache_metadata({ resources: page[:items], nextCursor: page[:next_cursor] }.compact)
    end

    # Default `resources/read` handler: routes to class-based resources and resource templates.
    # Fully replaced when `resources_read_handler` is set. When no class-based resource or template is registered,
    # unknown URIs keep the historical no-op `[]` response instead of raising.
    def read_resource(request, server_context: nil)
      uri = request[:uri]
      add_instrumentation_data(resource_uri: uri)

      resource = @resource_index[uri]
      if resource.is_a?(Class)
        return normalize_resource_contents(call_resource_contents(resource, server_context))
      end

      @resource_templates.each do |template|
        next unless template.is_a?(Class)

        params = template.match_uri(uri)
        next unless params

        add_instrumentation_data(resource_template: template.uri_template)
        return normalize_resource_contents(call_template_contents(template, params, server_context))
      end

      return [] unless class_based_resources_registered?

      raise ResourceNotFoundError.new(uri, request)
    end

    def call_resource_contents(resource, server_context)
      if accepts_server_context?(resource.method(:contents))
        resource.contents(server_context: server_context)
      else
        resource.contents
      end
    end

    def call_template_contents(template, params, server_context)
      if accepts_server_context?(template.method(:contents))
        template.contents(**params, server_context: server_context)
      else
        template.contents(**params)
      end
    end

    def normalize_resource_contents(result)
      contents = result.is_a?(Array) ? result : [result]
      contents.map(&:to_h)
    end

    def class_based_resources_registered?
      @resources.any? { |resource| resource.is_a?(Class) } ||
        @resource_templates.any? { |template| template.is_a?(Class) }
    end

    def list_resource_templates(request)
      page = paginate(@resource_templates, cursor: cursor_from(request), page_size: @page_size, request: request, &:to_h)

      apply_cache_metadata({ resourceTemplates: page[:items], nextCursor: page[:next_cursor] }.compact)
    end

    # Builds the `resources/read` result. The documented handler contract is "return value becomes `contents`";
    # a Hash with a `:contents` key is also accepted as a full result so a handler can override the server-level
    # `ttlMs`/`cacheScope` cache hints per result (SEP-2549).
    def build_read_resource_result(handler_result)
      result = if handler_result.is_a?(Hash) && handler_result.key?(:contents)
        handler_result
      else
        { contents: handler_result }
      end

      apply_cache_metadata(result)
    end

    # Adds the SEP-2549 cache hints (`ttlMs`, `cacheScope`) to a result. Emission is opt-in: nothing is added
    # unless the server was configured with `ttl_ms`/`cache_scope` or the result already carries one of the fields,
    # in which case the missing one is filled with `ttlMs: 0` (do not cache) or `cacheScope: "private"`,
    # the side that cannot leak a user-dependent result through a shared cache (the TypeScript SDK's default).
    # Values already in the result win, enabling per-result overrides.
    # https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2549
    def apply_cache_metadata(result)
      explicit = result.key?(:ttlMs) || result.key?(:cacheScope)
      return result if @ttl_ms.nil? && @cache_scope.nil? && !explicit

      { ttlMs: @ttl_ms || 0, cacheScope: @cache_scope || "private" }.merge(result)
    end

    def complete(params, session: nil, related_request_id: nil, cancellation: nil, envelope: nil)
      validate_completion_params!(params)

      result = dispatch_optional_context_handler(
        @handlers[Methods::COMPLETION_COMPLETE],
        params,
        session: session,
        related_request_id: related_request_id,
        cancellation: cancellation,
        envelope: envelope,
      )

      normalize_completion_result(result)
    end

    # Invokes `resources/read` via the registered handler. If the handler block opts in to `server_context:`,
    # pass an `MCP::ServerContext` so the handler can observe cancellation via `server_context.cancelled?` or
    # `server_context.raise_if_cancelled!`.
    def read_resource_contents(request, session: nil, related_request_id: nil, cancellation: nil, envelope: nil)
      dispatch_optional_context_handler(
        @handlers[Methods::RESOURCES_READ],
        request,
        session: session,
        related_request_id: related_request_id,
        cancellation: cancellation,
        envelope: envelope,
      )
    end

    # Opt-in `server_context:` dispatch for block-based handlers registered via `resources_read_handler`,
    # `completion_handler`, `resources_subscribe_handler`, `resources_unsubscribe_handler`, or `define_custom_method`.
    # Existing handlers that only accept `params` are called unchanged; handlers that declare a `server_context:`
    # keyword receive an `MCP::ServerContext` wrapping the raw server context with cancellation plumbing.
    def dispatch_optional_context_handler(handler, params, session: nil, related_request_id: nil, cancellation: nil, envelope: nil)
      return handler.call(params) unless handler_declares_server_context?(handler)

      server_context = build_server_context(
        request: params,
        session: session,
        related_request_id: related_request_id,
        cancellation: cancellation,
        envelope: envelope,
      )
      handler.call(params, server_context: server_context)
    end

    # Stricter than `accepts_server_context?`: requires `server_context` to appear as a named keyword parameter
    # (`:key` optional, `:keyreq` required). Positional parameters named `server_context` (`:req` / `:opt`) are NOT
    # treated as opt-in - otherwise `handler.call(params, server_context: ctx)` would pass the `{server_context: ctx}`
    # Hash as the handler's second positional argument, which is never what the user meant.
    #
    # `**kwargs`-only signatures (`:keyrest` without a named `server_context`) are also not opt-in here,
    # because the dispatch site passes a positional `params`, and a `**kwargs`-only block cannot accept
    # that positional argument (lambdas/methods raise `ArgumentError`; non-lambda procs silently drop `params`).
    # Tool handlers intentionally allow `**kwargs` opt-in via `accepts_server_context?` because they are invoked
    # via `tool.call(**args, server_context: …)` without a positional argument.
    def handler_declares_server_context?(handler)
      return false unless handler.respond_to?(:parameters)

      handler.parameters.any? do |type, name|
        name == :server_context && (type == :key || type == :keyreq)
      end
    end

    # Builds an `MCP::ServerContext` used to give a handler access to session-scoped helpers
    # (progress, cancellation, nested server-to-client requests).
    def build_server_context(request:, session:, related_request_id:, cancellation:, envelope: nil)
      meta_source = request.is_a?(Hash) ? request : {}
      progress_token = meta_source.dig(:_meta, :progressToken)
      progress = Progress.new(notification_target: session, progress_token: progress_token, related_request_id: related_request_id)
      retry_fields = mrtr_retry_fields(meta_source)
      ServerContext.new(
        server_context_with_meta(meta_source),
        progress: progress,
        notification_target: session,
        related_request_id: related_request_id,
        cancellation: cancellation,
        envelope: envelope,
        input_responses: retry_fields[:input_responses],
        request_state: retry_fields[:request_state],
      )
    end

    def report_exception(exception, server_context = {})
      configuration.exception_reporter.call(exception, server_context)
    end

    def index_resources_by_uri(resources)
      resources.to_h { |resource| [resource.uri, resource] }
    end

    def error_tool_response(text)
      Tool::Response.new(
        [{
          type: "text",
          text: text,
        }],
        error: true,
      ).to_h
    end

    def validate_tool_call_result!(tool, result)
      return unless configuration.validate_tool_call_results
      return unless tool.output_schema
      return if result[:isError]

      tool.output_schema.validate_result(result[:structuredContent])
    end

    # Per SEP-2106, `structuredContent` may be any JSON value, not only an object.
    # Clients on older protocol versions may only read `content`,
    # so when a tool returns non-object structured content without explicitly
    # providing `content`, mirror the value into serialized JSON text.
    def serialize_structured_content_fallback(result, content_provided: false)
      structured = result[:structuredContent]
      return result if structured.nil? || structured.is_a?(Hash)
      return result if content_provided
      return result unless result[:content].nil? || result[:content].empty?

      serialized = JSON.generate(structured)
      return result if JSON.parse(serialized).is_a?(Hash)

      result.merge(content: [{ type: "text", text: serialized }])
    end

    # Whether a tool/prompt handler opts in to receiving an `MCP::ServerContext`.
    # Recognizes `:keyrest` (`**kwargs`) because tools are invoked without a positional argument
    # (`tool.call(**args, server_context:)`), soa `**kwargs`-only signature safely captures `server_context:`.
    # Named keyword `server_context` must be `:key` or `:keyreq` - positional parameters (`:req` / `:opt`) that
    # happen to be named `server_context` are excluded because the call site passes `server_context:` as a keyword,
    # and a positional slot would receive the `{server_context: ctx}` Hash instead.
    def accepts_server_context?(method_object)
      parameters = method_object.parameters

      parameters.any? do |type, name|
        type == :keyrest || (name == :server_context && (type == :key || type == :keyreq))
      end
    end

    def call_tool_with_args(tool, arguments, context, progress_token: nil, session: nil, related_request_id: nil, cancellation: nil, envelope: nil, retry_fields: nil)
      # Transports parse incoming JSON with `symbolize_names: true`, so `arguments` already arrives symbolized
      # at every nesting level. This top-level transform only guards callers that hand in string-keyed top-level arguments;
      # it does not recurse, and nested object keys remain symbols. Tools therefore receive symbol keys all the way down.
      # See docs/building-servers.md ("Tool argument keys").
      args = arguments&.transform_keys(&:to_sym) || {}

      if accepts_server_context?(tool.method(:call))
        progress = Progress.new(notification_target: session, progress_token: progress_token, related_request_id: related_request_id)
        server_context = ServerContext.new(
          context,
          progress: progress,
          notification_target: session,
          related_request_id: related_request_id,
          cancellation: cancellation,
          envelope: envelope,
          input_responses: retry_fields&.fetch(:input_responses, nil),
          request_state: retry_fields&.fetch(:request_state, nil),
        )
        tool.call(**args, server_context: server_context)
      else
        tool.call(**args)
      end
    end

    def call_prompt_template_with_args(prompt, args, server_context)
      raw_result = if accepts_server_context?(prompt.method(:template))
        prompt.template(args, server_context: server_context)
      else
        prompt.template(args)
      end

      raw_result.is_a?(InputRequiredResult) ? raw_result : raw_result.to_h
    end

    def server_context_with_meta(request)
      meta = request[:_meta]
      if meta && server_context.is_a?(Hash)
        context = server_context.dup
        context[:_meta] = meta
        context
      elsif meta && server_context.nil?
        { _meta: meta }
      else
        server_context
      end
    end

    def validate_completion_params!(params)
      unless params.is_a?(Hash)
        raise RequestHandlerError.new("Invalid params", params, error_type: :invalid_params)
      end

      ref = params[:ref]
      if ref.nil? || ref[:type].nil?
        raise RequestHandlerError.new("Missing or invalid ref", params, error_type: :invalid_params)
      end

      argument = params[:argument]
      if argument.nil? || argument[:name].nil? || !argument.key?(:value)
        raise RequestHandlerError.new("Missing argument name or value", params, error_type: :invalid_params)
      end

      case ref[:type]
      when "ref/prompt"
        unless @prompts[ref[:name]]
          raise RequestHandlerError.new("Prompt not found: #{ref[:name]}", params, error_type: :invalid_params)
        end
      when "ref/resource"
        uri = ref[:uri]
        found = @resource_index.key?(uri) || @resource_templates.any? { |t| t.uri_template == uri }
        unless found
          raise ResourceNotFoundError.new(uri, params)
        end
      else
        raise RequestHandlerError.new("Invalid ref type: #{ref[:type]}", params, error_type: :invalid_params)
      end
    end

    def normalize_completion_result(result)
      return DEFAULT_COMPLETION_RESULT unless result.is_a?(Hash)

      completion = result[:completion] || result["completion"]
      return DEFAULT_COMPLETION_RESULT unless completion.is_a?(Hash)

      values = completion[:values] || completion["values"] || []
      total = completion[:total] || completion["total"]
      has_more = completion[:hasMore] || completion["hasMore"] || false

      count = values.length
      if count > MAX_COMPLETION_VALUES
        has_more = true
        total ||= count
        values = values.first(MAX_COMPLETION_VALUES)
      end

      { completion: { values: values, total: total, hasMore: has_more }.compact }
    end
  end
end
