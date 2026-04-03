# frozen_string_literal: true

require_relative "client/stdio"
require_relative "client/http"
require_relative "client/tool"

module MCP
  class Client
    class ServerError < StandardError
      attr_reader :code, :data

      def initialize(message, code:, data: nil)
        super(message)
        @code = code
        @data = data
      end
    end

    class RequestHandlerError < StandardError
      attr_reader :error_type, :original_error, :request

      def initialize(message, request, error_type: :internal_error, original_error: nil)
        super(message)
        @request = request
        @error_type = error_type
        @original_error = original_error
      end
    end

    # Initializes a new MCP::Client instance.
    #
    # @param transport [Object] The transport object to use for communication with the server.
    #   The transport should be a duck type that responds to `send_request`. See the README for more details.
    #
    # @example
    #   transport = MCP::Client::HTTP.new(url: "http://localhost:3000")
    #   client = MCP::Client.new(transport: transport)
    def initialize(transport:)
      @transport = transport
    end

    # The user may want to access additional transport-specific methods/attributes
    # So keeping it public
    attr_reader :transport

    # Returns the list of tools available from the server.
    # Each call will make a new request – the result is not cached.
    #
    # @return [Array<MCP::Client::Tool>] An array of available tools.
    #
    # @example
    #   tools = client.tools
    #   tools.each do |tool|
    #     puts tool.name
    #   end
    def tools
      response = request(method: "tools/list")

      response.dig("result", "tools")&.map do |tool|
        Tool.new(
          name: tool["name"],
          description: tool["description"],
          input_schema: tool["inputSchema"],
        )
      end || []
    end

    # Returns the list of resources available from the server.
    # Each call will make a new request – the result is not cached.
    #
    # @return [Array<Hash>] An array of available resources.
    def resources
      response = request(method: "resources/list")

      response.dig("result", "resources") || []
    end

    # Returns the list of resource templates available from the server.
    # Each call will make a new request – the result is not cached.
    #
    # @return [Array<Hash>] An array of available resource templates.
    def resource_templates
      response = request(method: "resources/templates/list")

      response.dig("result", "resourceTemplates") || []
    end

    # Returns the list of prompts available from the server.
    # Each call will make a new request – the result is not cached.
    #
    # @return [Array<Hash>] An array of available prompts.
    def prompts
      response = request(method: "prompts/list")

      response.dig("result", "prompts") || []
    end

    # Calls a tool via the transport layer and returns the full response from the server.
    #
    # @param name [String] The name of the tool to call.
    # @param tool [MCP::Client::Tool] The tool to be called.
    # @param arguments [Object, nil] The arguments to pass to the tool.
    # @param progress_token [String, Integer, nil] A token to request progress notifications from the server during tool execution.
    # @return [Hash] The full JSON-RPC response from the transport.
    #
    # @example Call by name
    #   response = client.call_tool(name: "my_tool", arguments: { foo: "bar" })
    #   content = response.dig("result", "content")
    #
    # @example Call with a tool object
    #   tool = client.tools.first
    #   response = client.call_tool(tool: tool, arguments: { foo: "bar" })
    #   structured_content = response.dig("result", "structuredContent")
    #
    # @note
    #   The exact requirements for `arguments` are determined by the transport layer in use.
    #   Consult the documentation for your transport (e.g., MCP::Client::HTTP) for details.
    def call_tool(name: nil, tool: nil, arguments: nil, progress_token: nil)
      tool_name = name || tool&.name
      raise ArgumentError, "Either `name:` or `tool:` must be provided." unless tool_name

      params = { name: tool_name, arguments: arguments }
      if progress_token
        params[:_meta] = { progressToken: progress_token }
      end

      request(method: "tools/call", params: params)
    end

    # Reads a resource from the server by URI and returns the contents.
    #
    # @param uri [String] The URI of the resource to read.
    # @return [Array<Hash>] An array of resource contents (text or blob).
    def read_resource(uri:)
      response = request(method: "resources/read", params: { uri: uri })

      response.dig("result", "contents") || []
    end

    # Gets a prompt from the server by name and returns its details.
    #
    # @param name [String] The name of the prompt to get.
    # @return [Hash] A hash containing the prompt details.
    def get_prompt(name:)
      response = request(method: "prompts/get", params: { name: name })

      response.fetch("result", {})
    end

    # Requests completion suggestions from the server for a prompt argument or resource template URI.
    #
    # @param ref [Hash] The reference, e.g. `{ type: "ref/prompt", name: "my_prompt" }`
    #   or `{ type: "ref/resource", uri: "file:///{path}" }`.
    # @param argument [Hash] The argument being completed, e.g. `{ name: "language", value: "py" }`.
    # @param context [Hash, nil] Optional context with previously resolved arguments.
    # @return [Hash] The completion result with `"values"`, `"hasMore"`, and optionally `"total"`.
    def complete(ref:, argument:, context: nil)
      params = { ref: ref, argument: argument }
      params[:context] = context if context

      response = request(method: "completion/complete", params: params)

      response.dig("result", "completion") || { "values" => [], "hasMore" => false }
    end

    private

    def request(method:, params: nil)
      request_body = {
        jsonrpc: JsonRpcHandler::Version::V2_0,
        id: request_id,
        method: method,
      }
      request_body[:params] = params if params

      response = transport.send_request(request: request_body)

      # Guard with `is_a?(Hash)` because custom transports may return non-Hash values.
      if response.is_a?(Hash) && response.key?("error")
        error = response["error"]
        raise ServerError.new(error["message"], code: error["code"], data: error["data"])
      end

      response
    end

    def request_id
      SecureRandom.uuid
    end
  end
end
