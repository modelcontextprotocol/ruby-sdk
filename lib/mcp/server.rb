# frozen_string_literal: true

require_relative "../json_rpc_handler"
require_relative "instrumentation"
require_relative "methods"
require_relative "logging_message_notification"
require_relative "progress"
require_relative "server_context"
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

    class MethodAlreadyDefinedError < StandardError
      attr_reader :method_name

      def initialize(method_name)
        super("Method #{method_name} already defined")
        @method_name = method_name
      end
    end

    include Instrumentation

    attr_accessor :description, :icons, :name, :title, :version, :website_url, :instructions, :tools, :prompts, :resources, :server_context, :configuration, :capabilities, :transport, :logging_message_notification
    attr_reader :client_capabilities

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
      @configuration = MCP.configuration.merge(configuration)
      @client = nil

      validate!

      @capabilities = capabilities || default_capabilities
      @client_capabilities = nil
      @logging_message_notification = nil

      @handlers = {
        Methods::RESOURCES_LIST => method(:list_resources),
        Methods::RESOURCES_READ => method(:read_resource_no_content),
        Methods::RESOURCES_TEMPLATES_LIST => method(:list_resource_templates),
        Methods::TOOLS_LIST => method(:list_tools),
        Methods::TOOLS_CALL => method(:call_tool),
        Methods::PROMPTS_LIST => method(:list_prompts),
        Methods::PROMPTS_GET => method(:get_prompt),
        Methods::INITIALIZE => method(:init),
        Methods::PING => ->(_) { {} },
        Methods::NOTIFICATIONS_INITIALIZED => ->(_) {},
        Methods::NOTIFICATIONS_PROGRESS => ->(_) {},
        Methods::NOTIFICATIONS_ROOTS_LIST_CHANGED => ->(_) {},
        Methods::COMPLETION_COMPLETE => ->(_) { DEFAULT_COMPLETION_RESULT },
        Methods::LOGGING_SET_LEVEL => method(:configure_logging_level),

        # No op handlers for currently unsupported methods
        Methods::RESOURCES_SUBSCRIBE => ->(_) { {} },
        Methods::RESOURCES_UNSUBSCRIBE => ->(_) { {} },
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

    def define_tool(name: nil, title: nil, description: nil, input_schema: nil, annotations: nil, meta: nil, &block)
      tool = Tool.define(name: name, title: title, description: description, input_schema: input_schema, annotations: annotations, meta: meta, &block)
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

    def define_custom_method(method_name:, &block)
      if @handlers.key?(method_name)
        raise MethodAlreadyDefinedError, method_name
      end

      @handlers[method_name] = block
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
      handler = @handlers[method]
      unless handler
        instrument_call("unsupported_method", server_context: { request: request }) do
          client = session&.client || @client
          add_instrumentation_data(client: client) if client
        end
        return
      end

      Methods.ensure_capability!(method, capabilities)

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
          when Methods::TOOLS_LIST
            { tools: @handlers[Methods::TOOLS_LIST].call(params) }
          when Methods::PROMPTS_LIST
            { prompts: @handlers[Methods::PROMPTS_LIST].call(params) }
          when Methods::RESOURCES_LIST
            { resources: @handlers[Methods::RESOURCES_LIST].call(params) }
          when Methods::RESOURCES_READ
            { contents: @handlers[Methods::RESOURCES_READ].call(params) }
          when Methods::RESOURCES_TEMPLATES_LIST
            { resourceTemplates: @handlers[Methods::RESOURCES_TEMPLATES_LIST].call(params) }
          when Methods::TOOLS_CALL
            call_tool(params, session: session, related_request_id: related_request_id)
          when Methods::COMPLETION_COMPLETE
            complete(params)
          when Methods::LOGGING_SET_LEVEL
            configure_logging_level(params, session: session)
          else
            @handlers[method].call(params)
          end
          client = session&.client || @client
          add_instrumentation_data(client: client) if client

          result
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
        end
      }
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
      if params
        if session
          session.store_client_info(client: params[:clientInfo], capabilities: params[:capabilities])
        else
          @client = params[:clientInfo]
          @client_capabilities = params[:capabilities]
        end
        protocol_version = params[:protocolVersion]
      end

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

      {
        protocolVersion: negotiated_version,
        capabilities: capabilities,
        serverInfo: info,
        instructions: response_instructions,
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
      @tools.values.map(&:to_h)
    end

    def call_tool(request, session: nil, related_request_id: nil)
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
        raise RequestHandlerError.new("Missing required arguments: #{missing}", request, error_type: :invalid_params)
      end

      if configuration.validate_tool_call_arguments && tool.input_schema
        begin
          tool.input_schema.validate_arguments(arguments)
        rescue Tool::InputSchema::ValidationError => e
          add_instrumentation_data(error: :invalid_schema)

          raise RequestHandlerError.new(e.message, request, error_type: :invalid_params)
        end
      end

      progress_token = request.dig(:_meta, :progressToken)

      call_tool_with_args(tool, arguments, server_context_with_meta(request), progress_token: progress_token, session: session, related_request_id: related_request_id)
    rescue RequestHandlerError
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
      @prompts.values.map(&:to_h)
    end

    def get_prompt(request)
      prompt_name = request[:name]
      prompt = @prompts[prompt_name]
      unless prompt
        add_instrumentation_data(error: :prompt_not_found)
        raise RequestHandlerError.new("Prompt not found #{prompt_name}", request, error_type: :prompt_not_found)
      end

      add_instrumentation_data(prompt_name: prompt_name)

      prompt_args = request[:arguments]
      prompt.validate_arguments!(prompt_args)

      call_prompt_template_with_args(prompt, prompt_args, server_context_with_meta(request))
    end

    def list_resources(request)
      @resources.map(&:to_h)
    end

    # Server implementation should set `resources_read_handler` to override no-op default
    def read_resource_no_content(request)
      add_instrumentation_data(resource_uri: request[:uri])
      []
    end

    def list_resource_templates(request)
      @resource_templates.map(&:to_h)
    end

    def complete(params)
      validate_completion_params!(params)

      result = @handlers[Methods::COMPLETION_COMPLETE].call(params)

      normalize_completion_result(result)
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

    def accepts_server_context?(method_object)
      parameters = method_object.parameters

      parameters.any? { |type, name| type == :keyrest || name == :server_context }
    end

    def call_tool_with_args(tool, arguments, context, progress_token: nil, session: nil, related_request_id: nil)
      args = arguments&.transform_keys(&:to_sym) || {}

      if accepts_server_context?(tool.method(:call))
        progress = Progress.new(notification_target: session, progress_token: progress_token, related_request_id: related_request_id)
        server_context = ServerContext.new(context, progress: progress, notification_target: session, related_request_id: related_request_id)
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
          raise RequestHandlerError.new("Resource not found: #{uri}", params, error_type: :invalid_params)
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
