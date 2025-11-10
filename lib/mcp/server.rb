# frozen_string_literal: true

require_relative "../json_rpc_handler"
require_relative "instrumentation"
require_relative "methods"

module MCP
  class Server
    DEFAULT_VERSION = "0.1.0"

    class RequestHandlerError < StandardError
      attr_reader :error_type
      attr_reader :original_error

      def initialize(message, request, error_type: :internal_error, original_error: nil)
        super(message)
        @request = request
        @error_type = error_type
        @original_error = original_error
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

    attr_accessor :name, :title, :version, :instructions, :tools, :prompts, :resources, :server_context, :configuration, :capabilities, :transport

    def initialize(
      name: "model_context_protocol",
      title: nil,
      version: DEFAULT_VERSION,
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
      @name = name
      @title = title
      @version = version
      @instructions = instructions
      @tools = tools.to_h { |t| [t.name_value, t] }
      @prompts = prompts.to_h { |p| [p.name_value, p] }
      @resources = resources
      @resource_templates = resource_templates
      @resource_index = index_resources_by_uri(resources)
      @server_context = server_context
      @configuration = MCP.configuration.merge(configuration)

      validate!

      @capabilities = capabilities || default_capabilities

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

        # No op handlers for currently unsupported methods
        Methods::RESOURCES_SUBSCRIBE => ->(_) {},
        Methods::RESOURCES_UNSUBSCRIBE => ->(_) {},
        Methods::COMPLETION_COMPLETE => ->(_) {},
        Methods::LOGGING_SET_LEVEL => ->(_) {},
        Methods::ELICITATION_CREATE => ->(_) {},
      }
      @transport = transport
    end

    def handle(request)
      JsonRpcHandler.handle(request) do |method|
        handle_request(request, method)
      end
    end

    def handle_json(request)
      JsonRpcHandler.handle_json(request) do |method|
        handle_request(request, method)
      end
    end

    def define_tool(name: nil, title: nil, description: nil, input_schema: nil, annotations: nil, meta: nil, &block)
      tool = Tool.define(name:, title:, description:, input_schema:, annotations:, meta:, &block)
      @tools[tool.name_value] = tool

      validate!
    end

    def define_prompt(name: nil, title: nil, description: nil, arguments: [], &block)
      prompt = Prompt.define(name:, title:, description:, arguments:, &block)
      @prompts[prompt.name_value] = prompt
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

    def resources_list_handler(&block)
      @handlers[Methods::RESOURCES_LIST] = block
    end

    def resources_read_handler(&block)
      @handlers[Methods::RESOURCES_READ] = block
    end

    def resources_templates_list_handler(&block)
      @handlers[Methods::RESOURCES_TEMPLATES_LIST] = block
    end

    def tools_list_handler(&block)
      @handlers[Methods::TOOLS_LIST] = block
    end

    def tools_call_handler(&block)
      @handlers[Methods::TOOLS_CALL] = block
    end

    def prompts_list_handler(&block)
      @handlers[Methods::PROMPTS_LIST] = block
    end

    def prompts_get_handler(&block)
      @handlers[Methods::PROMPTS_GET] = block
    end

    private

    def validate!
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

    def handle_request(request, method)
      handler = @handlers[method]
      unless handler
        instrument_call("unsupported_method") {}
        return
      end

      Methods.ensure_capability!(method, capabilities)

      ->(params) {
        instrument_call(method) do
          case method
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
          else
            @handlers[method].call(params)
          end
        rescue => e
          report_exception(e, { request: request })
          if e.is_a?(RequestHandlerError)
            add_instrumentation_data(error: e.error_type)
            raise e
          end

          add_instrumentation_data(error: :internal_error)
          raise RequestHandlerError.new("Internal error handling #{method} request", request, original_error: e)
        end
      }
    end

    def default_capabilities
      {
        tools: { listChanged: true },
        prompts: { listChanged: true },
        resources: { listChanged: true },
      }
    end

    def server_info
      @server_info ||= {
        name:,
        title:,
        version:,
      }.compact
    end

    def init(request)
      {
        protocolVersion: configuration.protocol_version,
        capabilities: capabilities,
        serverInfo: server_info,
        instructions: instructions,
      }.compact
    end

    def list_tools(request)
      @tools.values.map(&:to_h)
    end

    def call_tool(request)
      tool_name = request[:name]

      tool = tools[tool_name]
      unless tool
        add_instrumentation_data(tool_name:, error: :tool_not_found)
        return Tool::Response.new(
          [{
            type: "text",
            text: "Tool not found: #{tool_name}",
          }],
          error: true,
        ).to_h
      end

      arguments = request[:arguments] || {}
      add_instrumentation_data(tool_name:)

      if tool.input_schema&.missing_required_arguments?(arguments)
        add_instrumentation_data(error: :missing_required_arguments)
        missing = tool.input_schema.missing_required_arguments(arguments).join(", ")
        return Tool::Response.new(
          [{
            type: "text",
            text: "Missing required arguments: #{missing}",
          }],
          error: true,
        ).to_h
      end

      if configuration.validate_tool_call_arguments && tool.input_schema
        begin
          tool.input_schema.validate_arguments(arguments)
        rescue Tool::InputSchema::ValidationError => e
          add_instrumentation_data(error: :invalid_schema)
          return Tool::Response.new(
            [{
              type: "text",
              text: e.message,
            }],
            error: true,
          ).to_h
        end
      end

      begin
        call_tool_with_args(tool, arguments)
      rescue => e
        report_exception(e, { request: request })
        Tool::Response.new(
          [{
            type: "text",
            text: "Internal error calling tool #{tool_name}: #{e.message}",
          }],
          error: true,
        ).to_h
      end
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

      add_instrumentation_data(prompt_name:)

      prompt_args = request[:arguments]
      prompt.validate_arguments!(prompt_args)

      call_prompt_template_with_args(prompt, prompt_args)
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

    def report_exception(exception, server_context = {})
      configuration.exception_reporter.call(exception, server_context)
    end

    def index_resources_by_uri(resources)
      resources.each_with_object({}) do |resource, hash|
        hash[resource.uri] = resource
      end
    end

    def accepts_server_context?(method_object)
      parameters = method_object.parameters

      parameters.any? { |type, name| type == :keyrest || name == :server_context }
    end

    def call_tool_with_args(tool, arguments)
      args = arguments&.transform_keys(&:to_sym) || {}

      if accepts_server_context?(tool.method(:call))
        tool.call(**args, server_context: server_context).to_h
      else
        tool.call(**args).to_h
      end
    end

    def call_prompt_template_with_args(prompt, args)
      if accepts_server_context?(prompt.method(:template))
        prompt.template(args, server_context: server_context).to_h
      else
        prompt.template(args).to_h
      end
    end
  end
end
