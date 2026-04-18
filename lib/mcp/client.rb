# frozen_string_literal: true

require_relative "client/stdio"
require_relative "client/http"
require_relative "client/tool"

module MCP
  class Client
    # https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#streamable-http
    LATEST_PROTOCOL_VERSION = "2025-11-25"

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

    # Raised when the server responds 404 to a request containing an expired
    # session ID. Inherits from `RequestHandlerError` for backward compatibility
    # with callers that rescue the generic error.
    class SessionExpiredError < RequestHandlerError
      def initialize(message, request)
        super(message, request, error_type: :not_found)
      end
    end

    # @param transport [#send_request] Transport responding to `send_request(request:)`
    #   and returning a `Hash` (a JSON-RPC response). `MCP::Client::HTTP` and
    #   `MCP::Client::Stdio` both satisfy this contract.
    def initialize(transport:)
      @transport = transport
    end

    attr_reader :transport

    # Session ID is exposed for transports that track one (HTTP); `nil` for
    # transports that don't (Stdio).
    def session_id
      @transport.session_id if @transport.respond_to?(:session_id)
    end

    def protocol_version
      @transport.protocol_version if @transport.respond_to?(:protocol_version)
    end

    def connected?
      !protocol_version.nil?
    end

    # Performs the MCP initialization handshake. HTTP users should call this
    # explicitly; Stdio initializes lazily on the first request.
    def connect(client_info:, protocol_version: LATEST_PROTOCOL_VERSION, capabilities: {})
      request(
        method: "initialize",
        params: {
          protocolVersion: protocol_version,
          capabilities: capabilities,
          clientInfo: client_info,
        },
      )
    end

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

    def resources
      response = request(method: "resources/list")

      response.dig("result", "resources") || []
    end

    def resource_templates
      response = request(method: "resources/templates/list")

      response.dig("result", "resourceTemplates") || []
    end

    def prompts
      response = request(method: "prompts/list")

      response.dig("result", "prompts") || []
    end

    # @param name [String] The name of the tool to call.
    # @param tool [MCP::Client::Tool] The tool to be called.
    # @param arguments [Object, nil] The arguments to pass to the tool.
    # @param progress_token [String, Integer, nil] A token to request progress
    #   notifications from the server during tool execution.
    # @return [Hash] The full JSON-RPC response from the transport.
    def call_tool(name: nil, tool: nil, arguments: nil, progress_token: nil)
      tool_name = name || tool&.name
      raise ArgumentError, "Either `name:` or `tool:` must be provided." unless tool_name

      params = { name: tool_name, arguments: arguments }
      if progress_token
        params[:_meta] = { progressToken: progress_token }
      end

      request(method: "tools/call", params: params)
    end

    def read_resource(uri:)
      response = request(method: "resources/read", params: { uri: uri })

      response.dig("result", "contents") || []
    end

    def get_prompt(name:)
      response = request(method: "prompts/get", params: { name: name })

      response.fetch("result", {})
    end

    def complete(ref:, argument:, context: nil)
      params = { ref: ref, argument: argument }
      params[:context] = context if context

      response = request(method: "completion/complete", params: params)

      response.dig("result", "completion") || { "values" => [], "hasMore" => false }
    end

    # Closes the connection. For HTTP transport, terminates the session via
    # DELETE (see the spec's session-termination section). No-op for transports
    # that don't track session state.
    def close
      @transport.close if @transport.respond_to?(:close)
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
