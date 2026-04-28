# frozen_string_literal: true

require_relative "client/stdio"
require_relative "client/http"
require_relative "client/paginated_result"
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

    # Raised when a server response fails client-side validation, e.g., a success response
    # whose `result` field is missing or has the wrong type. This is distinct from a
    # server-returned JSON-RPC error, which is raised as `ServerError`.
    class ValidationError < StandardError; end

    # Raised when the server responds 404 to a request containing a session ID,
    # indicating the session has expired. Inherits from `RequestHandlerError` for
    # backward compatibility with callers that rescue the generic error. Per spec,
    # clients MUST start a new session with a fresh `initialize` request in response.
    class SessionExpiredError < RequestHandlerError
      def initialize(message, request, original_error: nil)
        super(message, request, error_type: :not_found, original_error: original_error)
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

    # The server's `InitializeResult` (protocol version, capabilities, server info,
    # instructions), as reported by the transport after a successful `connect`.
    # Returns `nil` before `connect`, after `close`, or when the transport manages
    # the handshake implicitly and does not expose it (e.g. stdio).
    def server_info
      transport.server_info if transport.respond_to?(:server_info)
    end

    # Performs the MCP `initialize` handshake by delegating to the transport when
    # it exposes a `connect` method (e.g. `MCP::Client::HTTP`). Returns the
    # server's `InitializeResult`.
    #
    # When the transport does not respond to `:connect` (e.g. `MCP::Client::Stdio`
    # manages the handshake implicitly on the first request), this is a no-op and
    # returns `nil`.
    #
    # @param client_info [Hash, nil] `{ name:, version: }` identifying the client.
    # @param protocol_version [String, nil] Protocol version to offer.
    # @param capabilities [Hash] Capabilities advertised by the client.
    # @return [Hash, nil] The server's `InitializeResult`, or `nil` when the transport
    #   does not expose an explicit handshake.
    # https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle#initialization
    def connect(client_info: nil, protocol_version: nil, capabilities: {})
      return unless transport.respond_to?(:connect)

      transport.connect(
        client_info: client_info,
        protocol_version: protocol_version,
        capabilities: capabilities,
      )
    end

    # Returns true once `connect` has completed the handshake on transports that
    # expose connection state. Transports that manage the handshake implicitly
    # (e.g. stdio) always report `true`, since the first request will initialize
    # on demand.
    def connected?
      return transport.connected? if transport.respond_to?(:connected?)

      true
    end

    # Returns a single page of tools from the server.
    #
    # @param cursor [String, nil] Cursor from a previous page response.
    # @return [MCP::Client::ListToolsResult] Result with `tools` (Array<MCP::Client::Tool>)
    #   and `next_cursor` (String or nil).
    #
    # @example Iterate all pages
    #   cursor = nil
    #   loop do
    #     page = client.list_tools(cursor: cursor)
    #     page.tools.each { |tool| puts tool.name }
    #     cursor = page.next_cursor
    #     break unless cursor
    #   end
    def list_tools(cursor: nil)
      params = cursor ? { cursor: cursor } : nil
      response = request(method: "tools/list", params: params)
      result = response["result"] || {}

      tools = (result["tools"] || []).map do |tool|
        Tool.new(
          name: tool["name"],
          description: tool["description"],
          input_schema: tool["inputSchema"],
        )
      end

      ListToolsResult.new(tools: tools, next_cursor: result["nextCursor"], meta: result["_meta"])
    end

    # Returns every tool available on the server. Iterates through all pages automatically
    # when the server paginates, so the full collection is returned regardless of the server's `page_size` setting.
    # Use {#list_tools} when you need fine-grained cursor control.
    #
    # Each call will make a new request - the result is not cached.
    #
    # @return [Array<MCP::Client::Tool>] An array of available tools.
    #
    # @example
    #   tools = client.tools
    #   tools.each do |tool|
    #     puts tool.name
    #   end
    def tools
      # TODO: consider renaming to `list_all_tools`.
      all_tools = []
      seen = Set.new
      cursor = nil

      loop do
        page = list_tools(cursor: cursor)
        all_tools.concat(page.tools)
        next_cursor = page.next_cursor
        break if next_cursor.nil? || seen.include?(next_cursor)

        seen << next_cursor
        cursor = next_cursor
      end

      all_tools
    end

    # Returns a single page of resources from the server.
    #
    # @param cursor [String, nil] Cursor from a previous page response.
    # @return [MCP::Client::ListResourcesResult] Result with `resources` (Array<Hash>)
    #   and `next_cursor` (String or nil).
    def list_resources(cursor: nil)
      params = cursor ? { cursor: cursor } : nil
      response = request(method: "resources/list", params: params)
      result = response["result"] || {}

      ListResourcesResult.new(
        resources: result["resources"] || [],
        next_cursor: result["nextCursor"],
        meta: result["_meta"],
      )
    end

    # Returns every resource available on the server. Iterates through all pages automatically
    # when the server paginates, so the full collection is returned regardless of the server's `page_size` setting.
    # Use {#list_resources} when you need fine-grained cursor control.
    #
    # Each call will make a new request - the result is not cached.
    #
    # @return [Array<Hash>] An array of available resources.
    def resources
      # TODO: consider renaming to `list_all_resources`.
      all_resources = []
      seen = Set.new
      cursor = nil

      loop do
        page = list_resources(cursor: cursor)
        all_resources.concat(page.resources)
        next_cursor = page.next_cursor
        break if next_cursor.nil? || seen.include?(next_cursor)

        seen << next_cursor
        cursor = next_cursor
      end

      all_resources
    end

    # Returns a single page of resource templates from the server.
    #
    # @param cursor [String, nil] Cursor from a previous page response.
    # @return [MCP::Client::ListResourceTemplatesResult] Result with `resource_templates`
    #   (Array<Hash>) and `next_cursor` (String or nil).
    def list_resource_templates(cursor: nil)
      params = cursor ? { cursor: cursor } : nil
      response = request(method: "resources/templates/list", params: params)
      result = response["result"] || {}

      ListResourceTemplatesResult.new(
        resource_templates: result["resourceTemplates"] || [],
        next_cursor: result["nextCursor"],
        meta: result["_meta"],
      )
    end

    # Returns every resource template available on the server. Iterates through all pages automatically
    # when the server paginates, so the full collection is returned regardless of the server's `page_size` setting.
    # Use {#list_resource_templates} when you need fine-grained cursor control.
    #
    # Each call will make a new request - the result is not cached.
    #
    # @return [Array<Hash>] An array of available resource templates.
    def resource_templates
      # TODO: consider renaming to `list_all_resource_templates`.
      all_templates = []
      seen = Set.new
      cursor = nil

      loop do
        page = list_resource_templates(cursor: cursor)
        all_templates.concat(page.resource_templates)
        next_cursor = page.next_cursor
        break if next_cursor.nil? || seen.include?(next_cursor)

        seen << next_cursor
        cursor = next_cursor
      end

      all_templates
    end

    # Returns a single page of prompts from the server.
    #
    # @param cursor [String, nil] Cursor from a previous page response.
    # @return [MCP::Client::ListPromptsResult] Result with `prompts` (Array<Hash>)
    #   and `next_cursor` (String or nil).
    def list_prompts(cursor: nil)
      params = cursor ? { cursor: cursor } : nil
      response = request(method: "prompts/list", params: params)
      result = response["result"] || {}

      ListPromptsResult.new(
        prompts: result["prompts"] || [],
        next_cursor: result["nextCursor"],
        meta: result["_meta"],
      )
    end

    # Returns every prompt available on the server. Iterates through all pages automatically
    # when the server paginates, so the full collection is returned regardless of the server's `page_size` setting.
    # Use {#list_prompts} when you need fine-grained cursor control.
    #
    # Each call will make a new request - the result is not cached.
    #
    # @return [Array<Hash>] An array of available prompts.
    def prompts
      # TODO: consider renaming to `list_all_prompts`.
      all_prompts = []
      seen = Set.new
      cursor = nil

      loop do
        page = list_prompts(cursor: cursor)
        all_prompts.concat(page.prompts)
        next_cursor = page.next_cursor
        break if next_cursor.nil? || seen.include?(next_cursor)

        seen << next_cursor
        cursor = next_cursor
      end

      all_prompts
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

    # Sends a `ping` request to the server to verify the connection is alive.
    # Per the MCP spec, the server responds with an empty result.
    #
    # @return [Hash] An empty hash on success.
    # @raise [ServerError] If the server returns a JSON-RPC error.
    # @raise [ValidationError] If the response `result` is missing or not a Hash.
    #
    # @example
    #   client.ping # => {}
    #
    # @see https://modelcontextprotocol.io/specification/latest/basic/utilities/ping
    def ping
      result = request(method: Methods::PING)["result"]
      raise ValidationError, "Response validation failed: missing or invalid `result`" unless result.is_a?(Hash)

      result
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
