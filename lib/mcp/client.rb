# frozen_string_literal: true

module MCP
  class Client
    # Initializes a new MCP::Client instance.
    #
    # @param transport [Object] The transport object to use for communication with the server.
    #   The transport should be a duck type that responds to `send_request`. See the README for more details.
    # @param client_info [Hash] Information about the client (name and version)
    # @param protocol_version [String] The MCP protocol version to use
    #
    # @example
    #   transport = MCP::Client::HTTP.new(url: "http://localhost:3000")
    #   client = MCP::Client.new(
    #     transport: transport,
    #     client_info: { name: "my-client", version: "1.0.0" }
    #   )
    def initialize(transport:, client_info: nil, protocol_version: "2025-06-18")
      @transport = transport
      @client_info = client_info || { name: "ruby-mcp-client", version: MCP::VERSION }
      @protocol_version = protocol_version
      @initialized = false
      @session_info = nil
    end

    # The user may want to access additional transport-specific methods/attributes
    # So keeping it public
    attr_reader :transport, :client_info, :protocol_version, :session_info

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

    # Returns the list of resources available from the server.
    # Each call will make a new request – the result is not cached.
    #
    # @return [Array<Hash>] An array of available resources.
    def resources
      response = transport.send_request(request: {
        jsonrpc: JsonRpcHandler::Version::V2_0,
        id: request_id,
        method: "resources/list",
      })

      response.dig("result", "resources") || []
    end

    # Calls a tool via the transport layer and returns the full response from the server.
    #
    # @param tool [MCP::Client::Tool] The tool to be called.
    # @param arguments [Object, nil] The arguments to pass to the tool.
    # @return [Hash] The full JSON-RPC response from the transport.
    #
    # @example
    #   tool = client.tools.first
    #   response = client.call_tool(tool: tool, arguments: { foo: "bar" })
    #   structured_content = response.dig("result", "structuredContent")
    #
    # @note
    #   The exact requirements for `arguments` are determined by the transport layer in use.
    #   Consult the documentation for your transport (e.g., MCP::Client::HTTP) for details.
    def call_tool(tool:, arguments: nil)
      transport.send_request(request: {
        jsonrpc: JsonRpcHandler::Version::V2_0,
        id: request_id,
        method: "tools/call",
        params: { name: tool.name, arguments: arguments },
      })
    end

    # Reads a resource from the server by URI and returns the contents.
    #
    # @param uri [String] The URI of the resource to read.
    # @return [Array<Hash>] An array of resource contents (text or blob).
    def read_resource(uri:)
      response = transport.send_request(request: {
        jsonrpc: JsonRpcHandler::Version::V2_0,
        id: request_id,
        method: "resources/read",
        params: { uri: uri },
      })

      response.dig("result", "contents") || []
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
