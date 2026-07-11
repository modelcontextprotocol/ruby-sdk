# frozen_string_literal: true

require_relative "../json_rpc_handler"
require_relative "cancellation"
require_relative "cancelled_error"
require_relative "instrumentation"
require_relative "methods"
require_relative "logging_message_notification"
require_relative "progress"
require_relative "server_context"
require_relative "server/capabilities"
require_relative "server/pagination"
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

    attr_accessor :description, :icons, :name, :title, :version, :website_url, :instructions, :tools, :prompts, :resource_templates, :server_context, :configuration, :capabilities, :transport, :logging_message_notification
    attr_reader :resources, :page_size, :client_capabilities, :ttl_ms, :cache_scope

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
      @configuration = MCP.configuration.merge(configuration)
      @client = nil

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

      Methods.ensure_capability!(method, capabilities)

      # `initialize` MUST NOT be cancelled (MCP spec 2025-11-25, cancellation item 2),
      # so do not track it in the in-flight registry.
      cancellation = if related_request_id && method != Methods::INITIALIZE
        session&.register_in_flight(related_request_id)
      end

      ->(params) {
        reported_exception = nil
        instrument_call(
          method,
          server_context: { request: request },
          exception_already_reported: ->(e) { reported_exception.equal?(e) },
        ) do
          result = case method
          when Methods::INITIALIZE
            init(params, session: session)
          when Methods::RESOURCES_READ
            build_read_resource_result(read_resource_contents(params, session: session, related_request_id: related_request_id, cancellation: cancellation))
          when Methods::RESOURCES_SUBSCRIBE, Methods::RESOURCES_UNSUBSCRIBE
            validate_resource_subscription_params!(params)
            dispatch_optional_context_handler(@handlers[method], params, session: session, related_request_id: related_request_id, cancellation: cancellation)
            {}
          when Methods::TOOLS_CALL
            call_tool(params, session: session, related_request_id: related_request_id, cancellation: cancellation)
          when Methods::PROMPTS_GET
            get_prompt(params, session: session, related_request_id: related_request_id, cancellation: cancellation)
          when Methods::COMPLETION_COMPLETE
            complete(params, session: session, related_request_id: related_request_id, cancellation: cancellation)
          when Methods::LOGGING_SET_LEVEL
            configure_logging_level(params, session: session)
          else
            dispatch_optional_context_handler(@handlers[method], params, session: session, related_request_id: related_request_id, cancellation: cancellation)
          end
          client = session&.client || @client
          add_instrumentation_data(client: client) if client

          if cancellation&.cancelled?
            add_instrumentation_data(cancelled: true, cancellation_reason: cancellation.reason)
            next JsonRpcHandler::NO_RESPONSE
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
          session&.unregister_in_flight(related_request_id) if related_request_id
        end
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

      negotiated_version = if Configuration::SUPPORTED_STABLE_PROTOCOL_VERSIONS.include?(protocol_version)
        protocol_version
      else
        configuration.protocol_version
      end

      info = server_info.reject do |property|
        negotiated_version <= "2025-06-18" && UNSUPPORTED_PROPERTIES_UNTIL_2025_06_18.include?(property) ||
          negotiated_version <= "2025-03-26" && UNSUPPORTED_PROPERTIES_UNTIL_2025_03_26.include?(property)
      end

      response_instructions = instructions

      if negotiated_version == "2024-11-05"
        response_instructions = nil
      end

      session&.mark_initialized!

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

    # Handles `server/discover` (MCP 2026-07-28 draft, SEP-2575): sessionless capability discovery.
    # Unlike `init`, this is state-free and idempotent: it stores no client info, does not mark
    # the session initialized, and responds regardless of capability declarations or initialization state,
    # so clients can probe a server before (or instead of) `initialize`. `serverInfo` is returned unfiltered
    # because discovery happens before version negotiation. The draft's `ttlMs`/`cacheScope` cache hints
    # are not included here yet.
    # https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2575
    def discover(_request)
      {
        supportedVersions: Configuration::SUPPORTED_STABLE_PROTOCOL_VERSIONS,
        capabilities: capabilities,
        serverInfo: server_info,
        instructions: instructions,
      }.compact
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

    def call_tool(request, session: nil, related_request_id: nil, cancellation: nil)
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

      result = call_tool_with_args(
        tool, arguments, server_context_with_meta(request), progress_token: progress_token, session: session, related_request_id: related_request_id, cancellation: cancellation
      )
      validate_tool_call_result!(tool, result)
      serialize_structured_content_fallback(result)
    rescue RequestHandlerError, CancelledError
      # CancelledError is intentionally not wrapped so `handle_request` can turn it into
      # `JsonRpcHandler::NO_RESPONSE` per the MCP cancellation spec.
      raise
    rescue => e
      raise RequestHandlerError.new(
        "Internal error calling tool #{tool_name}: #{e.message}",
        request,
        error_type: :internal_error,
        original_error: e,
      )
    end

    def list_prompts(request)
      page = paginate(@prompts.values, cursor: cursor_from(request), page_size: @page_size, request: request, &:to_h)

      apply_cache_metadata({ prompts: page[:items], nextCursor: page[:next_cursor] }.compact)
    end

    def get_prompt(request, session: nil, related_request_id: nil, cancellation: nil)
      prompt_name = request[:name]
      prompt = @prompts[prompt_name]
      unless prompt
        add_instrumentation_data(error: :prompt_not_found)
        raise RequestHandlerError.new("Prompt not found #{prompt_name}", request, error_type: :prompt_not_found)
      end

      add_instrumentation_data(prompt_name: prompt_name)

      prompt_args = request[:arguments]
      prompt.validate_arguments!(prompt_args)

      server_context = build_server_context(
        request: request,
        session: session,
        related_request_id: related_request_id,
        cancellation: cancellation,
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
    # unless the server was configured with `ttl_ms`/`cache_scope` or the result already carries one of the fields, in
    # which case the missing one is filled with the spec defaults (`ttlMs: 0` = do not cache, `cacheScope: "public"`).
    # Values already in the result win, enabling per-result overrides.
    # https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2549
    def apply_cache_metadata(result)
      explicit = result.key?(:ttlMs) || result.key?(:cacheScope)
      return result if @ttl_ms.nil? && @cache_scope.nil? && !explicit

      { ttlMs: @ttl_ms || 0, cacheScope: @cache_scope || "public" }.merge(result)
    end

    def complete(params, session: nil, related_request_id: nil, cancellation: nil)
      validate_completion_params!(params)

      result = dispatch_optional_context_handler(
        @handlers[Methods::COMPLETION_COMPLETE],
        params,
        session: session,
        related_request_id: related_request_id,
        cancellation: cancellation,
      )

      normalize_completion_result(result)
    end

    # Invokes `resources/read` via the registered handler. If the handler block opts in to `server_context:`,
    # pass an `MCP::ServerContext` so the handler can observe cancellation via `server_context.cancelled?` or
    # `server_context.raise_if_cancelled!`.
    def read_resource_contents(request, session: nil, related_request_id: nil, cancellation: nil)
      dispatch_optional_context_handler(
        @handlers[Methods::RESOURCES_READ],
        request,
        session: session,
        related_request_id: related_request_id,
        cancellation: cancellation,
      )
    end

    # Opt-in `server_context:` dispatch for block-based handlers registered via `resources_read_handler`,
    # `completion_handler`, `resources_subscribe_handler`, `resources_unsubscribe_handler`, or `define_custom_method`.
    # Existing handlers that only accept `params` are called unchanged; handlers that declare a `server_context:`
    # keyword receive an `MCP::ServerContext` wrapping the raw server context with cancellation plumbing.
    def dispatch_optional_context_handler(handler, params, session: nil, related_request_id: nil, cancellation: nil)
      return handler.call(params) unless handler_declares_server_context?(handler)

      server_context = build_server_context(
        request: params,
        session: session,
        related_request_id: related_request_id,
        cancellation: cancellation,
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
    def build_server_context(request:, session:, related_request_id:, cancellation:)
      meta_source = request.is_a?(Hash) ? request : {}
      progress_token = meta_source.dig(:_meta, :progressToken)
      progress = Progress.new(notification_target: session, progress_token: progress_token, related_request_id: related_request_id)
      ServerContext.new(
        server_context_with_meta(meta_source),
        progress: progress,
        notification_target: session,
        related_request_id: related_request_id,
        cancellation: cancellation,
      )
    end

    def report_exception(exception, server_context = {})
      configuration.exception_reporter.call(exception, server_context)
    end

    def index_resources_by_uri(resources)
      resources.each_with_object({}) do |resource, hash|
        hash[resource.uri] = resource
      end
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
    # so when a tool returns non-object structured content without providing
    # any content blocks, mirror the value into `content` as serialized JSON text.
    def serialize_structured_content_fallback(result)
      structured = result[:structuredContent]
      return result if structured.nil? || structured.is_a?(Hash)
      return result unless result[:content].nil? || result[:content].empty?

      result.merge(content: [{ type: "text", text: JSON.generate(structured) }])
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

    def call_tool_with_args(tool, arguments, context, progress_token: nil, session: nil, related_request_id: nil, cancellation: nil)
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
        )
        tool.call(**args, server_context: server_context).to_h
      else
        tool.call(**args).to_h
      end
    end

    def call_prompt_template_with_args(prompt, args, server_context)
      if accepts_server_context?(prompt.method(:template))
        prompt.template(args, server_context: server_context).to_h
      else
        prompt.template(args).to_h
      end
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
