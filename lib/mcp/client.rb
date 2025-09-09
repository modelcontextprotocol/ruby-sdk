# frozen_string_literal: true

module MCP
  class Client
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
      response = transport.send_request(request: {
        jsonrpc: JsonRpcHandler::Version::V2_0,
        id: request_id,
        method: "tools/list",
      })

      response.dig("result", "tools")&.map do |tool|
        Tool.new(
          name: tool["name"],
          description: tool["description"],
          input_schema: tool["inputSchema"],
        )
      end || []
    end

    # Calls a tool via the transport layer.
    #
    # @param tool [MCP::Client::Tool] The tool to be called.
    # @param arguments [Object, nil] The arguments to pass to the tool.
    # @return [Object] The result of the tool call, as returned by the transport.
    #
    # @example
    #   tool = client.tools.first
    #   result = client.call_tool(tool: tool, arguments: { foo: "bar" })
    #
    # @note
    #   The exact requirements for `arguments` are determined by the transport layer in use.
    #   Consult the documentation for your transport (e.g., MCP::Client::HTTP) for details.
    def call_tool(tool:, arguments: nil)
      response = transport.send_request(request: {
        jsonrpc: JsonRpcHandler::Version::V2_0,
        id: request_id,
        method: "tools/call",
        params: { name: tool.name, arguments: arguments },
      })

      response.dig("result", "content")
    end

    private

    def request_id
      SecureRandom.uuid
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
  end
end
