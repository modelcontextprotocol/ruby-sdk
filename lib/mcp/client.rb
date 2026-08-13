# frozen_string_literal: true

require_relative "client/elicitation"
require_relative "client/mcp_param_headers"
require_relative "client/modern_envelope"
require_relative "client/oauth"
require_relative "client/stdio"
require_relative "client/http"
require_relative "client/paginated_result"
require_relative "client/tool"
require_relative "result_type"

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

    # Raised inside a server-to-client request handler (registered via `on_server_request`, e.g. `on_sampling`)
    # to answer the request with a specific JSON-RPC error code instead of the default internal error.
    # Mirrors the TypeScript SDK's `McpError` and the Python SDK's `ErrorData` return: for example,
    # the sampling spec answers a rejected request with code `-1`.
    # https://modelcontextprotocol.io/specification/2025-11-25/client/sampling
    class ServerRequestError < StandardError
      attr_reader :code

      def initialize(message, code:)
        super(message)
        @code = code
      end
    end

    # Raised when a server response fails client-side validation, e.g., a success response
    # whose `result` field is missing or has the wrong type. This is distinct from a
    # server-returned JSON-RPC error, which is raised as `ServerError`.
    class ValidationError < StandardError; end

    # Raised when a server answers with a SEP-2322 Multi Round-Trip `input_required` result instead of
    # a final result. The result is not an error on the wire: it asks the client to fulfill the server's
    # `inputRequests` (a map of id => `{ "method" => ..., "params" => ... }` request objects with
    # `sampling/createMessage`, `roots/list`, or `elicitation/create` shapes) and re-issue
    # the original request with `inputResponses` plus the echoed opaque `requestState`.
    # With handlers registered through `on_elicitation`, `on_sampling`, or `on_roots`, the resume loop runs
    # automatically; this error surfaces when no matching handler exists (manual driving via
    # `input_requests` and the `input_responses:`/`request_state:` kwargs), or when the round cap is exhausted.
    # https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2322
    class InputRequiredError < StandardError
      attr_reader :input_requests, :request_state, :result

      def initialize(message, input_requests:, request_state: nil, result: nil)
        super(message)
        @input_requests = input_requests
        @request_state = request_state
        @result = result
      end
    end

    # Raised when the server responds 404 to a request containing a session ID,
    # indicating the session has expired. Inherits from `RequestHandlerError` for
    # backward compatibility with callers that rescue the generic error. Per spec,
    # clients MUST start a new session with a fresh `initialize` request in response.
    class SessionExpiredError < RequestHandlerError
      def initialize(message, request, original_error: nil)
        super(message, request, error_type: :not_found, original_error: original_error)
      end
    end

    # The server's `DiscoverResult` (MCP 2026-07-28, SEP-2575): the modern protocol versions it serves,
    # its capabilities and identity, optional instructions, and the REQUIRED `ttlMs`/`cacheScope` cache hints.
    DiscoverResult = Struct.new(
      :supported_versions,
      :capabilities,
      :server_info,
      :instructions,
      :ttl_ms,
      :cache_scope,
      keyword_init: true,
    )

    # Rounds the SEP-2322 driver runs before giving up, matching the TypeScript and
    # Python SDK defaults. Every leg counts, including `requestState`-only retries.
    DEFAULT_INPUT_REQUIRED_MAX_ROUNDS = 10

    # Backoff for `requestState`-only (load shedding) legs: exponential from 50ms to
    # a 250ms cap, matching the Python SDK (the TypeScript SDK uses a fixed 250ms).
    STATE_ONLY_BACKOFF_INITIAL_SECONDS = 0.05
    STATE_ONLY_BACKOFF_CAP_SECONDS = 0.25

    # Initializes a new MCP::Client instance.
    #
    # @param transport [Object] The transport object to use for communication with the server.
    #   The transport should be a duck type that responds to `send_request`. See the README for more details.
    # @param input_required_max_rounds [Integer] Cap on SEP-2322 driver rounds.
    #
    # Once a handler is registered through `on_elicitation`, `on_sampling`, or `on_roots`, `call_tool`,
    # `get_prompt`, and `read_resource` resume `input_required` results automatically; without handlers
    # (or when a requested kind has no handler) they raise `InputRequiredError` for manual driving,
    # exactly as before.
    #
    # @example
    #   transport = MCP::Client::HTTP.new(url: "http://localhost:3000")
    #   client = MCP::Client.new(transport: transport)
    def initialize(transport:, input_required_max_rounds: DEFAULT_INPUT_REQUIRED_MAX_ROUNDS)
      @transport = transport
      # Populated by `on_elicitation`, `on_sampling`, and `on_roots`. The same handler answers both ways
      # the server can ask for input: a real server-to-client request, and an embedded request inside
      # a SEP-2322 `input_required` result.
      @input_required_handlers = {}
      @input_required_max_rounds = input_required_max_rounds
    end

    # The user may want to access additional transport-specific methods/attributes
    # So keeping it public
    attr_reader :transport

    # The raw handshake result exactly as the server returned it, so its shape depends on the connection's era (SEP-2575):
    # after the legacy handshake it is an `InitializeResult` (`protocolVersion`, top-level `serverInfo`), after modern adoption
    # it is a `DiscoverResult` (`supportedVersions`, `ttlMs`/`cacheScope`, `serverInfo` optionally under `_meta`).
    # Code that must work against both eras should prefer the era-independent readers {#protocol_version}, {#server_capabilities},
    # {#instructions}, and {#server_implementation}; this raw form remains the window to everything they do not cover
    # (`supportedVersions`, cache hints, `_meta`, extension data). Returns `nil` before `connect`, after `close`,
    # or when the transport does not expose a cached handshake result.
    def server_info
      transport.server_info if transport.respond_to?(:server_info)
    end

    # The protocol version in use on this connection, independent of its era:
    # the version negotiated by `initialize` (legacy) or adopted via `server/discover` (modern).
    # Returns `nil` before `connect`.
    def protocol_version
      return transport.protocol_version if transport.respond_to?(:protocol_version)

      server_info&.dig("protocolVersion")
    end

    # The server's capabilities Hash, present in both eras. Returns `nil` before `connect`.
    def server_capabilities
      server_info&.dig("capabilities")
    end

    # The server's instructions text, present in both eras when provided.
    def instructions
      server_info&.dig("instructions")
    end

    # The server's identity (`name`/`version`), independent of where the era puts it: top-level `serverInfo`
    # on legacy results, the optional `_meta` `io.modelcontextprotocol/serverInfo` stamp on modern results.
    # Returns `nil` when a modern server does not identify itself.
    def server_implementation
      server_info&.dig("_meta", RequestEnvelope::SERVER_INFO_META_KEY) || server_info&.dig("serverInfo")
    end

    # Performs the MCP `initialize` handshake by delegating to the transport
    # (e.g. `MCP::Client::HTTP`, `MCP::Client::Stdio`). Returns the server's
    # `InitializeResult`.
    #
    # When the transport does not respond to `:connect`, this is a no-op and
    # returns `nil`.
    #
    # @param client_info [Hash, nil] `{ name:, version: }` identifying the client.
    # @param protocol_version [String, nil] Protocol version to offer.
    # @param capabilities [Hash] Capabilities advertised by the client. May include
    #   an `extensions` member per SEP-2133, keyed by reverse-DNS extension identifiers,
    #   e.g. `{ extensions: { "com.example/feature" => {} } }`.
    # @param mode [Symbol, nil] Lifecycle selection (SEP-2575). When omitted, transports whose
    #   `connect` declares `mode:` (the bundled `MCP::Client::HTTP` and `MCP::Client::Stdio`)
    #   negotiate with `:auto`: probe `server/discover` first and fall back to the legacy handshake
    #   when the server does not serve a mutually supported modern version. Transports without `mode:`
    #   keep receiving the historical legacy call shape. `:legacy` forces the `initialize` handshake
    #   exactly as before; `:modern` requires the modern lifecycle and fails without a mutual modern version.
    #   Passing an explicit `protocol_version` from a legacy generation (e.g. `"2025-11-25"`) pins
    #   the legacy handshake without a probe, so an explicitly requested version is never overridden
    #   by the default negotiation.
    # @return [Hash, nil] The server's `InitializeResult` (legacy) or `DiscoverResult` (modern),
    #   or `nil` when the transport does not expose an explicit handshake.
    #   Prefer the era-independent readers over inspecting this Hash directly.
    # https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle#initialization
    def connect(client_info: nil, protocol_version: nil, capabilities: {}, mode: nil)
      return unless transport.respond_to?(:connect)

      effective_mode = resolve_connect_mode(mode, protocol_version)

      if effective_mode == :legacy
        transport.connect(
          client_info: client_info,
          protocol_version: protocol_version,
          capabilities: capabilities,
        )
      else
        transport.connect(
          client_info: client_info,
          protocol_version: protocol_version,
          capabilities: capabilities,
          mode: effective_mode,
        )
      end
    end

    # Sends `server/discover` (MCP 2026-07-28, SEP-2575): sessionless capability discovery
    # that works before (or instead of) `connect`.
    #
    # @param meta [Hash, nil] Additional `_meta` entries to send with the request.
    # @param cancellation [MCP::Cancellation, nil] Optional cancellation token.
    # @return [MCP::Client::DiscoverResult]
    # @raise [ServerError] If the server returns a JSON-RPC error.
    # @raise [ValidationError] If the response `result` is missing or not a Hash.
    def discover(meta: nil, cancellation: nil)
      response = request(method: Methods::SERVER_DISCOVER, meta: meta, cancellation: cancellation)
      result = response.is_a?(Hash) ? response["result"] : nil
      raise ValidationError, "Response validation failed: missing or invalid `result`" unless result.is_a?(Hash)

      DiscoverResult.new(
        supported_versions: result["supportedVersions"],
        capabilities: result["capabilities"],
        # The finalized spec (PR #3002) stamps the server identity into the result `_meta`;
        # the top-level fallback tolerates servers built against the frozen SEP text.
        server_info: result.dig("_meta", RequestEnvelope::SERVER_INFO_META_KEY) || result["serverInfo"],
        instructions: result["instructions"],
        ttl_ms: result["ttlMs"],
        cache_scope: result["cacheScope"],
      )
    end

    # Returns true once `connect` has completed the handshake on the underlying
    # transport. Transports that do not expose connection state are assumed
    # connected and return `true`.
    def connected?
      return transport.connected? if transport.respond_to?(:connected?)

      true
    end

    # Returns a single page of tools from the server.
    #
    # @param cursor [String, nil] Cursor from a previous page response.
    # @param meta [Hash, nil] Additional `_meta` entries to send with the request,
    #   e.g. SEP-414 trace context (see {MCP::TraceContext}).
    # @param cancellation [MCP::Cancellation, nil] Optional token; cancelling it sends
    #   `notifications/cancelled` to the server and raises `MCP::CancelledError` from this call.
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
    def list_tools(cursor: nil, meta: nil, cancellation: nil)
      params = cursor ? { cursor: cursor } : nil
      response = request(method: "tools/list", params: params, meta: meta, cancellation: cancellation)
      result = response["result"] || {}

      tools = (result["tools"] || []).filter_map do |tool|
        next if exclude_invalid_x_mcp_header?(tool)

        Tool.new(
          name: tool["name"],
          description: tool["description"],
          input_schema: tool["inputSchema"],
          output_schema: tool["outputSchema"],
          annotations: tool["annotations"],
        )
      end

      ListToolsResult.new(
        tools: tools,
        next_cursor: result["nextCursor"],
        meta: result["_meta"],
        ttl_ms: result["ttlMs"],
        cache_scope: result["cacheScope"],
      )
    end

    # Returns every tool available on the server. Iterates through all pages automatically
    # when the server paginates, so the full collection is returned regardless of the server's `page_size` setting.
    # Use {#list_tools} when you need fine-grained cursor control.
    #
    # Each call will make a new request - the result is not cached.
    #
    # @param cancellation [MCP::Cancellation, nil] Optional cancellation token.
    #   Cancelling it aborts whichever page is currently in flight; pages already returned are kept,
    #   but the call raises `MCP::CancelledError` instead of returning the partial set.
    # @return [Array<MCP::Client::Tool>] An array of available tools.
    #
    # @example
    #   tools = client.tools
    #   tools.each do |tool|
    #     puts tool.name
    #   end
    def tools(cancellation: nil)
      # TODO: consider renaming to `list_all_tools`.
      fetch_all_pages { |cursor| list_tools(cursor: cursor, cancellation: cancellation) }.flat_map(&:tools)
    end

    # Returns a single page of resources from the server.
    #
    # @param cursor [String, nil] Cursor from a previous page response.
    # @param meta [Hash, nil] Additional `_meta` entries to send with the request,
    #   e.g. SEP-414 trace context (see {MCP::TraceContext}).
    # @param cancellation [MCP::Cancellation, nil] Optional cancellation token.
    # @return [MCP::Client::ListResourcesResult] Result with `resources` (Array<Hash>)
    #   and `next_cursor` (String or nil).
    def list_resources(cursor: nil, meta: nil, cancellation: nil)
      params = cursor ? { cursor: cursor } : nil
      response = request(method: "resources/list", params: params, meta: meta, cancellation: cancellation)
      result = response["result"] || {}

      ListResourcesResult.new(
        resources: result["resources"] || [],
        next_cursor: result["nextCursor"],
        meta: result["_meta"],
        ttl_ms: result["ttlMs"],
        cache_scope: result["cacheScope"],
      )
    end

    # Returns every resource available on the server. Iterates through all pages automatically
    # when the server paginates, so the full collection is returned regardless of the server's `page_size` setting.
    # Use {#list_resources} when you need fine-grained cursor control.
    #
    # Each call will make a new request - the result is not cached.
    #
    # @param cancellation [MCP::Cancellation, nil] Optional cancellation token (see {#tools}).
    # @return [Array<Hash>] An array of available resources.
    def resources(cancellation: nil)
      # TODO: consider renaming to `list_all_resources`.
      fetch_all_pages { |cursor| list_resources(cursor: cursor, cancellation: cancellation) }.flat_map(&:resources)
    end

    # Returns a single page of resource templates from the server.
    #
    # @param cursor [String, nil] Cursor from a previous page response.
    # @param meta [Hash, nil] Additional `_meta` entries to send with the request,
    #   e.g. SEP-414 trace context (see {MCP::TraceContext}).
    # @param cancellation [MCP::Cancellation, nil] Optional cancellation token.
    # @return [MCP::Client::ListResourceTemplatesResult] Result with `resource_templates`
    #   (Array<Hash>) and `next_cursor` (String or nil).
    def list_resource_templates(cursor: nil, meta: nil, cancellation: nil)
      params = cursor ? { cursor: cursor } : nil
      response = request(method: "resources/templates/list", params: params, meta: meta, cancellation: cancellation)
      result = response["result"] || {}

      ListResourceTemplatesResult.new(
        resource_templates: result["resourceTemplates"] || [],
        next_cursor: result["nextCursor"],
        meta: result["_meta"],
        ttl_ms: result["ttlMs"],
        cache_scope: result["cacheScope"],
      )
    end

    # Returns every resource template available on the server. Iterates through all pages automatically
    # when the server paginates, so the full collection is returned regardless of the server's `page_size` setting.
    # Use {#list_resource_templates} when you need fine-grained cursor control.
    #
    # Each call will make a new request - the result is not cached.
    #
    # @param cancellation [MCP::Cancellation, nil] Optional cancellation token (see {#tools}).
    # @return [Array<Hash>] An array of available resource templates.
    def resource_templates(cancellation: nil)
      # TODO: consider renaming to `list_all_resource_templates`.
      fetch_all_pages { |cursor| list_resource_templates(cursor: cursor, cancellation: cancellation) }.flat_map(&:resource_templates)
    end

    # Returns a single page of prompts from the server.
    #
    # @param cursor [String, nil] Cursor from a previous page response.
    # @param meta [Hash, nil] Additional `_meta` entries to send with the request,
    #   e.g. SEP-414 trace context (see {MCP::TraceContext}).
    # @param cancellation [MCP::Cancellation, nil] Optional cancellation token.
    # @return [MCP::Client::ListPromptsResult] Result with `prompts` (Array<Hash>)
    #   and `next_cursor` (String or nil).
    def list_prompts(cursor: nil, meta: nil, cancellation: nil)
      params = cursor ? { cursor: cursor } : nil
      response = request(method: "prompts/list", params: params, meta: meta, cancellation: cancellation)
      result = response["result"] || {}

      ListPromptsResult.new(
        prompts: result["prompts"] || [],
        next_cursor: result["nextCursor"],
        meta: result["_meta"],
        ttl_ms: result["ttlMs"],
        cache_scope: result["cacheScope"],
      )
    end

    # Returns every prompt available on the server. Iterates through all pages automatically
    # when the server paginates, so the full collection is returned regardless of the server's `page_size` setting.
    # Use {#list_prompts} when you need fine-grained cursor control.
    #
    # Each call will make a new request - the result is not cached.
    #
    # @param cancellation [MCP::Cancellation, nil] Optional cancellation token (see {#tools}).
    # @return [Array<Hash>] An array of available prompts.
    def prompts(cancellation: nil)
      # TODO: consider renaming to `list_all_prompts`.
      fetch_all_pages { |cursor| list_prompts(cursor: cursor, cancellation: cancellation) }.flat_map(&:prompts)
    end

    # Calls a tool via the transport layer and returns the full response from the server.
    #
    # @param name [String] The name of the tool to call.
    # @param tool [MCP::Client::Tool] The tool to be called.
    # @param arguments [Object, nil] The arguments to pass to the tool.
    # @param progress_token [String, Integer, nil] A token to request progress notifications from the server during tool execution.
    # @param meta [Hash, nil] Additional `_meta` entries to send with the request,
    #   e.g. the W3C Trace Context keys reserved by SEP-414
    #   (`MCP::TraceContext::TRACEPARENT_META_KEY`, `tracestate`, `baggage`).
    #   `progress_token` takes precedence over a `progressToken` entry in `meta`.
    # @param cancellation [MCP::Cancellation, nil] Optional cancellation token. Cancelling it from another thread
    #   sends `notifications/cancelled` to the server and raises `MCP::CancelledError` from this call.
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
    # @example Cancellable call
    #   cancellation = MCP::Cancellation.new
    #   Thread.new do
    #     client.call_tool(name: "slow_tool", arguments: {}, cancellation: cancellation)
    #   rescue MCP::CancelledError
    #     # cleanup
    #   end
    #   cancellation.cancel(reason: "user pressed cancel")
    #
    # @note
    #   The exact requirements for `arguments` are determined by the transport layer in use.
    #   Consult the documentation for your transport (e.g., MCP::Client::HTTP) for details.
    # @param input_responses [Hash, nil] SEP-2322 answers to a previous `input_required` result's `inputRequests`,
    #   keyed identically (manual retry legs).
    # @param request_state [String, nil] The opaque `requestState` echoed back byte-exactly.
    def call_tool(name: nil, tool: nil, arguments: nil, progress_token: nil, meta: nil, cancellation: nil, input_responses: nil, request_state: nil)
      tool_name = name || tool&.name
      raise ArgumentError, "Either `name:` or `tool:` must be provided." unless tool_name

      params = { name: tool_name, arguments: arguments }
      meta_entries = meta ? meta.dup : {}
      if progress_token
        meta_entries.delete("progressToken")
        meta_entries[:progressToken] = progress_token
      end
      params[:_meta] = meta_entries unless meta_entries.empty?
      params[:inputResponses] = input_responses if input_responses
      params[:requestState] = request_state if request_state

      drive_input_required(method: "tools/call", params: params, cancellation: cancellation)
    end

    # Reads a resource from the server by URI and returns the contents.
    #
    # @param uri [String] The URI of the resource to read.
    # @param meta [Hash, nil] Additional `_meta` entries to send with the request,
    #   e.g. SEP-414 trace context (see {MCP::TraceContext}).
    # @param cancellation [MCP::Cancellation, nil] Optional cancellation token.
    # @return [Array<Hash>] An array of resource contents (text or blob).
    def read_resource(uri:, meta: nil, cancellation: nil, input_responses: nil, request_state: nil)
      params = { uri: uri }
      params = params.merge(_meta: meta) if meta && !meta.empty?
      params[:inputResponses] = input_responses if input_responses
      params[:requestState] = request_state if request_state

      response = drive_input_required(method: "resources/read", params: params, cancellation: cancellation)

      response.dig("result", "contents") || []
    end

    # Gets a prompt from the server by name and returns its details.
    #
    # @param name [String] The name of the prompt to get.
    # @param meta [Hash, nil] Additional `_meta` entries to send with the request,
    #   e.g. SEP-414 trace context (see {MCP::TraceContext}).
    # @param cancellation [MCP::Cancellation, nil] Optional cancellation token.
    # @return [Hash] A hash containing the prompt details.
    def get_prompt(name:, meta: nil, cancellation: nil, input_responses: nil, request_state: nil)
      params = { name: name }
      params = params.merge(_meta: meta) if meta && !meta.empty?
      params[:inputResponses] = input_responses if input_responses
      params[:requestState] = request_state if request_state

      response = drive_input_required(method: "prompts/get", params: params, cancellation: cancellation)

      response.fetch("result", {})
    end

    # Requests completion suggestions from the server for a prompt argument or resource template URI.
    #
    # @param ref [Hash] The reference, e.g. `{ type: "ref/prompt", name: "my_prompt" }`
    #   or `{ type: "ref/resource", uri: "file:///{path}" }`.
    # @param argument [Hash] The argument being completed, e.g. `{ name: "language", value: "py" }`.
    # @param context [Hash, nil] Optional context with previously resolved arguments.
    # @param meta [Hash, nil] Additional `_meta` entries to send with the request,
    #   e.g. SEP-414 trace context (see {MCP::TraceContext}).
    # @param cancellation [MCP::Cancellation, nil] Optional cancellation token.
    # @return [Hash] The completion result with `"values"`, `"hasMore"`, and optionally `"total"`.
    def complete(ref:, argument:, context: nil, meta: nil, cancellation: nil)
      params = { ref: ref, argument: argument }
      params[:context] = context if context

      response = request(method: "completion/complete", params: params, meta: meta, cancellation: cancellation)

      response.dig("result", "completion") || { "values" => [], "hasMore" => false }
    end

    # Registers a handler for `elicitation/create` requests the server sends while one of
    # this client's requests is in flight. The handler receives the request `params`
    # (message and `requestedSchema`, string keys) and must return an `ElicitResult`-shaped Hash:
    # `{ action: "accept" | "decline" | "cancel", content: { ... } }`.
    #
    # The same handler answers both ways a server can ask: a real request mid-call, which needs a transport that
    # carries server-to-client requests (e.g. `MCP::Client::HTTP`); and an `elicitation/create` embedded in a SEP-2322
    # `input_required` result, which needs no server-to-client route, and is how the modern lifecycle asks now that it
    # forbids server-to-client requests. Both routes need `capabilities: { elicitation: {} }` passed to `connect`: per SEP-2322,
    # a server MUST NOT embed input requests of a kind the client has not declared.
    #
    # @example Accept with schema defaults applied (SEP-1034)
    #   client.on_elicitation do |params|
    #     {
    #       action: "accept",
    #       content: MCP::Client::Elicitation.apply_defaults(params["requestedSchema"]),
    #     }
    #   end
    # https://modelcontextprotocol.io/specification/2025-11-25/client/elicitation
    def on_elicitation(&handler)
      register_input_handler(Methods::ELICITATION_CREATE, &handler)
    end

    # Registers a handler for `sampling/createMessage` requests the server sends while one of this client's requests is in flight.
    # The handler receives the request `params` (`messages`, `maxTokens`, optionally `systemPrompt`, `modelPreferences`, `tools`,
    # `toolChoice`, ...; string keys) and must return a `CreateMessageResult`-shaped Hash:
    # `{ role: "assistant", content: { type: "text", text: "..." }, model: "...", stopReason: "..." }`.
    #
    # For trust and safety, the spec recommends a human in the loop able to review, edit, or reject the request and the generated response
    # before it is returned to the server. To reject, raise `ServerRequestError` with the spec's user-rejection code `-1`.
    #
    # The same handler answers both ways a server can ask: a real request mid-call, which needs a transport that
    # carries server-to-client requests (e.g. `MCP::Client::HTTP`); and a `sampling/createMessage` embedded in a SEP-2322
    # `input_required` result, which needs no server-to-client route. Both routes need `capabilities: { sampling: {} }` passed to
    # `connect` (or `{ sampling: { tools: {} } }` for tool-enabled requests): per SEP-2322, a server MUST NOT embed input requests of
    # a kind the client has not declared.
    #
    # @example Forward the request to an LLM and return its completion
    #
    #   client.on_sampling do |params|
    #     raise MCP::Client::ServerRequestError.new("User rejected sampling request", code: -1) unless approved?(params)
    #
    #     completion = my_llm.complete(params["messages"], max_tokens: params["maxTokens"])
    #     {
    #       role: "assistant",
    #       content: { type: "text", text: completion.text },
    #       model: completion.model,
    #       stopReason: "endTurn",
    #     }
    #   end
    #
    # https://modelcontextprotocol.io/specification/2025-11-25/client/sampling
    #
    # @deprecated MCP Sampling (`sampling/createMessage`) is deprecated as of MCP protocol version 2026-07-28 (SEP-2577).
    #   Register this handler only to interoperate with servers that still send sampling requests during the deprecation window;
    #   new servers should call LLM provider APIs directly.
    def on_sampling(&handler)
      register_input_handler(Methods::SAMPLING_CREATE_MESSAGE, &handler)
    end

    # Registers a handler for `roots/list`, answering both a server-to-client request on transports that
    # support one and an embedded `roots/list` inside a SEP-2322 `input_required` result. The handler
    # receives the request `params` (`nil` for `roots/list`) and must return a `ListRootsResult`-shaped Hash:
    # `{ roots: [{ uri: "file:///project", name: "Project" }] }`.
    #
    # @example
    #   client.on_roots { { roots: [{ uri: "file:///project", name: "Project" }] } }
    #
    # @deprecated MCP Roots (`roots/list`) is deprecated as of MCP protocol version 2026-07-28 (SEP-2577).
    #   Register this handler only to interoperate with servers that still ask for roots.
    #
    # https://modelcontextprotocol.io/specification/2025-11-25/client/roots
    def on_roots(&handler)
      register_input_handler(Methods::ROOTS_LIST, &handler)
    end

    # Sends a `ping` request to the server to verify the connection is alive.
    # Per the MCP spec, the server responds with an empty result.
    #
    # @param meta [Hash, nil] Additional `_meta` entries to send with the request,
    #   e.g. SEP-414 trace context (see {MCP::TraceContext}).
    # @param cancellation [MCP::Cancellation, nil] Optional cancellation token.
    # @return [Hash] An empty hash on success.
    # @raise [ServerError] If the server returns a JSON-RPC error.
    # @raise [ValidationError] If the response `result` is missing or not a Hash.
    #
    # @example
    #   client.ping # => {}
    #
    # @see https://modelcontextprotocol.io/specification/latest/basic/utilities/ping
    def ping(meta: nil, cancellation: nil)
      result = request(method: Methods::PING, meta: meta, cancellation: cancellation)["result"]
      raise ValidationError, "Response validation failed: missing or invalid `result`" unless result.is_a?(Hash)

      result
    end

    private

    # Records a handler for one of the three kinds of input a server can ask this client for, and wires it to
    # the transport when the transport can carry server-to-client requests. One registration serves both routes:
    # the real request a 2025-11-25 server sends mid-call, and the request embedded in a SEP-2322
    # `input_required` result, which is how the modern lifecycle asks now that it forbids server-to-client
    # requests outright. Registering is therefore valid on a transport with no `on_server_request` (stdio,
    # and every modern-lifecycle connection); only the wire route is skipped there.
    def register_input_handler(method, &handler)
      @input_required_handlers[method] = handler
      transport.on_server_request(method, &handler) if transport.respond_to?(:on_server_request)

      handler
    end

    # SEP-2243: on the modern lifecycle, a tool definition whose `x-mcp-header` annotations violate
    # the spec constraints MUST be excluded from `tools/list` results, so one malformed definition
    # does not block the valid tools. The TypeScript and Python SDKs filter their listings the same way.
    # Legacy connections, and transports without a lifecycle notion, list everything as before.
    def exclude_invalid_x_mcp_header?(tool)
      return false unless transport.respond_to?(:modern?) && transport.modern?

      scan = McpParamHeaders.scan(tool["inputSchema"])
      return false if scan[:valid]

      warn("MCP::Client: excluding tool #{tool["name"].inspect} from tools/list: #{scan[:reason]}")
      true
    end

    # Resolves the effective SEP-2575 lifecycle mode for `connect`:
    #
    # - An explicit `protocol_version` from a legacy generation pins the legacy handshake without a probe,
    #   so the default negotiation can never override a version the caller asked for.
    # - Absent an explicit mode, transports declaring `mode:` negotiate with `:auto`; other transports keep
    #   the historical legacy call shape.
    # - An explicit `:modern`/`:auto` on a transport without `mode:` raises, rather than silently downgrading to
    #   a lifecycle the caller did not ask for.
    def resolve_connect_mode(mode, protocol_version)
      unless [nil, :legacy, :modern, :auto].include?(mode)
        raise ArgumentError, "mode must be :legacy, :modern, or :auto"
      end

      return :legacy if mode == :legacy
      return :legacy if mode.nil? && protocol_version && !Configuration.modern_protocol_version?(protocol_version)

      if transport_connect_accepts_mode?
        mode || :auto
      elsif mode.nil?
        :legacy
      else
        raise ArgumentError, "transport does not support mode: #{mode.inspect}"
      end
    end

    # `mode:` is forwarded only when the transport's `connect` declares it as a keyword.
    # A bare `**kwargs` deliberately does not count, so wrappers and test doubles that
    # absorb arbitrary keywords keep the historical legacy call shape. Objects that
    # dispatch `connect` through `method_missing` (e.g. mocks) may not support `method`,
    # which reads as not declaring `mode:`.
    def transport_connect_accepts_mode?
      connect_method = begin
        transport.method(:connect)
      rescue NameError
        return false
      end

      connect_method.parameters.any? { |type, name| [:key, :keyreq].include?(type) && name == :mode }
    end

    # Walks every page of a list endpoint, following `next_cursor`, and returns
    # the page results. The `seen` set guards against a server that repeats or
    # cycles cursors, so the loop always terminates.
    def fetch_all_pages
      pages = []
      seen = Set.new
      cursor = nil

      loop do
        page = yield(cursor)
        pages << page
        next_cursor = page.next_cursor
        break if next_cursor.nil? || seen.include?(next_cursor)

        seen << next_cursor
        cursor = next_cursor
      end

      pages
    end

    # Merges caller-supplied `meta` entries into the request params as `_meta`,
    # without mutating the caller's hashes. Per SEP-414, `_meta` carries
    # request-specific metadata such as W3C trace context (`traceparent`,
    # `tracestate`, `baggage`); see {MCP::TraceContext}.
    def request(method:, params: nil, meta: nil, cancellation: nil, raise_on_input_required: true)
      params = (params || {}).merge(_meta: meta) if meta && !meta.empty?

      request_body = {
        jsonrpc: JsonRpcHandler::Version::V2_0,
        id: generate_request_id,
        method: method,
      }
      request_body[:params] = params if params

      response = if cancellation
        dispatch_with_cancellation(request_body, cancellation)
      else
        transport.send_request(request: request_body)
      end

      # Guard with `is_a?(Hash)` because custom transports may return non-Hash values.
      if response.is_a?(Hash) && response.key?("error")
        error = response["error"]
        raise ServerError.new(error["message"], code: error["code"], data: error["data"])
      end

      raise_on_input_required(response) if raise_on_input_required

      response
    end

    # Drives the SEP-2322 multi round-trip loop for `tools/call`, `prompts/get`, and `resources/read`.
    # With no configured handlers this degrades to the plain request (an `input_required` result raises
    # `InputRequiredError` for manual driving). Otherwise each `inputRequests` entry is fulfilled by
    # the matching handler and the ORIGINAL request is re-issued with `inputResponses` under
    # the same keys plus the byte-exact echoed `requestState`, on a fresh JSON-RPC id per leg.
    # A `requestState`-only result (load shedding) retries after an exponential backoff.
    # Every leg counts against `input_required_max_rounds`.
    def drive_input_required(method:, params:, cancellation:)
      response = request(
        method: method,
        params: params,
        cancellation: cancellation,
        raise_on_input_required: @input_required_handlers.empty?,
      )
      return response unless input_required?(response)

      original_params = params.dup
      original_params.delete(:inputResponses)
      original_params.delete(:requestState)
      rounds = 0
      backoff = STATE_ONLY_BACKOFF_INITIAL_SECONDS

      loop do
        result = response["result"]
        rounds += 1
        if rounds > @input_required_max_rounds
          raise InputRequiredError.new(
            "Server still returned `input_required` after #{@input_required_max_rounds} rounds (SEP-2322).",
            input_requests: result["inputRequests"] || {},
            request_state: result["requestState"],
            result: result,
          )
        end

        input_requests = result["inputRequests"] || {}
        responses = nil
        if input_requests.empty?
          sleep(backoff)
          backoff = [backoff * 2, STATE_ONLY_BACKOFF_CAP_SECONDS].min
        else
          backoff = STATE_ONLY_BACKOFF_INITIAL_SECONDS
          responses = fulfill_input_requests(input_requests, result)
        end

        retry_params = original_params.dup
        retry_params[:inputResponses] = responses if responses
        retry_params[:requestState] = result["requestState"] if result["requestState"]

        response = request(
          method: method,
          params: retry_params,
          cancellation: cancellation,
          raise_on_input_required: false,
        )
        return response unless input_required?(response)
      end
    end

    # Dispatches every embedded request to its configured handler and collects
    # the answers under the same keys. A kind without a handler falls back to
    # the manual path by raising `InputRequiredError` with the full result.
    def fulfill_input_requests(input_requests, result)
      input_requests.each_with_object({}) do |(key, entry), responses|
        entry_method = entry.is_a?(Hash) ? entry["method"] || entry[:method] : nil
        handler = @input_required_handlers[entry_method]
        unless handler
          raise InputRequiredError.new(
            "Server requested #{entry_method.inspect} input (key #{key.inspect}) but no matching handler " \
              "is configured; inspect `input_requests` to respond manually (SEP-2322).",
            input_requests: input_requests,
            request_state: result["requestState"],
            result: result,
          )
        end

        responses[key] = handler.call(entry.is_a?(Hash) ? entry["params"] || entry[:params] : nil)
      end
    end

    def input_required?(response)
      result = response.is_a?(Hash) ? response["result"] : nil
      result.is_a?(Hash) && result["resultType"] == ResultType::INPUT_REQUIRED
    end

    # Recognizes a SEP-2322 `input_required` result and raises rather than returning it as if it were a final result.
    # Servers on stable protocol versions never emit `resultType`, so this is a no-op for them.
    def raise_on_input_required(response)
      return unless input_required?(response)

      result = response["result"]
      raise InputRequiredError.new(
        "Server returned `input_required` (SEP-2322). Register a handler with `on_elicitation`, " \
          "`on_sampling`, or `on_roots` to resume automatically, or inspect `input_requests` to respond manually.",
        input_requests: result["inputRequests"] || {},
        request_state: result["requestState"],
        result: result,
      )
    end

    # Generates a fresh JSON-RPC request id for an outgoing request.
    # Ids are an internal concern: the public API never accepts or exposes them, and cancellation is driven through
    # an `MCP::Cancellation` token instead.
    def generate_request_id
      SecureRandom.uuid
    end

    # Sends `request_body` while watching `cancellation`. The actual blocking `transport.send_request` runs on
    # a worker thread; the calling thread waits on a Queue that is woken either by the response or by a cancel signal
    # (whichever arrives first - matching the server-side `StreamableHTTPTransport#cancel_pending_request` race contract).
    #
    # When a cancel wins the race, the calling thread raises `MCP::CancelledError` immediately and the `notifications/cancelled`
    # dispatch runs fire-and-forget on its own thread. We deliberately do not wait for that dispatch here: the calling thread
    # must not be blocked by a slow or stalled transport write on the cancel path.
    # The worker thread is also not force-killed; it stays blocked on the underlying I/O until the server actually responds
    # (or the transport closes). This is the same trade-off the server-side `StreamableHTTPTransport#send_request` accepts and
    # is noted in the README's Cancellation section.
    def dispatch_with_cancellation(request_body, cancellation)
      unless transport.respond_to?(:send_notification)
        raise NoMethodError, "Cancellation support requires a transport that responds to `send_notification(notification:)` " \
          "so `notifications/cancelled` can be delivered to the peer. The bundled `MCP::Client::Stdio` and `MCP::Client::HTTP` transports " \
          "implement this interface; custom transports must add it before passing `cancellation:` to a request method."
      end

      cancellation.raise_if_cancelled!

      request_id = request_body[:id]
      queue = Queue.new

      # First-writer-wins gate. Whichever side (worker or on_cancel) flips `completed` first owns the queue's single slot; the loser bails.
      # This closes the late-cancel window between the worker pushing `:response` and the main thread completing `dispatch_with_cancellation`,
      # where a callback firing in that gap would otherwise emit a stray `notifications/cancelled` for a request that already succeeded.
      completion_mutex = Mutex.new
      completed = false
      sent_mutex = Mutex.new
      sent_cond = ConditionVariable.new
      request_sent = false
      signal_sent = lambda do
        sent_mutex.synchronize do
          unless request_sent
            request_sent = true
            sent_cond.broadcast
          end
        end
      end

      Thread.new do
        Thread.current.report_on_exception = false
        begin
          result = transport.send_request(request: request_body, &signal_sent)
          completion_mutex.synchronize do
            next if completed

            completed = true
            queue.push([:response, result])
          end
        rescue StandardError => e
          completion_mutex.synchronize do
            next if completed

            completed = true
            queue.push([:error, e])
          end
        ensure
          # Unblock any waiting cancel-dispatch thread on completion (or error)
          # so it does not stall when the transport ignored the block.
          signal_sent.call
        end
      end

      cancel_hook = cancellation.on_cancel do |reason|
        should_dispatch = completion_mutex.synchronize do
          next false if completed

          completed = true

          # Wake the waiting thread first, then dispatch the `notifications/cancelled` send on a separate thread.
          # The wake-first ordering matters because the cancellation callback can run on the worker thread itself
          # (e.g. a tool that triggers cancel from within `transport.send_request`), and a synchronous `send_notification`
          # here would deadlock when the worker holds a transport-level mutex.
          queue.push([:cancelled, reason])
          true
        end

        next unless should_dispatch

        Thread.new do
          Thread.current.report_on_exception = false
          # Wait for the worker's send-boundary signal before issuing `notifications/cancelled`. Bundled transports raise
          # the signal via `&on_sent` from inside `send_request`; custom transports that ignore the block still raise it
          # via the worker's `ensure -> signal_sent.call`, so the loop is bounded by worker termination rather than by wall-clock time.
          # The previous fixed-duration fallback could release this thread before the worker reached its send-boundary at all,
          # allowing the cancel to be issued without any prior request commitment - which the spec only covers under
          # the receiver's MAY-ignore-unknown-id clause and is therefore avoided here.
          sent_mutex.synchronize do
            sent_cond.wait(sent_mutex) until request_sent
          end
          cancel(request_id: request_id, reason: reason)
        rescue StandardError
          # Swallow notification-send failures: the calling thread has already been woken with `:cancelled` above and
          # is on its way to raising `MCP::CancelledError`.
        end
      end

      tag, payload = queue.pop

      case tag
      when :response
        payload
      when :error
        raise payload
      when :cancelled
        raise MCP::CancelledError.new(request_id: request_id, reason: payload)
      end
    ensure
      cancellation&.off_cancel(cancel_hook) if cancel_hook
    end

    # Sends `notifications/cancelled` to the server for an in-flight request.
    # Per spec, this is fire-and-forget: the server is expected to stop processing and suppress its response,
    # with no acknowledgement returned. Driven internally by {#dispatch_with_cancellation} when a request's
    # `cancellation` token fires.
    def cancel(request_id:, reason: nil)
      params = { requestId: request_id }
      params[:reason] = reason if reason

      notification = {
        jsonrpc: JsonRpcHandler::Version::V2_0,
        method: Methods::NOTIFICATIONS_CANCELLED,
        params: params,
      }

      transport.send_notification(notification: notification)
      nil
    end
  end
end
