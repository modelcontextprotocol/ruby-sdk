# frozen_string_literal: true

module MCP
  class Client
    # https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#streamable-http
    LATEST_PROTOCOL_VERSION = "2025-11-25"
    SESSION_ID_HEADER = "MCP-Session-Id"
    PROTOCOL_VERSION_HEADER = "MCP-Protocol-Version"

    # Initializes a new MCP::Client instance.
    #
    # @param transport [Object] The transport object to use for communication with the server.
    #   The transport should be a duck type that responds to `post`. See the README for more details.
    #
    # @example
    #   transport = MCP::Client::HTTP.new(url: "http://localhost:3000")
    #   client = MCP::Client.new(transport: transport)
    def initialize(transport:)
      @transport = transport
      @session_id = nil
      @protocol_version = nil
    end

    attr_reader :transport, :session_id, :protocol_version

    def connected?
      !@protocol_version.nil?
    end

    # Opens a connection to the MCP server by performing the initialization handshake.
    #
    # @param client_info [Hash] Information about the client (name, version)
    # @param protocol_version [String] The protocol version to request
    # @param capabilities [Hash] Client capabilities to advertise
    # @return [Hash] The server's initialization response
    #
    # @example
    #   client.connect(
    #     client_info: { name: "my-client", version: "1.0.0" },
    #   )
    def connect(client_info:, protocol_version: LATEST_PROTOCOL_VERSION, capabilities: {})
      request = {
        jsonrpc: JsonRpcHandler::Version::V2_0,
        id: request_id,
        method: "initialize",
        params: {
          protocolVersion: protocol_version,
          capabilities: capabilities,
          clientInfo: client_info,
        },
      }

      response = transport.post(body: request)

      # Faraday normalizes headers to lowercase
      @session_id = response.headers["mcp-session-id"]
      @protocol_version = response.body.dig("result", "protocolVersion") || protocol_version

      response.body
    end

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
      response = send_request(method: "tools/list")

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
      response = send_request(method: "resources/list")

      response.dig("result", "resources") || []
    end

    # Returns the list of prompts available from the server.
    # Each call will make a new request – the result is not cached.
    #
    # @return [Array<Hash>] An array of available prompts.
    def prompts
      response = send_request(method: "prompts/list")

      response.dig("result", "prompts") || []
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
    def call_tool(tool:, arguments: nil)
      send_request(
        method: "tools/call",
        params: { name: tool.name, arguments: arguments },
      )
    end

    # Reads a resource from the server by URI and returns the contents.
    #
    # @param uri [String] The URI of the resource to read.
    # @return [Array<Hash>] An array of resource contents (text or blob).
    def read_resource(uri:)
      response = send_request(
        method: "resources/read",
        params: { uri: uri },
      )

      response.dig("result", "contents") || []
    end

    # Gets a prompt from the server by name and returns its details.
    #
    # @param name [String] The name of the prompt to get.
    # @return [Hash] A hash containing the prompt details.
    def get_prompt(name:)
      response = send_request(
        method: "prompts/get",
        params: { name: name },
      )

      response.fetch("result", {})
    end

    # Closes the connection with the MCP server.
    # For HTTP transport, this sends a DELETE request to terminate the session.
    # Session state is cleared regardless of whether the DELETE succeeds.
    def close
      return unless @session_id

      begin
        transport.delete(headers: session_headers) if transport.respond_to?(:delete)
      rescue StandardError
        # Server may return 405 if it doesn't support session termination
      end

      @session_id = nil
      @protocol_version = nil
    end

    private

    def send_request(method:, params: nil)
      request = {
        jsonrpc: JsonRpcHandler::Version::V2_0,
        id: request_id,
        method: method,
      }
      request[:params] = params if params

      response = transport.post(body: request, headers: session_headers)

      response.body
    rescue SessionExpiredError
      @session_id = nil
      @protocol_version = nil
      raise
    end

    def session_headers
      headers = {}
      headers[SESSION_ID_HEADER] = @session_id if @session_id
      headers[PROTOCOL_VERSION_HEADER] = @protocol_version if @protocol_version
      headers
    end

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

    class SessionExpiredError < StandardError
      attr_reader :request

      def initialize(message, request)
        super(message)
        @request = request
      end
    end
  end
end
