# frozen_string_literal: true

require "json_rpc_handler"
require_relative "instrumentation"
require_relative "methods"
require_relative "server/capabilities"

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

    include Instrumentation

    attr_writer :capabilities
    attr_accessor :name, :version, :tools, :prompts, :resources, :server_context, :configuration, :transport

    def initialize(
      name: "model_context_protocol",
      version: DEFAULT_VERSION,
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
      @version = version
      @tools = tools.to_h { |t| [t.name_value, t] }
      @prompts = prompts.to_h { |p| [p.name_value, p] }
      @resources = resources
      @resource_templates = resource_templates
      @resource_index = index_resources_by_uri(resources)
      @server_context = server_context
      @configuration = MCP.configuration.merge(configuration)
      @capabilities = Capabilities.new(capabilities)
      @capabilities.support_tools if tools.any?
      @capabilities.support_prompts if prompts.any?
      @capabilities.support_resources if resources.any? || resource_templates.any?

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

        # No op handlers for currently unsupported methods
        Methods::RESOURCES_SUBSCRIBE => ->(_) {},
        Methods::RESOURCES_UNSUBSCRIBE => ->(_) {},
        Methods::COMPLETION_COMPLETE => ->(_) {},
        Methods::LOGGING_SET_LEVEL => ->(_) {},
      }
      @transport = transport
    end

    def capabilities
      @capabilities.to_h
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

    def define_tool(name: nil, description: nil, input_schema: nil, annotations: nil, &block)
      tool = Tool.define(name:, description:, input_schema:, annotations:, &block)
      @tools[tool.name_value] = tool
    end

    def define_prompt(name: nil, description: nil, arguments: [], &block)
      prompt = Prompt.define(name:, description:, arguments:, &block)
      @prompts[prompt.name_value] = prompt
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
      @capabilities.support_resources
      @handlers[Methods::RESOURCES_LIST] = block
    end

    def resources_read_handler(&block)
      @handlers[Methods::RESOURCES_READ] = block
    end

    def resources_templates_list_handler(&block)
      @capabilities.support_resources
      @handlers[Methods::RESOURCES_TEMPLATES_LIST] = block
    end

    def tools_list_handler(&block)
      @capabilities.support_tools
      @handlers[Methods::TOOLS_LIST] = block
    end

    def tools_call_handler(&block)
      @handlers[Methods::TOOLS_CALL] = block
    end

    def prompts_list_handler(&block)
      @capabilities.support_prompts
      @handlers[Methods::PROMPTS_LIST] = block
    end

    def prompts_get_handler(&block)
      @handlers[Methods::PROMPTS_GET] = block
    end

    private

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

    def server_info
      @server_info ||= {
        name:,
        version:,
      }
    end

    def init(request)
      add_instrumentation_data(method: Methods::INITIALIZE)
      {
        protocolVersion: configuration.protocol_version,
        capabilities: capabilities,
        serverInfo: server_info,
      }
    end

    def list_tools(request)
      add_instrumentation_data(method: Methods::TOOLS_LIST)
      @tools.map { |_, tool| tool.to_h }
    end

    def call_tool(request)
      add_instrumentation_data(method: Methods::TOOLS_CALL)
      tool_name = request[:name]
      tool = tools[tool_name]
      unless tool
        add_instrumentation_data(error: :tool_not_found)
        raise RequestHandlerError.new("Tool not found #{tool_name}", request, error_type: :tool_not_found)
      end

      arguments = request[:arguments]
      add_instrumentation_data(tool_name:)

      if tool.input_schema&.missing_required_arguments?(arguments)
        add_instrumentation_data(error: :missing_required_arguments)
        raise RequestHandlerError.new(
          "Missing required arguments: #{tool.input_schema.missing_required_arguments(arguments).join(", ")}",
          request,
          error_type: :missing_required_arguments,
        )
      end

      begin
        call_params = tool_call_parameters(tool)

        if call_params.include?(:server_context)
          tool.call(**arguments.transform_keys(&:to_sym), server_context:).to_h
        else
          tool.call(**arguments.transform_keys(&:to_sym)).to_h
        end
      rescue => e
        raise RequestHandlerError.new("Internal error calling tool #{tool_name}", request, original_error: e)
      end
    end

    def list_prompts(request)
      add_instrumentation_data(method: Methods::PROMPTS_LIST)
      @prompts.map { |_, prompt| prompt.to_h }
    end

    def get_prompt(request)
      add_instrumentation_data(method: Methods::PROMPTS_GET)
      prompt_name = request[:name]
      prompt = @prompts[prompt_name]
      unless prompt
        add_instrumentation_data(error: :prompt_not_found)
        raise RequestHandlerError.new("Prompt not found #{prompt_name}", request, error_type: :prompt_not_found)
      end

      add_instrumentation_data(prompt_name:)

      prompt_args = request[:arguments]
      prompt.validate_arguments!(prompt_args)

      prompt.template(prompt_args, server_context:).to_h
    end

    def list_resources(request)
      add_instrumentation_data(method: Methods::RESOURCES_LIST)

      @resources.map(&:to_h)
    end

    # Server implementation should set `resources_read_handler` to override no-op default
    def read_resource_no_content(request)
      add_instrumentation_data(method: Methods::RESOURCES_READ)
      add_instrumentation_data(resource_uri: request[:uri])
      []
    end

    def list_resource_templates(request)
      add_instrumentation_data(method: Methods::RESOURCES_TEMPLATES_LIST)

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

    def tool_call_parameters(tool)
      method_def = tool_call_method_def(tool)
      method_def.parameters.flatten
    end

    def tool_call_method_def(tool)
      method = tool.method(:call)

      if defined?(T::Utils) && T::Utils.respond_to?(:signature_for_method)
        sorbet_typed_method_definition = T::Utils.signature_for_method(method)&.method

        # Return the Sorbet typed method definition if it exists, otherwise fallback to original method
        # definition if Sorbet is defined but not used by this tool.
        sorbet_typed_method_definition || method
      else
        method
      end
    end
  end
end
