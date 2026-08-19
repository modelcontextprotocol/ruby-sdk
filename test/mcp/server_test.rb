# frozen_string_literal: true

require "test_helper"

module MCP
  class ServerTest < ActiveSupport::TestCase
    include InstrumentationTestHelper
    include InitializeParamsTestHelper
    include DeprecationWarningTestHelper
    setup do
      @tool = Tool.define(
        name: "test_tool",
        title: "Test tool",
        description: "A test tool",
        meta: { foo: "bar" },
      )

      @tool_that_raises = Tool.define(
        name: "tool_that_raises",
        title: "Tool that raises",
        description: "A tool that raises",
        input_schema: { type: "object", properties: { message: { type: "string" } }, required: ["message"] },
      ) { raise StandardError, "Tool error" }

      @tool_with_no_args = Tool.define(
        name: "tool_with_no_args",
        title: "Tool with no args",
        description: "This tool performs specific functionality...",
        annotations: {
          read_only_hint: true,
        },
      ) do
        Tool::Response.new([{ type: "text", content: "OK" }])
      end

      @prompt = Prompt.define(
        name: "test_prompt",
        title: "Test Prompt",
        description: "Test prompt",
        arguments: [
          Prompt::Argument.new(name: "test_argument", description: "Test argument", required: true),
        ],
      ) do
        Prompt::Result.new(
          description: "Hello, world!",
          messages: [
            Prompt::Message.new(role: "user", content: Content::Text.new("Hello, world!")),
          ],
        )
      end

      @resource = Resource.new(
        uri: "https://test_resource.invalid",
        name: "test-resource",
        title: "Test Resource",
        description: "Test resource",
        icons: [{ mimeType: "image/png", sizes: ["48x48", "96x96"], src: "https://example.com", theme: "light" }],
        mime_type: "text/plain",
      )

      @resource_template = ResourceTemplate.new(
        uri_template: "https://test_resource.invalid/{id}",
        name: "test-resource",
        title: "Test Resource",
        description: "Test resource",
        icons: [{ mimeType: "image/png", sizes: ["48x48", "96x96"], src: "https://example.com", theme: "light" }],
        mime_type: "text/plain",
      )

      @server_name = "test_server"
      configuration = MCP::Configuration.new
      configuration.instrumentation_callback = instrumentation_helper.callback

      @server = Server.new(
        description: "Test server",
        icons: [{ mimeType: "image/png", sizes: ["48x48", "96x96"], src: "https://example.com", theme: "light" }],
        name: @server_name,
        title: "Example Server Display Name",
        version: "1.2.3",
        instructions: "Optional instructions for the client",
        tools: [@tool, @tool_that_raises],
        prompts: [@prompt],
        resources: [@resource],
        resource_templates: [@resource_template],
        configuration: configuration,
      )
    end

    # https://modelcontextprotocol.io/specification/latest/basic/utilities/ping#behavior-requirements
    test "#handle ping request returns empty response" do
      request = {
        jsonrpc: "2.0",
        method: "ping",
        id: "123",
      }

      response = @server.handle(request)
      assert_equal(
        {
          jsonrpc: "2.0",
          id: "123",
          result: {},
        },
        response,
      )
      assert_instrumentation_data({ method: "ping" })
    end

    test "#handle_json ping request returns empty response" do
      request = JSON.generate({
        jsonrpc: "2.0",
        method: "ping",
        id: "123",
      })

      response = JSON.parse(@server.handle_json(request), symbolize_names: true)
      assert_equal(
        {
          jsonrpc: "2.0",
          id: "123",
          result: {},
        },
        response,
      )
      assert_instrumentation_data({ method: "ping" })
    end

    test "#handle server/discover returns supported versions, capabilities, server info, and instructions" do
      response = @server.handle({ jsonrpc: "2.0", method: "server/discover", id: 1 })
      result = response[:result]

      assert_equal Configuration::SUPPORTED_MODERN_PROTOCOL_VERSIONS, result[:supportedVersions]
      # Without a `subscriptions/listen`-serving transport, the `listChanged` flags are
      # stripped from the advertised capabilities (see the dedicated tests below).
      assert_equal @server.capabilities.keys, result[:capabilities].keys
      # Per the finalized spec (PR #3002), the server identity is the optional `_meta` stamp,
      # not a top-level `serverInfo` field.
      assert_equal @server_name, result.dig(:_meta, RequestEnvelope::SERVER_INFO_META_KEY, :name)
      assert_equal "1.2.3", result.dig(:_meta, RequestEnvelope::SERVER_INFO_META_KEY, :version)
      refute result.key?(:serverInfo)
      assert_equal "Optional instructions for the client", result[:instructions]
    end

    test "#handle server/discover strips listChanged and subscribe flags without a listen-serving transport" do
      server = Server.new(name: "discover_test", capabilities: {
        tools: { listChanged: true },
        resources: { listChanged: true, subscribe: true },
        logging: {},
      })

      result = server.handle({ jsonrpc: "2.0", method: "server/discover", id: 1 })[:result]

      assert_equal({ tools: {}, resources: {}, logging: {} }, result[:capabilities])
    end

    test "#handle server/discover keeps listChanged flags when the transport serves subscriptions/listen" do
      server = Server.new(name: "discover_test", capabilities: { tools: { listChanged: true } })
      transport = mock
      transport.stubs(:serves_subscriptions_listen?).returns(true)
      server.transport = transport

      result = server.handle({ jsonrpc: "2.0", method: "server/discover", id: 1 })[:result]

      assert_equal({ tools: { listChanged: true } }, result[:capabilities])
    end

    test "#handle server/discover responds before initialize and regardless of capabilities" do
      # Per SEP-2575, discovery is sessionless: no prior `initialize`, no capability gate.
      server = Server.new(name: "discover_test", capabilities: {})

      response = server.handle({ jsonrpc: "2.0", method: "server/discover", id: 1 })

      assert_equal Configuration::SUPPORTED_MODERN_PROTOCOL_VERSIONS, response.dig(:result, :supportedVersions)
    end

    test "#handle server/discover does not mark the session initialized" do
      session = ServerSession.new(server: @server, transport: mock)

      @server.handle({ jsonrpc: "2.0", method: "server/discover", id: 1 }, session: session)

      refute_predicate session, :initialized?
      # `initialize` must still succeed afterwards.
      response = @server.handle(
        { jsonrpc: "2.0", method: "initialize", id: 2, params: initialize_params },
        session: session,
      )
      refute_nil response[:result]
    end

    test "#handle server/discover omits instructions when the server has none" do
      server = Server.new(name: "discover_test")

      response = server.handle({ jsonrpc: "2.0", method: "server/discover", id: 1 })

      refute response[:result].key?(:instructions)
    end

    test "#handle server/discover always carries the required cache hints with spec defaults" do
      # Unlike the opt-in SEP-2549 hints on list/read results, `ttlMs`/`cacheScope`
      # are REQUIRED on `DiscoverResult`.
      server = Server.new(name: "discover_test")

      result = server.handle({ jsonrpc: "2.0", method: "server/discover", id: 1 })[:result]

      assert_equal 0, result[:ttlMs]
      assert_equal "private", result[:cacheScope]
    end

    test "#handle server/discover reuses the configured SEP-2549 cache hints" do
      server = Server.new(name: "discover_test", ttl_ms: 3_600_000, cache_scope: "public")

      result = server.handle({ jsonrpc: "2.0", method: "server/discover", id: 1 })[:result]

      assert_equal 3_600_000, result[:ttlMs]
      assert_equal "public", result[:cacheScope]
    end

    test "#define_custom_method raises for server/discover" do
      assert_raises(Server::MethodAlreadyDefinedError) do
        @server.define_custom_method(method_name: "server/discover") { {} }
      end
    end

    test "UnsupportedProtocolVersionError surfaces as -32022 with the SEP-2575 data shape" do
      server = Server.new(name: "error_test", tools: [TestTool])
      server.define_tool(name: "unsupported_version_tool") do
        raise Server::UnsupportedProtocolVersionError, "1900-01-01"
      end

      response = server.handle({
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: { name: "unsupported_version_tool" },
      })

      assert_equal ErrorCodes::UNSUPPORTED_PROTOCOL_VERSION, response.dig(:error, :code)
      assert_equal "Unsupported protocol version", response.dig(:error, :message)
      assert_equal Configuration::SUPPORTED_MODERN_PROTOCOL_VERSIONS, response.dig(:error, :data, :supported)
      assert_equal "1900-01-01", response.dig(:error, :data, :requested)
    end

    test "UnsupportedProtocolVersionError reports an unknown requested version" do
      error = Server::UnsupportedProtocolVersionError.new(nil)

      assert_equal "unknown", error.error_data[:requested]
    end

    test "UnsupportedProtocolVersionError accepts a symbol-keyed request Hash on every Ruby version" do
      # On Ruby 2.7, a keyword parameter in `initialize` would make the trailing symbol-keyed Hash split
      # into keywords and raise an ArgumentError.
      request = { name: "echo", arguments: {}, _meta: {} }

      error = Server::UnsupportedProtocolVersionError.new("1900-01-01", request)

      assert_equal "1900-01-01", error.error_data[:requested]
      assert_equal Configuration::SUPPORTED_MODERN_PROTOCOL_VERSIONS, error.error_data[:supported]
    end

    test "MissingRequiredClientCapabilityError surfaces as -32021 with the SEP-2575 data shape" do
      server = Server.new(name: "error_test", tools: [TestTool])
      server.define_tool(name: "missing_capability_tool") do
        raise Server::MissingRequiredClientCapabilityError, { elicitation: {} }
      end

      response = server.handle({
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: { name: "missing_capability_tool" },
      })

      assert_equal ErrorCodes::MISSING_REQUIRED_CLIENT_CAPABILITY, response.dig(:error, :code)
      assert_equal "Missing required client capability", response.dig(:error, :message)
      assert_equal({ elicitation: {} }, response.dig(:error, :data, :requiredCapabilities))
    end

    test "#handle tools/call with a modern envelope exposes per-request client data without touching the session" do
      server = Server.new(name: "modern_test", tools: [])
      received = nil
      server.define_tool(name: "modern_tool") do |server_context:|
        received = {
          modern: server_context.modern?,
          client_info: server_context.client_info,
          client_capabilities: server_context.client_capabilities,
          protocol_version: server_context.protocol_version,
        }
        Tool::Response.new([{ type: "text", text: "ok" }])
      end
      session = ServerSession.new(server: server, transport: mock)

      response = server.handle(
        modern_request("tools/call", { name: "modern_tool", arguments: {} }, capabilities: { elicitation: {} }),
        session: session,
      )

      refute_nil response[:result]
      assert received[:modern]
      assert_equal({ name: "modern_client", version: "2.0" }, received[:client_info])
      assert_equal({ elicitation: {} }, received[:client_capabilities])
      assert_equal "2026-07-28", received[:protocol_version]
      # Per SEP-2575, servers MUST NOT infer client state from prior requests, so nothing is stored.
      assert_nil session.client
      refute_predicate session, :initialized?
    end

    test "#handle tools/call with an unsupported envelope version returns -32022" do
      server = Server.new(name: "modern_test", tools: [])
      called = false
      server.define_tool(name: "modern_tool") do
        called = true
        Tool::Response.new([{ type: "text", text: "ok" }])
      end

      response = server.handle(modern_request("tools/call", { name: "modern_tool" }, version: "2027-01-01"))

      refute called
      assert_equal ErrorCodes::UNSUPPORTED_PROTOCOL_VERSION, response.dig(:error, :code)
      assert_equal Configuration::SUPPORTED_MODERN_PROTOCOL_VERSIONS, response.dig(:error, :data, :supported)
      assert_equal "2027-01-01", response.dig(:error, :data, :requested)
    end

    test "#handle rejects a claimed but incomplete envelope with -32602 naming the missing key" do
      # A request carrying the `protocolVersion` claim key must be validated, never silently served as legacy:
      # the spec maps missing required envelope fields to Invalid params, and the TypeScript and Python classifiers
      # answer the same way.
      server = Server.new(name: "modern_test", tools: [])
      server.define_tool(name: "modern_tool") { Tool::Response.new([{ type: "text", text: "ok" }]) }

      response = server.handle({
        jsonrpc: "2.0",
        method: "tools/call",
        id: 1,
        params: {
          name: "modern_tool",
          arguments: {},
          _meta: { "io.modelcontextprotocol/protocolVersion": "2026-07-28" },
        },
      })

      assert_equal JsonRpcHandler::ErrorCode::INVALID_PARAMS, response.dig(:error, :code)
      assert_includes response.dig(:error, :message), "io.modelcontextprotocol/clientCapabilities"
    end

    test "#handle serves an envelope without the optional clientInfo" do
      # `clientInfo` became optional after the SEP was finalized (spec PR #3002).
      server = Server.new(name: "modern_test", tools: [])
      received_context = nil
      server.define_tool(name: "modern_tool") do |server_context:|
        received_context = server_context
        Tool::Response.new([{ type: "text", text: "ok" }])
      end

      response = server.handle({
        jsonrpc: "2.0",
        method: "tools/call",
        id: 1,
        params: {
          name: "modern_tool",
          arguments: {},
          _meta: {
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities": { elicitation: {} },
          },
        },
      })

      refute_nil response[:result]
      assert_predicate received_context, :modern?
      assert_nil received_context.client_info
      assert_equal({ elicitation: {} }, received_context.client_capabilities)
    end

    test "#handle requires the envelope for requests on a modern-locked session" do
      server = Server.new(name: "modern_test", tools: [])
      server.define_tool(name: "modern_tool") { Tool::Response.new([{ type: "text", text: "ok" }]) }
      session = ServerSession.new(server: server, transport: mock, era: :modern)

      response = server.handle(
        { jsonrpc: "2.0", method: "tools/call", id: 1, params: { name: "modern_tool" } },
        session: session,
      )

      assert_equal JsonRpcHandler::ErrorCode::INVALID_PARAMS, response.dig(:error, :code)
      assert_includes response.dig(:error, :message), "io.modelcontextprotocol/protocolVersion"
    end

    test "#handle rejects removed lifecycle methods on a modern-locked session with -32601" do
      session = ServerSession.new(server: @server, transport: mock, era: :modern)

      Methods::MODERN_REMOVED_METHODS.each_with_index do |method, index|
        response = @server.handle(
          { jsonrpc: "2.0", method: method, id: index + 1 },
          session: session,
        )

        assert_equal JsonRpcHandler::ErrorCode::METHOD_NOT_FOUND, response.dig(:error, :code), "expected -32601 for #{method}"
        assert_equal index + 1, response[:id], "expected the request id to be preserved for #{method}"
      end
    end

    test "#handle rejects removed lifecycle methods carrying the envelope before the era locks" do
      # `StdioTransport` locks the era only after a response succeeds, so the first request of a connection
      # arrives with `era == nil`. The envelope on the request is what identifies it as modern there.
      Methods::MODERN_REMOVED_METHODS.each do |method|
        session = ServerSession.new(server: @server, transport: mock)

        response = @server.handle(modern_request(method, {}), session: session)

        assert_equal JsonRpcHandler::ErrorCode::METHOD_NOT_FOUND, response.dig(:error, :code), "expected -32601 for #{method}"
      end
    end

    test "#handle does not let an enveloped initialize lock the era before it is settled" do
      # Serving it would negotiate the legacy lifecycle for a request that declared the modern one,
      # pinning the connection to the wrong era for its whole lifetime.
      session = ServerSession.new(server: @server, transport: mock)

      @server.handle(modern_request("initialize", initialize_params), session: session)

      assert_nil session.era
      refute_predicate session, :initialized?
    end

    test "#handle serves an enveloped method the modern lifecycle keeps before the era locks" do
      session = ServerSession.new(server: @server, transport: mock)

      response = @server.handle(modern_request("tools/list", {}), session: session)

      refute_nil response[:result]
    end

    test "#handle counter-offers the latest handshake version for a modern initialize request and locks the legacy era" do
      # Per the SEP-2575 era model, the handshake never lands on a modern version: the client is
      # counter-offered 2025-11-25 and the connection proceeds on the legacy lifecycle it selected.
      session = ServerSession.new(server: @server, transport: mock)

      response = @server.handle(
        {
          jsonrpc: "2.0",
          method: "initialize",
          id: 1,
          params: initialize_params(protocolVersion: "2026-07-28"),
        },
        session: session,
      )

      assert_equal Configuration::LATEST_HANDSHAKE_PROTOCOL_VERSION, response.dig(:result, :protocolVersion)
      assert_equal :legacy, session.era
    end

    test "#handle server/discover requires the envelope on a modern-locked session" do
      # The 2026-07-28 conformance requirements reject an envelope-less `server/discover`
      # on the modern era with -32602 (SEP-2575).
      session = ServerSession.new(server: @server, transport: mock, era: :modern)

      response = @server.handle({ jsonrpc: "2.0", method: "server/discover", id: 1 }, session: session)

      assert_equal JsonRpcHandler::ErrorCode::INVALID_PARAMS, response.dig(:error, :code)
    end

    test "#handle server/discover succeeds without an envelope outside the modern era" do
      response = @server.handle({ jsonrpc: "2.0", method: "server/discover", id: 1 })

      refute_nil response[:result]
    end

    test "#handle tools/call enforces require_client_capability! from the envelope" do
      server = Server.new(name: "modern_test", tools: [])
      server.define_tool(name: "guarded_tool") do |server_context:|
        server_context.require_client_capability!(:elicitation, :form)
        Tool::Response.new([{ type: "text", text: "ok" }])
      end

      declared = server.handle(
        modern_request("tools/call", { name: "guarded_tool" }, capabilities: { elicitation: { form: {} } }),
      )
      undeclared = server.handle(modern_request("tools/call", { name: "guarded_tool" }))

      refute_nil declared[:result]
      assert_equal ErrorCodes::MISSING_REQUIRED_CLIENT_CAPABILITY, undeclared.dig(:error, :code)
      assert_equal(
        { elicitation: { form: {} } },
        undeclared.dig(:error, :data, :requiredCapabilities),
      )
    end

    test "#handle tools/call serializes an input_required result on a modern request" do
      server = Server.new(name: "mrtr_test", tools: [])
      server.define_tool(name: "mrtr_tool") do |server_context:|
        if server_context.input_responses
          Tool::Response.new([{ type: "text", text: "done" }])
        else
          Server::InputRequiredResult.new(
            input_requests: { region: { method: "elicitation/create", params: { message: "Which region?" } } },
            request_state: "state-1",
          )
        end
      end

      response = server.handle(
        modern_request("tools/call", { name: "mrtr_tool" }, capabilities: { elicitation: { form: {} } }),
      )
      result = response[:result]

      assert_equal "input_required", result[:resultType]
      assert_equal "state-1", result[:requestState]
      assert_equal(
        { method: "elicitation/create", params: { message: "Which region?" } },
        result.dig(:inputRequests, "region"),
      )
    end

    test "#handle tools/call retry leg exposes input responses and request state to the handler" do
      server = Server.new(name: "mrtr_test", tools: [])
      seen = nil
      server.define_tool(name: "mrtr_tool") do |server_context:|
        seen = {
          input_responses: server_context.input_responses,
          request_state: server_context.request_state,
          region: server_context.input_response(:region),
        }
        Tool::Response.new([{ type: "text", text: "done" }])
      end

      request = modern_request("tools/call", {
        name: "mrtr_tool",
        arguments: {},
        inputResponses: { region: { action: "accept", content: { value: "us-east-1" } } },
        requestState: "state-1",
      })
      response = server.handle(request)

      refute_nil response[:result]
      assert_equal "state-1", seen[:request_state]
      assert_equal({ action: "accept", content: { value: "us-east-1" } }, seen[:region])
      assert_equal seen[:region], seen[:input_responses][:region]
    end

    test "#handle rejects an input_required result on a legacy request with an internal error" do
      # The result type exists only in the 2026-07-28 lifecycle: pre-2026 clients treat
      # an unknown resultType as a final result, so it must never reach them.
      server = Server.new(name: "mrtr_test", tools: [])
      server.define_tool(name: "mrtr_tool") do
        Server::InputRequiredResult.new(request_state: "state-1")
      end

      response = server.handle({
        jsonrpc: "2.0",
        method: "tools/call",
        id: 1,
        params: { name: "mrtr_tool" },
      })

      assert_equal JsonRpcHandler::ErrorCode::INTERNAL_ERROR, response.dig(:error, :code)
    end

    test "#handle rejects an input_required result whose embedded requests exceed declared capabilities" do
      server = Server.new(name: "mrtr_test", tools: [])
      server.define_tool(name: "mrtr_tool") do
        Server::InputRequiredResult.new(input_requests: {
          region: { method: "elicitation/create", params: { message: "?" } },
          roots: { method: "roots/list" },
        })
      end

      response = server.handle(modern_request("tools/call", { name: "mrtr_tool" }, capabilities: {}))

      assert_equal ErrorCodes::MISSING_REQUIRED_CLIENT_CAPABILITY, response.dig(:error, :code)
      assert_equal(
        { elicitation: { form: {} }, roots: {} },
        response.dig(:error, :data, :requiredCapabilities),
      )
    end

    test "#handle tools/call input_required bypasses output schema validation" do
      configuration = Configuration.new(validate_tool_call_results: true)
      server = Server.new(name: "mrtr_test", tools: [], configuration: configuration)
      server.define_tool(name: "mrtr_tool", output_schema: { properties: { value: { type: "string" } }, required: ["value"] }) do
        Server::InputRequiredResult.new(request_state: "state-1")
      end

      response = server.handle(modern_request("tools/call", { name: "mrtr_tool" }))

      assert_equal "input_required", response.dig(:result, :resultType)
    end

    test "#handle seals and unseals requestState transparently when request_state_security is set" do
      security = Server::RequestStateSecurity.new(key: "k" * 32)
      server = Server.new(name: "mrtr_test", tools: [], request_state_security: security)
      seen_state = nil
      server.define_tool(name: "mrtr_tool") do |server_context:|
        if server_context.request_state
          seen_state = server_context.request_state
          Tool::Response.new([{ type: "text", text: "done" }])
        else
          Server::InputRequiredResult.new(request_state: "plain-state")
        end
      end

      first = server.handle(modern_request("tools/call", { name: "mrtr_tool", arguments: {} }))
      sealed = first.dig(:result, :requestState)

      assert sealed.start_with?("v1.")
      refute_equal "plain-state", sealed

      retry_response = server.handle(modern_request("tools/call", {
        name: "mrtr_tool",
        arguments: {},
        requestState: sealed,
      }))

      refute_nil retry_response[:result]
      # The handler reads the plaintext it originally wrote.
      assert_equal "plain-state", seen_state
    end

    test "#handle rejects a tampered or cross-call requestState echo with -32602" do
      security = Server::RequestStateSecurity.new(key: "k" * 32)
      server = Server.new(name: "mrtr_test", tools: [], request_state_security: security)
      server.define_tool(name: "mrtr_tool") do |server_context:|
        if server_context.request_state
          Tool::Response.new([{ type: "text", text: "done" }])
        else
          Server::InputRequiredResult.new(request_state: "plain-state")
        end
      end

      first = server.handle(modern_request("tools/call", { name: "mrtr_tool", arguments: {} }))
      sealed = first.dig(:result, :requestState)

      tampered = server.handle(modern_request("tools/call", {
        name: "mrtr_tool",
        arguments: {},
        requestState: sealed.sub("v1.", "v1.x"),
      }))
      # Different arguments than the sealing call: the digest claim no longer matches.
      cross_call = server.handle(modern_request("tools/call", {
        name: "mrtr_tool",
        arguments: { other: true },
        requestState: sealed,
      }))

      assert_equal JsonRpcHandler::ErrorCode::INVALID_PARAMS, tampered.dig(:error, :code)
      assert_equal "Invalid or expired requestState", tampered.dig(:error, :message)
      assert_equal JsonRpcHandler::ErrorCode::INVALID_PARAMS, cross_call.dig(:error, :code)
    end

    test "#handle passes requestState through untouched without request_state_security" do
      server = Server.new(name: "mrtr_test", tools: [])
      seen_state = nil
      server.define_tool(name: "mrtr_tool") do |server_context:|
        seen_state = server_context.request_state
        Tool::Response.new([{ type: "text", text: "done" }])
      end

      server.handle(modern_request("tools/call", { name: "mrtr_tool", requestState: "raw-state" }))

      assert_equal "raw-state", seen_state
    end

    test "#handle prompts/get serializes an input_required result on a modern request" do
      server = Server.new(name: "mrtr_test")
      server.define_prompt(name: "mrtr_prompt", arguments: []) do |_args, server_context:|
        server_context.request_state # participates via server_context:
        Server::InputRequiredResult.new(request_state: "prompt-state")
      end

      response = server.handle(modern_request("prompts/get", { name: "mrtr_prompt", arguments: {} }))

      assert_equal "input_required", response.dig(:result, :resultType)
      assert_equal "prompt-state", response.dig(:result, :requestState)
    end

    test "#handle resources/read passes an input_required result through unwrapped and without cache hints" do
      server = Server.new(name: "mrtr_test", ttl_ms: 5000, cache_scope: "public")
      server.resources_read_handler do |_params, server_context:|
        server_context.request_state
        Server::InputRequiredResult.new(request_state: "resource-state")
      end

      response = server.handle(modern_request("resources/read", { uri: "file:///pending.txt" }))
      result = response[:result]

      assert_equal "input_required", result[:resultType]
      assert_equal "resource-state", result[:requestState]
      refute result.key?(:contents)
      refute result.key?(:ttlMs)
      refute result.key?(:cacheScope)
    end

    test "ServerSession locks the legacy era on mark_initialized! and refuses to flip eras" do
      session = ServerSession.new(server: @server, transport: mock)

      assert_nil session.era
      session.mark_initialized!
      assert_equal :legacy, session.era

      session.lock_era!(:legacy)
      assert_equal :legacy, session.era
      assert_raises(RuntimeError) { session.lock_era!(:modern) }
    end

    test "ServerSession accepts a preset era and validates era values" do
      session = ServerSession.new(server: @server, transport: mock, era: :modern)

      assert_equal :modern, session.era
      assert_raises(ArgumentError) { ServerSession.new(server: @server, transport: mock, era: :future) }
      assert_raises(ArgumentError) { session.lock_era!(:future) }
    end

    test "#handle initialize request returns protocol info, server info, and capabilities" do
      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: initialize_params,
      }

      response = @server.handle(request)
      refute_nil response

      expected_result = {
        jsonrpc: "2.0",
        id: 1,
        result: {
          protocolVersion: Configuration::LATEST_HANDSHAKE_PROTOCOL_VERSION,
          capabilities: {
            prompts: { listChanged: true },
            resources: { listChanged: true },
            tools: { listChanged: true },
            logging: {},
          },
          serverInfo: {
            description: "Test server",
            icons: [{ mimeType: "image/png", sizes: ["48x48", "96x96"], src: "https://example.com", theme: "light" }],
            name: @server_name,
            title: "Example Server Display Name",
            version: "1.2.3",
          },
          instructions: "Optional instructions for the client",
        },
      }

      assert_equal expected_result, response
      assert_instrumentation_data({ method: "initialize", client: { name: "test-client", version: "1.0.0" } })
    end

    test "#handle initialize result carries declared capability extensions" do
      server = Server.new(
        name: "extensions_test",
        capabilities: {
          tools: { listChanged: true },
          extensions: { "com.example/feature" => { enabled: true } },
        },
      )

      response = server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })

      assert_equal(
        { "com.example/feature" => { enabled: true } },
        response.dig(:result, :capabilities, :extensions),
      )
    end

    test "Server.new accepts an MCP::Server::Capabilities instance" do
      capabilities = Server::Capabilities.new
      capabilities.support_tools
      capabilities.support_extensions("io.modelcontextprotocol/tasks" => {})

      server = Server.new(name: "extensions_test", capabilities: capabilities)
      response = server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })

      assert_equal(
        {
          tools: {},
          extensions: { "io.modelcontextprotocol/tasks" => {} },
        },
        response.dig(:result, :capabilities),
      )
    end

    test "client-declared capability extensions are readable via client_capabilities" do
      extensions = { "com.example/feature": { enabled: true } }
      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: initialize_params(capabilities: { extensions: extensions }),
      }

      @server.handle(request)

      assert_equal extensions, @server.client_capabilities[:extensions]
    end

    test "client-declared capability extensions are readable via the session" do
      session = ServerSession.new(server: @server, transport: mock)
      extensions = { "com.example/feature": {} }
      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: initialize_params(capabilities: { extensions: extensions }),
      }

      @server.handle(request, session: session)

      assert_equal extensions, session.client_capabilities[:extensions]
    end

    test "#handle initialize request with clientInfo includes client in instrumentation data" do
      client_info = { name: "test_client", version: "1.0.0" }
      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: initialize_params(clientInfo: client_info),
      }

      @server.handle(request)
      assert_instrumentation_data({ method: "initialize", client: client_info })
    end

    test "instrumentation data includes client info for subsequent requests after initialize" do
      client_info = { name: "test_client", version: "1.0.0" }
      initialize_request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: initialize_params(clientInfo: client_info),
      }
      @server.handle(initialize_request)

      ping_request = {
        jsonrpc: "2.0",
        method: "ping",
        id: 2,
      }
      @server.handle(ping_request)
      assert_instrumentation_data({ method: "ping", client: client_info })
    end

    test "#handle rejects duplicate initialize on an already-initialized session with -32600" do
      session = ServerSession.new(server: @server, transport: mock)

      first_request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: initialize_params(clientInfo: { name: "original", version: "1.0" }),
      }
      first_response = @server.handle(first_request, session: session)
      refute_nil first_response[:result]

      second_request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 2,
        params: initialize_params(clientInfo: { name: "intruder", version: "9.9" }, protocolVersion: "2024-11-05"),
      }
      second_response = @server.handle(second_request, session: session)

      assert_equal JsonRpcHandler::ErrorCode::INVALID_REQUEST, second_response[:error][:code]
      assert_equal "Invalid Request", second_response[:error][:message]
      assert_equal({ name: "original", version: "1.0" }, session.client)
    end

    test "#handle initialize with empty params returns -32602 and does not initialize the session" do
      session = ServerSession.new(server: @server, transport: mock)

      response = @server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: {} }, session: session)

      assert_equal(-32602, response[:error][:code])
      assert_equal "Invalid params", response[:error][:message]
      refute_predicate session, :initialized?
    end

    test "#handle initialize without params returns -32602" do
      response = @server.handle({ jsonrpc: "2.0", method: "initialize", id: 1 })

      assert_equal(-32602, response[:error][:code])
      assert_equal "Invalid params", response[:error][:message]
    end

    test "#handle initialize with a missing required field returns -32602" do
      [:protocolVersion, :capabilities, :clientInfo].each do |field|
        params = initialize_params.tap { |hash| hash.delete(field) }

        response = @server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: params })

        assert_equal(-32602, response[:error][:code], "expected -32602 when #{field} is missing")
        assert_includes response[:error][:data], field.to_s
      end
    end

    test "#handle initialize with clientInfo missing name or version returns -32602" do
      [{ name: "client-without-version" }, { version: "1.0.0" }].each do |client_info|
        response = @server.handle({
          jsonrpc: "2.0",
          method: "initialize",
          id: 1,
          params: initialize_params(clientInfo: client_info),
        })

        assert_equal(-32602, response[:error][:code])
        assert_includes response[:error][:data], "clientInfo"
      end
    end

    test "#handle initialize with an unsupported protocolVersion still negotiates the fallback version" do
      response = @server.handle({
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: initialize_params(protocolVersion: "1999-01-01"),
      })

      assert_equal Configuration::LATEST_HANDSHAKE_PROTOCOL_VERSION, response[:result][:protocolVersion]
    end

    test "instrumentation data does not include client key when no clientInfo provided" do
      request = {
        jsonrpc: "2.0",
        method: "ping",
        id: 1,
      }

      @server.handle(request)
      assert_instrumentation_data({ method: "ping" })
    end

    test "unsupported method instrumentation includes client from session" do
      session = ServerSession.new(server: @server, transport: mock)
      session.store_client_info(client: { name: "session-client", version: "1.0" })

      request = {
        jsonrpc: "2.0",
        method: "does/not/exist",
        id: 1,
      }

      @server.handle(request, session: session)
      assert_instrumentation_data({ method: "unsupported_method", client: { name: "session-client", version: "1.0" } })
    end

    test "#handle returns nil for notification requests" do
      request = {
        jsonrpc: "2.0",
        method: "some_notification",
      }

      assert_nil @server.handle(request)
      assert_instrumentation_data({ method: "unsupported_method" })
    end

    test "#handle notifications/initialized returns nil response" do
      request = {
        jsonrpc: "2.0",
        method: "notifications/initialized",
      }

      assert_nil @server.handle(request)
      assert_instrumentation_data({ method: "notifications/initialized" })
    end

    test "#handle_json notifications/initialized returns nil response" do
      request = JSON.generate({
        jsonrpc: "2.0",
        method: "notifications/initialized",
      })

      assert_nil @server.handle_json(request)
      assert_instrumentation_data({ method: "notifications/initialized" })
    end

    test "#handle tools/list returns available tools" do
      request = {
        jsonrpc: "2.0",
        method: "tools/list",
        id: 1,
      }

      response = @server.handle(request)
      result = response[:result]
      assert_kind_of Array, result[:tools]
      assert_equal "test_tool", result[:tools][0][:name]
      assert_equal "Test tool", result[:tools][0][:title]
      assert_equal "A test tool", result[:tools][0][:description]
      assert_equal(
        { "$schema": "https://json-schema.org/draft/2020-12/schema", type: "object" }, result[:tools][0][:inputSchema]
      )
      assert_equal({ foo: "bar" }, result[:tools][0][:_meta])
      assert_instrumentation_data({ method: "tools/list" })
    end

    test "#handle_json tools/list returns available tools" do
      request = JSON.generate({
        jsonrpc: "2.0",
        method: "tools/list",
        id: 1,
      })

      response = JSON.parse(@server.handle_json(request), symbolize_names: true)
      result = response[:result]
      assert_kind_of Array, result[:tools]
      assert_equal "test_tool", result[:tools][0][:name]
      assert_equal "Test tool", result[:tools][0][:title]
      assert_equal "A test tool", result[:tools][0][:description]
      assert_equal({ foo: "bar" }, result[:tools][0][:_meta])
    end

    test "#handle tools/list emits 2020-12 $schema on inputSchema and outputSchema" do
      tool_with_output = Tool.define(
        name: "tool_with_output",
        description: "tool with output schema",
        input_schema: { properties: { msg: { type: "string" } } },
        output_schema: { properties: { result: { type: "string" } } },
      ) do
        Tool::Response.new([{ type: "text", content: "OK" }])
      end
      server = Server.new(name: "test_server", tools: [tool_with_output])

      response = server.handle({ jsonrpc: "2.0", method: "tools/list", id: 1 })
      tool = response[:result][:tools][0]

      assert_equal "https://json-schema.org/draft/2020-12/schema", tool[:inputSchema][:"$schema"]
      assert_equal "https://json-schema.org/draft/2020-12/schema", tool[:outputSchema][:"$schema"]
    end

    test "#handle tools/call executes tool and returns result" do
      tool_name = "test_tool"
      tool_args = { arg: "value" }
      tool_response = Tool::Response.new([{ result: "success" }])

      if RUBY_VERSION >= "3.1"
        # Ruby 3.1+: Mocha stub preserves `method.parameters` info.
        @tool.expects(:call).with(arg: "value", server_context: is_a(ServerContext)).returns(tool_response)
      else
        # Ruby 3.0: Mocha stub changes `method.parameters`, so `accepts_server_context?` returns false.
        @tool.expects(:call).with(arg: "value").returns(tool_response)
      end

      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: {
          name: tool_name,
          arguments: tool_args,
        },
        id: 1,
      }

      response = @server.handle(request)
      assert_equal tool_response.to_h, response[:result]
      assert_instrumentation_data({ method: "tools/call", tool_name: tool_name, tool_arguments: tool_args })
    end

    test "#handle_json tools/call delivers nested object arguments with symbol keys at every level" do
      received_payload = nil
      server = Server.new(name: "test_server")
      server.define_tool(
        name: "nested_args_tool",
        input_schema: { properties: { message: { type: "string" }, payload: { type: "object" } }, required: ["message"] },
      ) do |message:, payload: nil, server_context:|
        received_payload = payload
        Tool::Response.new([{ type: "text", text: "#{message} #{server_context.class}" }])
      end

      request_json = JSON.generate(
        jsonrpc: "2.0",
        method: "tools/call",
        id: 1,
        params: {
          name: "nested_args_tool",
          arguments: { message: "hi", payload: { subject: "greet", nested: { deep: "value" } } },
        },
      )

      server.handle_json(request_json)

      assert_equal({ subject: "greet", nested: { deep: "value" } }, received_payload)
      assert_equal "greet", received_payload[:subject]
      assert_nil received_payload["subject"]
    end

    test "tool receives symbol keys when called under the JSON-round-tripped argument shape" do
      received_payload = nil
      tool = Tool.define(
        name: "nested_args_tool",
        input_schema: { properties: { payload: { type: "object" } } },
      ) do |payload: nil, server_context:|
        received_payload = payload
        Tool::Response.new([{ type: "text", text: server_context.class.to_s }])
      end

      # Round-trip the arguments through JSON the way a transport does, so the tool
      # is exercised under the symbolized shape it actually receives at runtime.
      arguments = { payload: { "subject" => "greet" } }
      delivered = JSON.parse(JSON.generate(arguments), symbolize_names: true)
      tool.call(**delivered, server_context: nil)

      assert_equal({ subject: "greet" }, received_payload)
      assert_nil received_payload["subject"]
    end

    test "#handle tools/call returns tool execution error if required tool arguments are missing" do
      tool_with_required_argument = Tool.define(
        name: "test_tool",
        title: "Test tool",
        description: "A test tool",
        input_schema: { properties: { message: { type: "string" } }, required: ["message"] },
      ) do |message: nil|
        Tool::Response.new("success #{message}")
      end

      server = Server.new(
        name: "test_server",
        tools: [tool_with_required_argument],
      )

      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: "test_tool", arguments: {} },
        id: 1,
      }

      response = server.handle(request)

      assert_nil response[:error]
      assert(response[:result][:isError])
      assert_equal "text", response[:result][:content][0][:type]
      assert_includes response[:result][:content][0][:text], "Missing required arguments: message"
    end

    test "#handle_json tools/call executes tool and returns result" do
      tool_name = "test_tool"
      tool_args = { arg: "value" }
      tool_response = Tool::Response.new([{ result: "success" }])

      if RUBY_VERSION >= "3.1"
        # Ruby 3.1+: Mocha stub preserves `method.parameters` info.
        @tool.expects(:call).with(arg: "value", server_context: is_a(ServerContext)).returns(tool_response)
      else
        # Ruby 3.0: Mocha stub changes `method.parameters`, so `accepts_server_context?` returns false.
        @tool.expects(:call).with(arg: "value").returns(tool_response)
      end

      request = JSON.generate({
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: tool_name, arguments: tool_args },
        id: 1,
      })

      raw_response = @server.handle_json(request)
      response = JSON.parse(raw_response, symbolize_names: true) if raw_response
      assert_equal tool_response.to_h, response[:result] if response
      assert_instrumentation_data({ method: "tools/call", tool_name: tool_name, tool_arguments: { arg: "value" } })
    end

    test "#handle_json tools/call executes tool and returns result, when the tool is typed with Sorbet" do
      skip "Sorbet is not available" unless defined?(T::Sig)

      class TypedTestTool < Tool
        tool_name "test_tool"
        description "a test tool for testing"
        input_schema({ properties: { message: { type: "string" } }, required: ["message"] })

        class << self
          extend T::Sig

          sig { params(message: String, server_context: T.nilable(T.untyped)).returns(Tool::Response) }
          def call(message:, server_context: nil)
            Tool::Response.new([{ type: "text", content: "OK" }])
          end
        end
      end

      request = JSON.generate({
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: "test_tool", arguments: { message: "Hello, world!" } },
        id: 1,
      })

      server = Server.new(
        name: @server_name,
        tools: [TypedTestTool],
        prompts: [@prompt],
        resources: [@resource],
        resource_templates: [@resource_template],
      )

      raw_response = server.handle_json(request)
      response = JSON.parse(raw_response, symbolize_names: true) if raw_response

      assert_equal({ content: [{ type: "text", content: "OK" }], isError: false }, response[:result])
    end

    test "#handle tools/call returns protocol error in JSON-RPC format if the tool raises an uncaught exception" do
      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: {
          name: "tool_that_raises",
          arguments: { message: "test" },
        },
        id: 1,
      }

      @server.configuration.exception_reporter.expects(:call).with do |exception, server_context|
        refute_kind_of MCP::Server::RequestHandlerError, exception
        assert_equal({ request: request }, server_context)
      end

      response = @server.handle(request)

      assert_nil response[:result]
      assert_equal(-32603, response[:error][:code])
      assert_equal "Internal error", response[:error][:message]
      assert_equal "Internal error calling tool tool_that_raises", response[:error][:data]
      assert_instrumentation_data({ method: "tools/call", tool_name: "tool_that_raises", tool_arguments: { message: "test" }, error: :internal_error })
    end

    test "registers tools with the same class name in different namespaces" do
      module Foo
        class Example < Tool
        end
      end

      module Bar
        class Example < Tool
        end
      end

      error = assert_raises(MCP::ToolNotUnique) { Server.new(tools: [Foo::Example, Bar::Example]) }
      assert_equal(<<~MESSAGE, error.message)
        Tool names should be unique. Use `tool_name` to assign unique names to:
        example
      MESSAGE
    end

    test "registers tools with the same tool name" do
      module Baz
        class Example < Tool
          tool_name "foo"
        end
      end

      module Qux
        class Example < Tool
          tool_name "foo"
        end
      end

      error = assert_raises(MCP::ToolNotUnique) { Server.new(tools: [Baz::Example, Qux::Example]) }
      assert_equal(<<~MESSAGE, error.message)
        Tool names should be unique. Use `tool_name` to assign unique names to:
        foo
      MESSAGE
    end

    test "#handle_json returns protocol error in JSON-RPC format if the tool raises an uncaught exception" do
      request = JSON.generate({
        jsonrpc: "2.0",
        method: "tools/call",
        params: {
          name: "tool_that_raises",
          arguments: { message: "test" },
        },
        id: 1,
      })

      response = JSON.parse(@server.handle_json(request), symbolize_names: true)
      assert_nil response[:result]
      assert_equal(-32603, response[:error][:code])
      assert_equal "Internal error", response[:error][:message]
      assert_equal "Internal error calling tool tool_that_raises", response[:error][:data]
      assert_instrumentation_data({ method: "tools/call", tool_name: "tool_that_raises", tool_arguments: { message: "test" }, error: :internal_error })
    end

    test "#handle tools/call returns protocol error in JSON-RPC format if input_schema raises an error during validation" do
      tool = Tool.define(
        name: "tool_with_faulty_schema",
        title: "Tool with faulty schema",
        description: "A tool with a faulty schema",
        input_schema: { type: "object", properties: { message: { type: "string" } }, required: ["message"] },
      ) { Tool::Response.new("success") }

      tool.input_schema.expects(:missing_required_arguments?).raises(RuntimeError, "Unexpected schema error")

      server = Server.new(name: "test_server", tools: [tool])

      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: {
          name: "tool_with_faulty_schema",
          arguments: { message: "test" },
        },
        id: 1,
      }

      response = server.handle(request)

      assert_nil response[:result]
      assert_equal(-32603, response[:error][:code])
      assert_equal "Internal error", response[:error][:message]
      assert_equal "Internal error calling tool tool_with_faulty_schema", response[:error][:data]
    end

    test "#handle tools/call returns JSON-RPC error for unknown tool" do
      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: {
          name: "unknown_tool",
          arguments: { message: "test" },
        },
        id: 1,
      }

      response = @server.handle(request)
      assert_nil response[:result]
      assert_equal(-32602, response[:error][:code])
      assert_equal "Invalid params", response[:error][:message]
      assert_includes response[:error][:data], "Tool not found: unknown_tool"
      assert_instrumentation_data({ method: "tools/call", tool_name: "unknown_tool", error: :invalid_params })
    end

    test "#handle_json returns JSON-RPC error for unknown tool" do
      request = JSON.generate({
        jsonrpc: "2.0",
        method: "tools/call",
        params: {
          name: "unknown_tool",
          arguments: {},
        },
        id: 1,
      })

      response = JSON.parse(@server.handle_json(request), symbolize_names: true)
      assert_nil response[:result]
      assert_equal(-32602, response[:error][:code])
      assert_equal "Invalid params", response[:error][:message]
      assert_includes response[:error][:data], "Tool not found: unknown_tool"
    end

    test "#handle prompts/list returns list of prompts" do
      request = {
        jsonrpc: "2.0",
        method: "prompts/list",
        id: 1,
      }

      response = @server.handle(request)
      assert_equal({ prompts: [@prompt.to_h] }, response[:result])
      assert_instrumentation_data({ method: "prompts/list" })
    end

    test "#handle prompts/get returns templated prompt" do
      request = {
        jsonrpc: "2.0",
        method: "prompts/get",
        id: 1,
        params: {
          name: "test_prompt",
          arguments: { test_argument: "Hello, friend!" },
        },
      }

      expected_result = {
        description: "Hello, world!",
        messages: [
          { role: "user", content: { text: "Hello, world!", type: "text" } },
        ],
      }

      response = @server.handle(request)
      assert_equal(expected_result, response[:result])
      assert_instrumentation_data({ method: "prompts/get", prompt_name: "test_prompt" })
    end

    test "#handle prompts/get returns error if prompt is not found" do
      request = {
        jsonrpc: "2.0",
        method: "prompts/get",
        id: 1,
        params: {
          name: "unknown_prompt",
          arguments: {},
        },
      }

      response = @server.handle(request)
      # An unknown prompt is client input, so it maps to Invalid Params (-32602), not the
      # default Internal Error (-32603); matches the tools/call and completion/complete siblings.
      assert_equal JsonRpcHandler::ErrorCode::INVALID_PARAMS, response.dig(:error, :code)
      assert_equal("Prompt not found unknown_prompt", response[:error][:data])
      assert_instrumentation_data({ method: "prompts/get", error: :prompt_not_found })
    end

    test "#handle prompts/get returns error if prompt arguments are invalid" do
      request = {
        jsonrpc: "2.0",
        method: "prompts/get",
        id: 1,
        params: {
          name: "test_prompt",
          arguments: { "unknown_argument" => "Hello, friend!" },
        },
      }

      response = @server.handle(request)
      # A missing required argument is client input, so it maps to Invalid Params (-32602),
      # not the default Internal Error (-32603).
      assert_equal JsonRpcHandler::ErrorCode::INVALID_PARAMS, response.dig(:error, :code)
      assert_equal "Missing required arguments: test_argument", response[:error][:data]
      assert_instrumentation_data({
        method: "prompts/get",
        prompt_name: "test_prompt",
        error: :missing_required_arguments,
      })
    end

    test "#handle resources/list returns a list of resources" do
      request = {
        jsonrpc: "2.0",
        method: "resources/list",
        id: 1,
      }

      response = @server.handle(request)
      assert_equal({ resources: [@resource.to_h] }, response[:result])
      assert_instrumentation_data({ method: "resources/list" })
    end

    test "#resources_list_handler replaces the served resource collection" do
      other = Resource.new(uri: "https://other.invalid", name: "other", mime_type: "text/plain")
      @server.resources_list_handler { |_params| [other] }

      response = @server.handle({ jsonrpc: "2.0", method: "resources/list", id: 1 })

      assert_equal({ resources: [other.to_h] }, response[:result])
    end

    test "#resources_list_handler receives server_context when it opts in" do
      real = Resource.new(uri: "https://real.invalid", name: "real", mime_type: "text/plain")
      demo = Resource.new(uri: "https://demo.invalid", name: "demo", mime_type: "text/plain")
      @server.resources_list_handler do |_params, server_context:|
        server_context[:authenticated] ? [real] : [demo]
      end

      @server.server_context = { authenticated: false }
      anon = @server.handle({ jsonrpc: "2.0", method: "resources/list", id: 1 })
      @server.server_context = { authenticated: true }
      authed = @server.handle({ jsonrpc: "2.0", method: "resources/list", id: 1 })

      assert_equal({ resources: [demo.to_h] }, anon[:result])
      assert_equal({ resources: [real.to_h] }, authed[:result])
    end

    test "#resources_list_handler paginates and stamps cache hints on the returned collection" do
      first = Resource.new(uri: "https://first.invalid", name: "first", mime_type: "text/plain")
      second = Resource.new(uri: "https://second.invalid", name: "second", mime_type: "text/plain")
      server = Server.new(name: @server_name, resources: [], page_size: 1, ttl_ms: 60_000)
      server.resources_list_handler { |_params| [first, second] }

      response = server.handle({ jsonrpc: "2.0", method: "resources/list", id: 1 })

      assert_equal([first.to_h], response[:result][:resources])
      assert_equal("1", response[:result][:nextCursor])
      assert_equal(60_000, response[:result][:ttlMs])
    end

    test "#resources_list_handler serves a server with no constructor-provided resources" do
      only = Resource.new(uri: "https://only.invalid", name: "only", mime_type: "text/plain")
      server = Server.new(name: @server_name, resources: [])
      server.resources_list_handler { |_params| [only] }

      response = server.handle({ jsonrpc: "2.0", method: "resources/list", id: 1 })

      assert_equal({ resources: [only.to_h] }, response[:result])
    end

    test "#handle resources/read returns an empty array of contents by default" do
      request = {
        jsonrpc: "2.0",
        method: "resources/read",
        id: 1,
        params: {
          uri: "https://test_resource.invalid",
        },
      }

      response = @server.handle(request)
      assert_equal({ contents: [] }, response[:result])
      assert_instrumentation_data({ method: "resources/read", resource_uri: "https://test_resource.invalid" })
    end

    test "#resources_read_handler sets the resources/read handler" do
      @server.resources_read_handler do |request|
        {
          uri: request[:uri],
          mimeType: "text/plain",
          text: "Lorem ipsum dolor sit amet",
        }
      end

      request = {
        jsonrpc: "2.0",
        method: "resources/read",
        id: 1,
        params: {
          uri: "https://test_resource.invalid/my_resource",
        },
      }

      response = @server.handle(request)
      assert_equal(
        { contents: { uri: "https://test_resource.invalid/my_resource", mimeType: "text/plain", text: "Lorem ipsum dolor sit amet" } },
        response[:result],
      )
    end

    test "#handle resources/read returns -32602 with the uri in error data when the handler raises ResourceNotFoundError" do
      # Per SEP-2164, resource-not-found errors use the standard JSON-RPC Invalid Params code (-32602)
      # and carry the requested URI in `data`.
      @server.resources_read_handler do |request|
        raise Server::ResourceNotFoundError.new(request[:uri], request)
      end

      response = @server.handle({
        jsonrpc: "2.0",
        method: "resources/read",
        id: 1,
        params: { uri: "file:///missing.txt" },
      })

      assert_equal(-32602, response[:error][:code])
      assert_equal("Resource not found: file:///missing.txt", response[:error][:message])
      assert_equal({ uri: "file:///missing.txt" }, response[:error][:data])
    end

    test "#handle resources/templates/list returns a list of resource templates" do
      request = {
        jsonrpc: "2.0",
        method: "resources/templates/list",
        id: 1,
      }

      response = @server.handle(request)
      assert_equal(
        {
          resourceTemplates: [@resource_template.to_h],
        },
        response[:result],
      )
      assert_instrumentation_data({ method: "resources/templates/list" })
    end

    class GreetingResource < Resource
      uri "greeting://hello"
      resource_name "greeting"
      mime_type "text/plain"

      class << self
        def contents
          [Resource::TextContents.new(uri: uri, mime_type: mime_type, text: "hello")]
        end
      end
    end

    class UserProfileTemplate < ResourceTemplate
      uri_template "users://{user_id}/profile"
      resource_template_name "user_profile"
      mime_type "text/plain"

      class << self
        def contents(user_id:)
          [Resource::TextContents.new(uri: "users://#{user_id}/profile", mime_type: mime_type, text: "profile of #{user_id}")]
        end
      end
    end

    def read_resource_request(uri)
      {
        jsonrpc: "2.0",
        method: "resources/read",
        id: 1,
        params: { uri: uri },
      }
    end

    test "#handle resources/read auto-routes to a class-based resource by exact URI" do
      configuration = MCP::Configuration.new
      configuration.instrumentation_callback = instrumentation_helper.callback
      server = Server.new(name: "test_server", resources: [GreetingResource], configuration: configuration)

      response = server.handle(read_resource_request("greeting://hello"))

      expected = [{ uri: "greeting://hello", mimeType: "text/plain", text: "hello" }]
      assert_equal({ contents: expected }, response[:result])
      assert_instrumentation_data({ method: "resources/read", resource_uri: "greeting://hello" })
    end

    test "#handle resources/read wraps a single contents object returned by a class-based resource" do
      resource = Resource.define(uri: "single://one", name: "single") do
        Resource::TextContents.new(uri: "single://one", mime_type: "text/plain", text: "only one")
      end
      server = Server.new(name: "test_server", resources: [resource])

      response = server.handle(read_resource_request("single://one"))

      expected = [{ uri: "single://one", mimeType: "text/plain", text: "only one" }]
      assert_equal({ contents: expected }, response[:result])
    end

    test "#handle resources/read passes server_context to contents that opt in" do
      received = nil
      resource = Resource.define(uri: "ctx://resource", name: "ctx") do |server_context:|
        received = server_context
        [Resource::TextContents.new(uri: "ctx://resource", mime_type: "text/plain", text: "ctx")]
      end
      server = Server.new(name: "test_server", resources: [resource])

      server.handle(read_resource_request("ctx://resource"))

      assert_instance_of ServerContext, received
    end

    test "#handle resources/read auto-routes to a class-based resource template with extracted params" do
      configuration = MCP::Configuration.new
      configuration.instrumentation_callback = instrumentation_helper.callback
      server = Server.new(name: "test_server", resource_templates: [UserProfileTemplate], configuration: configuration)

      response = server.handle(read_resource_request("users://42/profile"))

      expected = [{ uri: "users://42/profile", mimeType: "text/plain", text: "profile of 42" }]
      assert_equal({ contents: expected }, response[:result])
      assert_instrumentation_data({
        method: "resources/read",
        resource_uri: "users://42/profile",
        resource_template: "users://{user_id}/profile",
      })
    end

    test "#handle resources/read prefers an exact resource match over a template match" do
      resource = Resource.define(uri: "users://42/profile", name: "pinned_profile") do
        [Resource::TextContents.new(uri: "users://42/profile", mime_type: "text/plain", text: "pinned")]
      end
      server = Server.new(name: "test_server", resources: [resource], resource_templates: [UserProfileTemplate])

      response = server.handle(read_resource_request("users://42/profile"))

      assert_equal "pinned", response[:result][:contents].first[:text]
    end

    test "#handle resources/read returns -32602 for an unknown URI when class-based resources are registered" do
      server = Server.new(name: "test_server", resources: [GreetingResource])

      response = server.handle(read_resource_request("greeting://unknown"))

      assert_equal(-32602, response[:error][:code])
      assert_equal("Resource not found: greeting://unknown", response[:error][:message])
      assert_equal({ uri: "greeting://unknown" }, response[:error][:data])
    end

    test "#handle resources/read returns -32602 for a non-matching URI when class-based templates are registered" do
      server = Server.new(name: "test_server", resource_templates: [UserProfileTemplate])

      response = server.handle(read_resource_request("users://42/settings"))

      assert_equal(-32602, response[:error][:code])
      assert_equal({ uri: "users://42/settings" }, response[:error][:data])
    end

    test "#handle resources/read keeps returning [] for unknown URIs when only instance-based resources are registered" do
      server = Server.new(name: "test_server", resources: [@resource], resource_templates: [@resource_template])

      response = server.handle(read_resource_request("unknown://resource"))

      assert_equal({ contents: [] }, response[:result])
    end

    test "#resources_read_handler overrides auto-routing for class-based resources" do
      server = Server.new(name: "test_server", resources: [GreetingResource])
      server.resources_read_handler do |request|
        [{ uri: request[:uri], mimeType: "text/plain", text: "handler wins" }]
      end

      response = server.handle(read_resource_request("greeting://hello"))

      assert_equal "handler wins", response[:result][:contents].first[:text]
    end

    test "#handle resources/list and resources/templates/list render class-based and instance-based entries together" do
      server = Server.new(
        name: "test_server",
        resources: [@resource, GreetingResource],
        resource_templates: [@resource_template, UserProfileTemplate],
      )

      list_response = server.handle({ jsonrpc: "2.0", method: "resources/list", id: 1 })
      assert_equal [@resource.to_h, GreetingResource.to_h], list_response[:result][:resources]

      templates_response = server.handle({ jsonrpc: "2.0", method: "resources/templates/list", id: 1 })
      assert_equal [@resource_template.to_h, UserProfileTemplate.to_h], templates_response[:result][:resourceTemplates]
    end

    test "#resources= rebuilds the resource index used for auto-routing" do
      server = Server.new(name: "test_server", resources: [GreetingResource])

      replacement = Resource.define(uri: "replacement://res", name: "replacement") do
        [Resource::TextContents.new(uri: "replacement://res", mime_type: "text/plain", text: "replaced")]
      end
      server.resources = [replacement]

      response = server.handle(read_resource_request("replacement://res"))
      assert_equal "replaced", response[:result][:contents].first[:text]

      stale_response = server.handle(read_resource_request("greeting://hello"))
      assert_equal(-32602, stale_response[:error][:code])
    end

    test "#define_resource registers a resource served by auto-routing" do
      server = Server.new(name: "test_server")
      server.define_resource(uri: "defined://res", name: "defined", mime_type: "text/plain") do
        [Resource::TextContents.new(uri: "defined://res", mime_type: "text/plain", text: "defined body")]
      end

      list_response = server.handle({ jsonrpc: "2.0", method: "resources/list", id: 1 })
      assert_equal ["defined"], list_response[:result][:resources].map { |resource| resource[:name] }

      response = server.handle(read_resource_request("defined://res"))
      assert_equal "defined body", response[:result][:contents].first[:text]
    end

    test "#define_resource_template registers a template served by auto-routing" do
      server = Server.new(name: "test_server")
      server.define_resource_template(uri_template: "items://{item_id}", name: "item_template") do |item_id:|
        [Resource::TextContents.new(uri: "items://#{item_id}", mime_type: "text/plain", text: "item #{item_id}")]
      end

      templates_response = server.handle({ jsonrpc: "2.0", method: "resources/templates/list", id: 1 })
      assert_equal ["item_template"], templates_response[:result][:resourceTemplates].map { |template| template[:name] }

      response = server.handle(read_resource_request("items://7"))
      assert_equal "item 7", response[:result][:contents].first[:text]
    end

    test "#configure_logging_level returns empty hash on success" do
      response = @server.handle(
        {
          jsonrpc: "2.0",
          id: 1,
          method: "logging/setLevel",
          params: {
            level: "info",
          },
        },
      )

      assert_equal "2.0", response[:jsonrpc]
      assert_equal 1, response[:id]
      assert_equal({}, response[:result])
      refute response.key?(:error)
    end

    test "#configure_logging_level does not warn after a modern initialize request is counter-offered" do
      # `initialize` asking for 2026-07-28 lands on 2025-11-25, where logging is not deprecated,
      # so no warning fires. On the modern lifecycle itself `logging/setLevel` is a removed method
      # and never reaches this handler.
      server = Server.new(tools: [TestTool])
      server.handle(
        {
          jsonrpc: "2.0",
          method: "initialize",
          id: 1,
          params: {
            protocolVersion: "2026-07-28",
            capabilities: {},
            clientInfo: { name: "test-client", version: "1.0" },
          },
        },
      )

      response = nil
      assert_no_deprecation_warning do
        response = server.handle(
          {
            jsonrpc: "2.0",
            id: 2,
            method: "logging/setLevel",
            params: {
              level: "info",
            },
          },
        )
      end

      assert_empty response[:result]
    end

    test "#configure_logging_level does not warn when negotiated protocol version is older" do
      server = Server.new(tools: [TestTool])
      server.handle(
        {
          jsonrpc: "2.0",
          method: "initialize",
          id: 1,
          params: {
            protocolVersion: "2025-11-25",
            capabilities: {},
            clientInfo: { name: "test-client", version: "1.0" },
          },
        },
      )

      assert_no_deprecation_warning do
        server.handle(
          {
            jsonrpc: "2.0",
            id: 2,
            method: "logging/setLevel",
            params: {
              level: "info",
            },
          },
        )
      end
    end

    test "#configure_logging_level returns an error object when invalid log level is provided" do
      server = Server.new(
        tools: [TestTool],
        configuration: Configuration.new(validate_tool_call_arguments: true),
      )

      response = server.handle(
        {
          jsonrpc: "2.0",
          id: 1,
          method: "logging/setLevel",
          params: {
            level: "invalid_level",
          },
        },
      )

      assert_equal "2.0", response[:jsonrpc]
      assert_equal 1, response[:id]
      assert_equal(-32602, response[:error][:code])
      assert_includes response[:error][:data], "Invalid log level invalid_level"
    end

    test "#configure_logging_level returns an error object when server has not logging capability" do
      server = Server.new(
        tools: [TestTool],
        configuration: Configuration.new(validate_tool_call_arguments: true),
        capabilities: {
          tools: { listChanged: true },
          prompts: { listChanged: true },
          resources: { listChanged: true },
        },
      )

      response = server.handle(
        {
          jsonrpc: "2.0",
          id: 1,
          method: "logging/setLevel",
          params: {
            level: "debug",
          },
        },
      )

      assert_equal "2.0", response[:jsonrpc]
      assert_equal 1, response[:id]
      assert_equal(-32603, response[:error][:code])
      assert_includes response[:error][:data], "Server does not support logging"
    end

    test "#handle method with missing required top-level capability returns an error" do
      @server.capabilities = {}

      response = @server.handle({ jsonrpc: "2.0", method: "prompts/list", id: 1 })
      assert_equal "Server does not support prompts (required for prompts/list)", response[:error][:data]

      response = @server.handle({ jsonrpc: "2.0", method: "resources/list", id: 1 })
      assert_equal "Server does not support resources (required for resources/list)", response[:error][:data]
    end

    test "#handle method with missing required nested capability returns an error" do
      @server.capabilities = { resources: {} }
      response = @server.handle({ jsonrpc: "2.0", method: "resources/subscribe", id: 1 })
      assert_equal "Server does not support resources.subscribe (required for resources/subscribe)",
        response[:error][:data]
    end

    test "#handle unknown method returns method not found error" do
      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "unknown_method",
      }

      response = @server.handle(request)

      assert_equal "Method not found", response[:error][:message]
      assert_equal "unknown_method", response[:error][:data]
      assert_instrumentation_data({ method: "unsupported_method" })
    end

    test "#handle handles custom methods" do
      @server.define_custom_method(method_name: "add") do |params|
        params[:a] + params[:b]
      end

      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "add",
        params: { a: 1, b: 2 },
      }

      response = @server.handle(request)
      assert_equal 3, response[:result]
      assert_instrumentation_data({ method: "add" })
    end

    test "#handle handles custom notifications" do
      @server.define_custom_method(method_name: "notify") do
        nil
      end

      request = {
        jsonrpc: "2.0",
        method: "notify",
      }

      response = @server.handle(request)
      assert_nil response
      assert_instrumentation_data({ method: "notify" })
    end

    test "#handle tools/call invokes around_request with correct data" do
      call_log = []
      data_before = nil
      data_after = nil

      configuration = MCP::Configuration.new
      configuration.instrumentation_callback = instrumentation_helper.callback
      configuration.around_request = ->(data, &request_handler) {
        data_before = data.dup
        call_log << :before
        request_handler.call
        call_log << :after
        data_after = data.dup
      }

      tool = Tool.define(name: "around_test_tool", description: "Test") do |arg:|
        Tool::Response.new([{ type: "text", text: arg }])
      end

      server = Server.new(name: "test_server", tools: [tool], configuration: configuration)

      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: "around_test_tool", arguments: { arg: "hello" } },
        id: 1,
      }

      server.handle(request)

      assert_equal([:before, :after], call_log)
      assert_equal("tools/call", data_before[:method])
      assert_nil(data_before[:tool_name])
      assert_equal("around_test_tool", data_after[:tool_name])
      assert_equal({ arg: "hello" }, data_after[:tool_arguments])
    end

    test "#handle around_request and instrumentation_callback coexist" do
      around_called = false
      callback_data = nil

      configuration = MCP::Configuration.new
      configuration.around_request = ->(_data, &request_handler) {
        around_called = true
        request_handler.call
      }
      configuration.instrumentation_callback = ->(data) {
        callback_data = data.dup
      }

      server = Server.new(name: "test_server", configuration: configuration)

      request = {
        jsonrpc: "2.0",
        method: "ping",
        id: 1,
      }

      server.handle(request)

      assert(around_called)
      assert_equal("ping", callback_data[:method])
      assert(callback_data[:duration])
    end

    test "#handle reports exception and sets error when around_request raises" do
      reported_exception = nil
      reported_context = nil
      callback_data = nil

      configuration = MCP::Configuration.new
      configuration.exception_reporter = ->(e, server_context) {
        reported_exception = e
        reported_context = server_context
      }
      configuration.instrumentation_callback = ->(data) { callback_data = data.dup }
      configuration.around_request = ->(_data, &_request_handler) { raise "around_request failure" }

      server = Server.new(name: "test_server", configuration: configuration)

      request = {
        jsonrpc: "2.0",
        method: "ping",
        id: 1,
      }

      response = server.handle(request)

      assert_equal("around_request failure", reported_exception.message)
      assert_equal({ request: request }, reported_context)
      assert_equal(:internal_error, callback_data[:error])
      assert_equal(JsonRpcHandler::ErrorCode::INTERNAL_ERROR, response[:error][:code])
    end

    test "#handle does not double-report exception_reporter when a tool handler raises" do
      report_count = 0
      configuration = MCP::Configuration.new
      configuration.exception_reporter = ->(_e, _server_context) { report_count += 1 }

      failing_tool = Tool.define(name: "failing_tool", description: "Always fails") do
        raise "tool failure"
      end

      server = Server.new(name: "test_server", tools: [failing_tool], configuration: configuration)

      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: "failing_tool", arguments: {} },
        id: 1,
      }

      server.handle(request)

      assert_equal(1, report_count)
    end

    test "#handle reports both exceptions when around_request ensure raises after tool failure" do
      reported = []
      configuration = MCP::Configuration.new
      configuration.exception_reporter = ->(e, _server_context) { reported << e.message }
      configuration.around_request = ->(_data, &request_handler) do
        request_handler.call
      ensure
        raise "around ensure boom"
      end

      failing_tool = Tool.define(name: "failing_tool", description: "Always fails") do
        raise "tool failure"
      end

      server = Server.new(name: "test_server", tools: [failing_tool], configuration: configuration)

      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: "failing_tool", arguments: {} },
        id: 1,
      }

      response = server.handle(request)

      assert_equal(["tool failure", "around ensure boom"], reported)
      assert_equal(JsonRpcHandler::ErrorCode::INTERNAL_ERROR, response[:error][:code])
      assert_nil(response[:error][:data])
    end

    test "#handle reports the same exception object reused across requests on every call" do
      reported = []
      configuration = MCP::Configuration.new
      configuration.exception_reporter = ->(e, _server_context) { reported << e }

      shared_error = RuntimeError.new("reused")
      shared_tool = Tool.define(name: "shared_failing_tool", description: "Always fails") do
        raise shared_error
      end

      server = Server.new(name: "test_server", tools: [shared_tool], configuration: configuration)

      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: "shared_failing_tool", arguments: {} },
        id: 1,
      }

      server.handle(request)
      server.handle(request)

      assert_equal(2, reported.size)
      assert_same(shared_error, reported[0])
      assert_same(shared_error, reported[1])
    end

    test "#handle reports frozen exceptions raised by tool handlers without wrapping them" do
      reported = []
      configuration = MCP::Configuration.new
      configuration.exception_reporter = ->(e, _server_context) { reported << e }

      frozen_error = RuntimeError.new("frozen failure").freeze
      frozen_tool = Tool.define(name: "frozen_tool", description: "Raises frozen") do
        raise frozen_error
      end

      server = Server.new(name: "test_server", tools: [frozen_tool], configuration: configuration)

      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: "frozen_tool", arguments: {} },
        id: 1,
      }

      response = server.handle(request)

      assert_equal([frozen_error], reported)
      assert_equal("Internal error calling tool frozen_tool", response[:error][:data])
    end

    test "#handle still reports via exception_reporter when around_request swallows the tool failure" do
      reported = []
      configuration = MCP::Configuration.new
      configuration.exception_reporter = ->(e, _server_context) { reported << e.message }
      configuration.around_request = ->(_data, &request_handler) do
        request_handler.call
      rescue StandardError
        { swallowed: true }
      end

      failing_tool = Tool.define(name: "failing_tool", description: "Always fails") do
        raise "tool failure"
      end

      server = Server.new(name: "test_server", tools: [failing_tool], configuration: configuration)

      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: "failing_tool", arguments: {} },
        id: 1,
      }

      response = server.handle(request)

      assert_equal(["tool failure"], reported)
      assert_equal({ swallowed: true }, response[:result])
    end

    test "#handle concurrent requests on a shared server report exceptions independently" do
      reported = Queue.new
      configuration = MCP::Configuration.new
      configuration.exception_reporter = ->(e, _server_context) { reported << e.message }

      failing_tool = Tool.define(name: "concurrent_tool", description: "Raises per-thread") do |i:|
        raise "thread #{i}"
      end

      server = Server.new(name: "test_server", tools: [failing_tool], configuration: configuration)

      threads = 10.times.map do |i|
        Thread.new do
          server.handle({
            jsonrpc: "2.0",
            method: "tools/call",
            params: { name: "concurrent_tool", arguments: { i: i } },
            id: i,
          })
        end
      end
      threads.each(&:join)

      messages = []
      messages << reported.pop until reported.empty?

      assert_equal(10.times.map { |i| "thread #{i}" }.sort, messages.sort)
    end

    test "#define_custom_method raises an error if the method is already defined" do
      assert_raises(Server::MethodAlreadyDefinedError) do
        @server.define_custom_method(method_name: "tools/call") do
          nil
        end
      end
    end

    test "the global configuration is used if no configuration is passed to the server" do
      server = Server.new(name: "test_server")
      assert_equal MCP.configuration.instrumentation_callback,
        server.configuration.instrumentation_callback
      assert_equal MCP.configuration.exception_reporter,
        server.configuration.exception_reporter
    end

    test "the server configuration takes precedence over the global configuration" do
      configuration = MCP::Configuration.new
      local_callback = ->(data) { puts "Local callback #{data.inspect}" }
      local_exception_reporter = ->(exception, server_context) {
        puts "Local exception reporter #{exception.inspect} #{server_context.inspect}"
      }
      configuration.instrumentation_callback = local_callback
      configuration.exception_reporter = local_exception_reporter

      server = Server.new(name: "test_server", configuration: configuration)

      assert_equal local_callback, server.configuration.instrumentation_callback
      assert_equal local_exception_reporter, server.configuration.exception_reporter
    end

    test "server uses the latest handshake version when not configured" do
      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: initialize_params,
      }

      response = @server.handle(request)
      assert_equal Configuration::LATEST_HANDSHAKE_PROTOCOL_VERSION, response[:result][:protocolVersion]
    end

    test "server response does not include optional parameters when configured" do
      server = Server.new(title: "Example Server Display Name", name: "test_server", website_url: "https://example.com")
      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: initialize_params,
      }

      response = server.handle(request)
      server_info = response[:result][:serverInfo]

      assert_equal("Example Server Display Name", server_info[:title])
      assert_equal("https://example.com", server_info[:websiteUrl])
    end

    test "server response does not include optional parameters when not configured" do
      server = Server.new(name: "test_server")
      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: initialize_params,
      }

      response = server.handle(request)
      refute response[:result][:serverInfo].key?(:title)
      refute response[:result][:serverInfo].key?(:website_url)
    end

    test "server response does not include icons when icons is empty" do
      server = Server.new(name: "test_server")
      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: initialize_params,
      }
      response = server.handle(request)

      refute response[:result][:serverInfo].key?(:icons)
    end

    test "server response does not include icons when icons is nil" do
      server = Server.new(name: "test_server", icons: nil)
      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: initialize_params,
      }
      response = server.handle(request)

      refute response[:result][:serverInfo].key?(:icons)
    end

    test "server response includes icons when icons is present" do
      server = Server.new(
        name: "test_server",
        icons: [Icon.new(mime_type: "image/png", sizes: ["48x48"], src: "https://example.com", theme: "light")],
      )
      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: initialize_params,
      }
      response = server.handle(request)
      expected_icons = [{ mimeType: "image/png", sizes: ["48x48"], src: "https://example.com", theme: "light" }]

      assert_equal expected_icons, response[:result][:serverInfo][:icons]
    end

    test "server uses default version when not configured" do
      server = Server.new(name: "test_server")
      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: initialize_params,
      }

      response = server.handle(request)
      assert_equal Server::DEFAULT_VERSION, response[:result][:serverInfo][:version]
    end

    test "server uses instructions when not configured" do
      server = Server.new(name: "test_server")
      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: initialize_params,
      }

      response = server.handle(request)
      refute response[:result].key?(:instructions)
    end

    test "server uses description when configured with protocol version 2025-11-25" do
      configuration = Configuration.new(protocol_version: "2025-11-25")
      server = Server.new(description: "This is the MCP server used during tests.", name: "test_server", configuration: configuration)
      assert_equal("This is the MCP server used during tests.", server.description)
    end

    test "raises error if description is used with protocol version 2025-06-18" do
      configuration = Configuration.new(protocol_version: "2025-06-18")

      exception = assert_raises(ArgumentError) do
        Server.new(description: "This is the MCP server used during tests.", name: "test_server", configuration: configuration)
      end
      assert_equal("Error occurred in server_info. `description` is not supported in protocol version 2025-06-18 or earlier", exception.message)
    end

    test "server uses instructions when configured with protocol version 2025-03-26" do
      configuration = Configuration.new(protocol_version: "2025-03-26")
      server = Server.new(name: "test_server", instructions: "The server instructions.", configuration: configuration)
      assert_equal("The server instructions.", server.instructions)
    end

    test "raises error if instructions are used with protocol version 2024-11-05" do
      configuration = Configuration.new(protocol_version: "2024-11-05")

      exception = assert_raises(ArgumentError) do
        Server.new(name: "test_server", instructions: "The server instructions.", configuration: configuration)
      end
      assert_equal("`instructions` supported by protocol version 2025-03-26 or higher", exception.message)
    end

    test "server uses annotations when configured with protocol version 2025-03-26" do
      configuration = Configuration.new(protocol_version: "2025-03-26")
      server = Server.new(name: "test_server", configuration: configuration)
      server.define_tool(
        name: "defined_tool",
        annotations: { title: "test server" },
      )
      assert_equal({ destructiveHint: true, idempotentHint: false, openWorldHint: true, readOnlyHint: false, title: "test server" }, server.tools.first[1].annotations.to_h)
    end

    test "raises error if annotations are used with protocol version 2024-11-05" do
      configuration = Configuration.new(protocol_version: "2024-11-05")
      exception = assert_raises(ArgumentError) do
        server = Server.new(name: "test_server", configuration: configuration)
        server.define_tool(
          name: "defined_tool",
          annotations: { title: "test server" },
        )
      end
      assert_equal("Error occurred in defined_tool. `annotations` are supported by protocol version 2025-03-26 or higher", exception.message)
    end

    test "raises error if `title` of `server_info` is used with protocol version 2025-03-26" do
      configuration = Configuration.new(protocol_version: "2025-03-26")

      exception = assert_raises(ArgumentError) do
        Server.new(name: "test_server", title: "Example Server Display Name", configuration: configuration)
      end
      assert_equal("Error occurred in server_info. `title` or `website_url` are not supported in protocol version 2025-03-26 or earlier", exception.message)
    end

    test "raises error if `website_url` of `server_info` is used with protocol version 2025-03-26" do
      configuration = Configuration.new(protocol_version: "2025-03-26")

      exception = assert_raises(ArgumentError) do
        Server.new(name: "test_server", website_url: "https://example.com", configuration: configuration)
      end
      assert_equal("Error occurred in server_info. `title` or `website_url` are not supported in protocol version 2025-03-26 or earlier", exception.message)
    end

    test "raises error if `title` of tool is used with protocol version 2025-03-26" do
      configuration = Configuration.new(protocol_version: "2025-03-26")
      server = Server.new(name: "test_server", configuration: configuration)

      exception = assert_raises(ArgumentError) do
        server.define_tool(
          title: "Test tool",
        )
      end
      assert_equal("Error occurred in Test tool. `title` is not supported in protocol version 2025-03-26 or earlier", exception.message)
    end

    test "raises error if `title` of prompt is used with protocol version 2025-03-26" do
      configuration = Configuration.new(protocol_version: "2025-03-26")
      server = Server.new(name: "test_server", configuration: configuration)

      exception = assert_raises(ArgumentError) do
        server.define_prompt(
          title: "Test prompt",
        )
      end
      assert_equal("Error occurred in Test prompt. `title` is not supported in protocol version 2025-03-26 or earlier", exception.message)
    end

    test "raises error if `title` of resource is used with protocol version 2025-03-26" do
      configuration = Configuration.new(protocol_version: "2025-03-26")

      resource = Resource.new(
        uri: "https://test_resource.invalid",
        name: "test-resource",
        title: "Test resource",
      )
      exception = assert_raises(ArgumentError) do
        Server.new(name: "test_server", resources: [resource], configuration: configuration)
      end
      assert_equal("Error occurred in Test resource. `title` is not supported in protocol version 2025-03-26 or earlier", exception.message)
    end

    test "raises error if `title` of class-based resource is used with protocol version 2025-03-26" do
      configuration = Configuration.new(protocol_version: "2025-03-26")

      resource = Resource.define(
        uri: "https://test_resource.invalid",
        name: "test-resource",
        title: "Test resource",
      )
      exception = assert_raises(ArgumentError) do
        Server.new(name: "test_server", resources: [resource], configuration: configuration)
      end
      assert_equal("Error occurred in Test resource. `title` is not supported in protocol version 2025-03-26 or earlier", exception.message)
    end

    test "allows `$ref` in tool input schema with protocol version 2025-11-25" do
      tool = Tool.define(
        name: "ref_tool",
        description: "Tool with $ref",
        input_schema: {
          type: "object",
          "$defs": { address: { type: "object", properties: { city: { type: "string" } } } },
          properties: { address: { "$ref": "#/$defs/address" } },
        },
      )
      configuration = Configuration.new(protocol_version: "2025-11-25")

      assert_nothing_raised do
        Server.new(name: "test_server", tools: [tool], configuration: configuration)
      end
    end

    test "raises error if `$ref` in tool input schema is used with protocol version 2025-06-18" do
      tool = Tool.define(
        name: "ref_tool",
        description: "Tool with $ref",
        input_schema: {
          type: "object",
          "$defs": { address: { type: "object", properties: { city: { type: "string" } } } },
          properties: { address: { "$ref": "#/$defs/address" } },
        },
      )
      configuration = Configuration.new(protocol_version: "2025-06-18")

      exception = assert_raises(ArgumentError) do
        Server.new(name: "test_server", tools: [tool], configuration: configuration)
      end
      assert_equal(
        "Error occurred in ref_tool. `$ref` in input schemas is supported by protocol version 2025-11-25 or higher",
        exception.message,
      )
    end

    test "raises error if `title` of resource template is used with protocol version 2025-03-26" do
      configuration = Configuration.new(protocol_version: "2025-03-26")

      resource = Resource.new(
        uri: "https://test_resource.invalid",
        name: "test-resource",
        title: "Test resource template",
      )
      exception = assert_raises(ArgumentError) do
        Server.new(name: "test_server", resources: [resource], configuration: configuration)
      end
      assert_equal("Error occurred in Test resource template. `title` is not supported in protocol version 2025-03-26 or earlier", exception.message)
    end

    test "#define_tool adds a tool to the server" do
      @server.define_tool(
        name: "defined_tool",
        description: "Defined tool",
        input_schema: { type: "object", properties: { message: { type: "string" } }, required: ["message"] },
        output_schema: { type: "object", properties: { response: { type: "string" } }, required: ["response"] },
        meta: { foo: "bar" },
      ) do |message:|
        Tool::Response.new({ "response" => message })
      end

      stored_tool = @server.tools["defined_tool"]
      assert_not_nil(stored_tool)
      assert_equal(MCP::Tool::OutputSchema.new({ type: "object", properties: { response: { type: "string" } }, required: ["response"] }), stored_tool.output_schema)

      response = @server.handle({
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: "defined_tool", arguments: { message: "success" } },
        id: 1,
      })

      assert_equal({ content: { "response" => "success" }, isError: false }, response[:result])
    end

    test "#define_tool adds a tool with duplicated tool name to the server" do
      error = assert_raises(MCP::ToolNotUnique) do
        @server.define_tool(
          name: "test_tool", # NOTE: Already registered tool name
          description: "Defined tool",
          input_schema: { type: "object", properties: { message: { type: "string" } }, required: ["message"] },
          meta: { foo: "bar" },
        ) do |message:|
          Tool::Response.new(message)
        end
      end
      assert_match(/\ATool names should be unique. Use `tool_name` to assign unique names to/, error.message)
    end

    test "#define_tool call definition allows tool arguments and server context" do
      @server.server_context = { user_id: "123" }

      @server.define_tool(
        name: "defined_tool",
        description: "Defined tool",
        input_schema: { type: "object", properties: { message: { type: "string" } }, required: ["message"] },
      ) do |message:, server_context:|
        Tool::Response.new("success #{message} #{server_context[:user_id]}")
      end

      response = @server.handle({
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: "defined_tool", arguments: { message: "hello" } },
        id: 1,
      })

      assert_equal({ content: "success hello 123", isError: false }, response[:result])
    end

    test "#define_prompt adds a tool to the server" do
      @server.define_prompt(name: "defined_prompt", description: "Defined prompt", arguments: []) do
        Prompt::Result.new(
          description: "a prompt description",
          messages: [Prompt::Message.new(role: "user", content: Content::Text.new("a prompt message"))],
        )
      end

      response = @server.handle({
        jsonrpc: "2.0",
        method: "prompts/get",
        params: { name: "defined_prompt", arguments: {} },
        id: 1,
      })

      assert_equal(
        {
          description: "a prompt description",
          messages: [{ role: "user", content: { text: "a prompt message", type: "text" } }],
        },
        response[:result],
      )
    end

    test "server protocol version can be overridden via configuration" do
      custom_version = "2025-03-26"
      configuration = Configuration.new(protocol_version: custom_version)
      server = Server.new(name: "test_server", configuration: configuration)

      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: initialize_params(protocolVersion: "1999-01-01"),
      }

      response = server.handle(request)
      assert_equal custom_version, response[:result][:protocolVersion]
    end

    test "server negotiates protocol version when client requests a supported version" do
      server = Server.new(name: "test_server")

      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: initialize_params(protocolVersion: "2025-06-18"),
      }

      response = server.handle(request)
      assert_equal "2025-06-18", response[:result][:protocolVersion]
    end

    test "server falls back to the latest handshake version when client requests unsupported version" do
      server = Server.new(name: "test_server")

      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: initialize_params(protocolVersion: "1999-01-01"),
      }

      response = server.handle(request)
      assert_equal Configuration::LATEST_HANDSHAKE_PROTOCOL_VERSION, response[:result][:protocolVersion]
    end

    test "server counter-offers 2025-11-25 when the client requests 2026-07-28 via initialize" do
      # Per the SEP-2575 era model, `initialize` negotiates legacy versions only: a modern version carries
      # its own version on every request and has no handshake at all. The TypeScript and Python servers
      # answer the same way.
      server = Server.new(name: "test_server")

      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: initialize_params(protocolVersion: "2026-07-28"),
      }

      response = server.handle(request)
      assert_equal "2025-11-25", response[:result][:protocolVersion]
    end

    test "server removes description and icons from server_info when negotiating to 2025-06-18" do
      server = Server.new(
        name: "test_server",
        description: "A test server",
        icons: [Icon.new(src: "https://example.com/icon.png")],
      )

      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: initialize_params(protocolVersion: "2025-06-18"),
      }

      response = server.handle(request)
      assert_equal "2025-06-18", response[:result][:protocolVersion]
      refute response[:result][:serverInfo].key?(:description)
      refute response[:result][:serverInfo].key?(:icons)
    end

    test "server removes title and websiteUrl when negotiating to 2025-03-26" do
      server = Server.new(name: "test_server", title: "Test Server", website_url: "https://example.com")

      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: initialize_params(protocolVersion: "2025-03-26"),
      }

      response = server.handle(request)
      assert_equal "2025-03-26", response[:result][:protocolVersion]
      refute response[:result][:serverInfo].key?(:title)
      refute response[:result][:serverInfo].key?(:websiteUrl)
    end

    test "server removes instructions when negotiating to 2024-11-05" do
      server = Server.new(name: "test_server", instructions: "Some instructions")

      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: initialize_params(protocolVersion: "2024-11-05"),
      }

      response = server.handle(request)
      assert_equal "2024-11-05", response[:result][:protocolVersion]
      refute response[:result].key?(:instructions)
    end

    test "tools/call returns tool execution error for missing arguments" do
      configuration = Configuration.new(validate_tool_call_arguments: true)
      configuration.instrumentation_callback = instrumentation_helper.callback
      server = Server.new(tools: [TestTool], configuration: configuration)

      response = server.handle(
        {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: {
            name: "test_tool",
          },
        },
      )

      assert_equal "2.0", response[:jsonrpc]
      assert_equal 1, response[:id]
      assert_nil response[:error]
      assert(response[:result][:isError])
      assert_equal "text", response[:result][:content][0][:type]
      assert_includes response[:result][:content][0][:text], "Missing required arguments"
      assert_instrumentation_data({
        method: "tools/call",
        tool_name: "test_tool",
        tool_arguments: {},
        error: :missing_required_arguments,
      })
    end

    test "tools/call returns tool execution error for invalid arguments when validate_tool_call_arguments is true" do
      configuration = Configuration.new(validate_tool_call_arguments: true)
      configuration.instrumentation_callback = instrumentation_helper.callback
      server = Server.new(tools: [TestTool], configuration: configuration)

      response = server.handle(
        {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: {
            name: "test_tool",
            arguments: { message: 123 },
          },
        },
      )

      assert_equal "2.0", response[:jsonrpc]
      assert_equal 1, response[:id]
      assert_nil response[:error]
      assert(response[:result][:isError])
      assert_equal "text", response[:result][:content][0][:type]
      assert_includes response[:result][:content][0][:text], "Invalid arguments"
      assert_instrumentation_data({
        method: "tools/call",
        tool_name: "test_tool",
        tool_arguments: { message: 123 },
        error: :invalid_schema,
      })
    end

    test "tools/call returns tool execution error for nested schema validation failure" do
      server = Server.new(
        tools: [ComplexTypesTool],
        configuration: Configuration.new(validate_tool_call_arguments: true),
      )

      response = server.handle(
        {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: {
            name: "complex_types_tool",
            arguments: {
              numbers: [1, 2, 3],
              strings: ["a", "b", "c"],
              objects: [{ name: 123 }],
            },
          },
        },
      )

      assert_nil response[:error]
      assert(response[:result][:isError])
      assert_equal "text", response[:result][:content][0][:type]
      assert_includes response[:result][:content][0][:text], "Invalid arguments"
    end

    test "tools/call skips argument validation when validate_tool_call_arguments is false" do
      server = Server.new(
        tools: [TestTool],
        configuration: Configuration.new(validate_tool_call_arguments: false),
      )

      response = server.handle(
        {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: {
            name: "test_tool",
            arguments: { message: 123 },
          },
        },
      )

      assert_equal "2.0", response[:jsonrpc]
      assert_equal 1, response[:id]
      assert response[:result], "Expected result key in response"
      assert_equal "text", response[:result][:content][0][:type]
      assert_equal "OK", response[:result][:content][0][:content]
    end

    test "tools/call validates arguments with complex types" do
      server = Server.new(
        tools: [ComplexTypesTool],
        configuration: Configuration.new(validate_tool_call_arguments: true),
      )

      response = server.handle(
        {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: {
            name: "complex_types_tool",
            arguments: {
              numbers: [1, 2, 3],
              strings: ["a", "b", "c"],
              objects: [{ name: "test" }],
            },
          },
        },
      )

      assert_equal "2.0", response[:jsonrpc]
      assert_equal 1, response[:id]
      assert response[:result], "Expected result key in response"
      assert_equal "text", response[:result][:content][0][:type]
      assert_equal "OK", response[:result][:content][0][:content]
    end

    test "tools/call allows additional properties by default" do
      server = Server.new(
        tools: [TestTool],
        configuration: Configuration.new(validate_tool_call_arguments: true),
      )

      response = server.handle(
        {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: {
            name: "test_tool",
            arguments: {
              message: "Hello, world!",
              other_property: "I am allowed",
            },
          },
        },
      )

      assert_equal "2.0", response[:jsonrpc]
      assert_equal 1, response[:id]
      assert response[:result], "Expected result key in response"
      assert_equal "text", response[:result][:content][0][:type]
      assert_equal "OK", response[:result][:content][0][:content]
    end

    test "tools/call returns tool execution error when additionalProperties set to false" do
      server = Server.new(
        tools: [TestToolWithAdditionalPropertiesSetToFalse],
        configuration: Configuration.new(validate_tool_call_arguments: true),
      )

      response = server.handle(
        {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: {
            name: "test_tool_with_additional_properties_set_to_false",
            arguments: {
              message: "Hello, world!",
              extra: 123,
            },
          },
        },
      )

      assert_equal "2.0", response[:jsonrpc]
      assert_equal 1, response[:id]
      assert_nil response[:error]
      assert(response[:result][:isError])
      assert_equal "text", response[:result][:content][0][:type]
      assert_includes response[:result][:content][0][:text], "Invalid arguments"
    end

    test "tools/call skips output schema validation by default" do
      tool = Tool.define(
        name: "invalid_structured_content_tool",
        output_schema: {
          type: "object",
          properties: { result: { type: "string" } },
          required: ["result"],
        },
      ) do
        Tool::Response.new(
          [{ type: "text", text: "ok" }],
          structured_content: { result: 123 },
        )
      end
      server = Server.new(tools: [tool])

      response = server.handle({
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: { name: "invalid_structured_content_tool" },
      })

      assert_nil response[:error]
      assert_equal({ result: 123 }, response[:result][:structuredContent])
    end

    test "tools/call validates structuredContent against output schema when enabled" do
      tool = Tool.define(
        name: "valid_structured_content_tool",
        output_schema: {
          type: "object",
          properties: { result: { type: "string" } },
          required: ["result"],
        },
      ) do
        Tool::Response.new(
          [{ type: "text", text: "ok" }],
          structured_content: { result: "success" },
        )
      end
      server = Server.new(
        tools: [tool],
        configuration: Configuration.new(validate_tool_call_results: true),
      )

      response = server.handle({
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: { name: "valid_structured_content_tool" },
      })

      assert_nil response[:error]
      assert_equal({ result: "success" }, response[:result][:structuredContent])
    end

    test "tools/call returns JSON-RPC error for invalid structuredContent when output schema validation is enabled" do
      tool = Tool.define(
        name: "invalid_structured_content_tool",
        output_schema: {
          type: "object",
          properties: { result: { type: "string" } },
          required: ["result"],
        },
      ) do
        Tool::Response.new(
          [{ type: "text", text: "ok" }],
          structured_content: { result: 123 },
        )
      end
      server = Server.new(
        tools: [tool],
        configuration: Configuration.new(validate_tool_call_results: true),
      )

      response = server.handle({
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: { name: "invalid_structured_content_tool" },
      })

      assert_nil response[:result]
      assert_equal(-32603, response[:error][:code])
      assert_equal "Internal error", response[:error][:message]
      assert_equal "Internal error calling tool invalid_structured_content_tool", response[:error][:data]
    end

    test "tools/call returns JSON-RPC error when output schema validation is enabled and structuredContent is missing" do
      tool = Tool.define(
        name: "missing_structured_content_tool",
        output_schema: {
          type: "object",
          properties: { result: { type: "string" } },
          required: ["result"],
        },
      ) do
        Tool::Response.new([{ type: "text", text: "ok" }])
      end
      server = Server.new(
        tools: [tool],
        configuration: Configuration.new(validate_tool_call_results: true),
      )

      response = server.handle({
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: { name: "missing_structured_content_tool" },
      })

      assert_nil response[:result]
      assert_equal(-32603, response[:error][:code])
      assert_equal "Internal error", response[:error][:message]
      assert_equal "Internal error calling tool missing_structured_content_tool", response[:error][:data]
    end

    test "tools/call skips output schema validation for error responses" do
      tool = Tool.define(
        name: "error_response_tool",
        output_schema: {
          type: "object",
          properties: { result: { type: "string" } },
          required: ["result"],
        },
      ) do
        Tool::Response.new(
          [{ type: "text", text: "failed" }],
          error: true,
          structured_content: { result: 123 },
        )
      end
      server = Server.new(
        tools: [tool],
        configuration: Configuration.new(validate_tool_call_results: true),
      )

      response = server.handle({
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: { name: "error_response_tool" },
      })

      assert_nil response[:error]
      assert response[:result][:isError]
      assert_equal({ result: 123 }, response[:result][:structuredContent])
    end

    test "tools/call returns JSON-RPC -32602 protocol error when tool is not found" do
      server = Server.new(
        tools: [TestTool],
      )

      response = server.handle(
        {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: {
            name: "unknown_tool",
            arguments: {},
          },
        },
      )

      assert_nil response[:result]
      assert_equal(-32602, response[:error][:code])
      assert_equal "Invalid params", response[:error][:message]
      assert_includes response[:error][:data], "Tool not found: unknown_tool"
    end

    test "#handle completion/complete returns default completion result" do
      prompt = Prompt.define(name: "test") {}
      server = Server.new(
        name: "test_server",
        prompts: [prompt],
        capabilities: { completions: {} },
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/prompt", name: "test" },
          argument: { name: "arg", value: "val" },
        },
      })

      assert_equal(
        {
          jsonrpc: "2.0",
          id: 2,
          result: { completion: { values: [], hasMore: false } },
        },
        response,
      )
    end

    test "#handle completion/complete with custom handler for ref/prompt" do
      prompt = Prompt.define(
        name: "code_review",
        arguments: [Prompt::Argument.new(name: "language", required: true)],
      ) {}
      server = Server.new(
        name: "test_server",
        prompts: [prompt],
        capabilities: { completions: {} },
      )

      server.completion_handler do |_params|
        { completion: { values: ["python", "pytorch", "pyside"], total: 10, hasMore: true } }
      end

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/prompt", name: "code_review" },
          argument: { name: "language", value: "py" },
        },
      })

      assert_equal(
        {
          jsonrpc: "2.0",
          id: 2,
          result: { completion: { values: ["python", "pytorch", "pyside"], total: 10, hasMore: true } },
        },
        response,
      )
    end

    test "#handle completion/complete with custom handler for ref/resource" do
      template = ResourceTemplate.new(
        uri_template: "file:///{path}",
        name: "file",
      )
      server = Server.new(
        name: "test_server",
        resource_templates: [template],
        capabilities: { completions: {} },
      )

      server.completion_handler do |_params|
        { completion: { values: ["file:///src", "file:///spec"], hasMore: false } }
      end

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/resource", uri: "file:///{path}" },
          argument: { name: "path", value: "s" },
        },
      })

      assert_equal(
        {
          jsonrpc: "2.0",
          id: 2,
          result: { completion: { values: ["file:///src", "file:///spec"], hasMore: false } },
        },
        response,
      )
    end

    test "#handle completion/complete passes context arguments to handler" do
      prompt = Prompt.define(
        name: "code_review",
        arguments: [
          Prompt::Argument.new(name: "language", required: true),
          Prompt::Argument.new(name: "framework", required: false),
        ],
      ) {}
      server = Server.new(
        name: "test_server",
        prompts: [prompt],
        capabilities: { completions: {} },
      )

      received_params = nil
      server.completion_handler do |params|
        received_params = params
        { completion: { values: ["flask"], hasMore: false } }
      end

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/prompt", name: "code_review" },
          argument: { name: "framework", value: "fla" },
          context: { arguments: { language: "python" } },
        },
      })

      assert_equal({ language: "python" }, received_params.dig(:context, :arguments))
    end

    test "#handle completion/complete truncates values exceeding 100 items" do
      prompt = Prompt.define(name: "test") {}
      server = Server.new(
        name: "test_server",
        prompts: [prompt],
        capabilities: { completions: {} },
      )

      server.completion_handler do |_params|
        { completion: { values: (1..150).map(&:to_s), hasMore: false } }
      end

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/prompt", name: "test" },
          argument: { name: "arg", value: "" },
        },
      })

      completion = response[:result][:completion]
      assert_equal 100, completion[:values].length
      assert_equal "1", completion[:values].first
      assert_equal "100", completion[:values].last
      assert(completion[:hasMore])
      assert_equal 150, completion[:total]
    end

    test "#handle completion/complete returns error for nonexistent prompt" do
      server = Server.new(
        name: "test_server",
        capabilities: { completions: {} },
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/prompt", name: "nonexistent" },
          argument: { name: "arg", value: "val" },
        },
      })

      assert_equal(-32_602, response[:error][:code])
    end

    test "#handle completion/complete returns error for nonexistent resource template" do
      server = Server.new(
        name: "test_server",
        capabilities: { completions: {} },
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/resource", uri: "unknown://template" },
          argument: { name: "arg", value: "val" },
        },
      })

      assert_equal(-32_602, response[:error][:code])
    end

    test "#handle completion/complete resource-not-found error carries the uri in error data" do
      server = Server.new(
        name: "test_server",
        capabilities: { completions: {} },
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/resource", uri: "unknown://template" },
          argument: { name: "arg", value: "val" },
        },
      })

      assert_equal(-32602, response[:error][:code])
      assert_equal("Resource not found: unknown://template", response[:error][:message])
      assert_equal({ uri: "unknown://template" }, response[:error][:data])
    end

    test "#handle completion/complete returns error for invalid ref type" do
      server = Server.new(
        name: "test_server",
        capabilities: { completions: {} },
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/invalid" },
          argument: { name: "arg", value: "val" },
        },
      })

      assert_equal(-32_602, response[:error][:code])
    end

    test "#handle completion/complete returns error for missing ref" do
      server = Server.new(
        name: "test_server",
        capabilities: { completions: {} },
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: {},
          argument: { name: "arg", value: "val" },
        },
      })

      assert_equal(-32_602, response[:error][:code])
    end

    test "#handle completion/complete with custom handler for ref/resource with resource URI" do
      resource = Resource.new(
        uri: "file:///README.md",
        name: "readme",
      )
      server = Server.new(
        name: "test_server",
        resources: [resource],
        capabilities: { completions: {} },
      )

      server.completion_handler do |_params|
        { completion: { values: ["file:///README.md"], hasMore: false } }
      end

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/resource", uri: "file:///README.md" },
          argument: { name: "path", value: "R" },
        },
      })

      assert_equal(
        {
          jsonrpc: "2.0",
          id: 2,
          result: { completion: { values: ["file:///README.md"], hasMore: false } },
        },
        response,
      )
    end

    test "#handle completion/complete returns error for missing argument" do
      prompt = Prompt.define(name: "test") {}
      server = Server.new(
        name: "test_server",
        prompts: [prompt],
        capabilities: { completions: {} },
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/prompt", name: "test" },
        },
      })

      assert_equal(-32_602, response[:error][:code])
    end

    test "#handle completion/complete returns error for missing argument value" do
      prompt = Prompt.define(name: "test") {}
      server = Server.new(
        name: "test_server",
        prompts: [prompt],
        capabilities: { completions: {} },
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/prompt", name: "test" },
          argument: { name: "arg" },
        },
      })

      assert_equal(-32_602, response[:error][:code])
    end

    test "#handle completion/complete returns default when handler returns nil" do
      prompt = Prompt.define(name: "test") {}
      server = Server.new(
        name: "test_server",
        prompts: [prompt],
        capabilities: { completions: {} },
      )

      server.completion_handler do |_params|
        nil
      end

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/prompt", name: "test" },
          argument: { name: "arg", value: "" },
        },
      })

      assert_equal(
        {
          jsonrpc: "2.0",
          id: 2,
          result: { completion: { values: [], hasMore: false } },
        },
        response,
      )
    end

    test "#handle completion/complete with string-keyed handler result" do
      prompt = Prompt.define(name: "test") {}
      server = Server.new(
        name: "test_server",
        prompts: [prompt],
        capabilities: { completions: {} },
      )

      server.completion_handler do |_params|
        { "completion" => { "values" => ["alpha", "beta"], "hasMore" => true } }
      end

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/prompt", name: "test" },
          argument: { name: "arg", value: "" },
        },
      })

      assert_equal ["alpha", "beta"], response[:result][:completion][:values]
      assert response[:result][:completion][:hasMore]
    end

    test "#handle completion/complete returns invalid params for non-Hash params" do
      server = Server.new(
        name: "test_server",
        prompts: [],
        capabilities: { completions: {} },
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: "invalid",
      })

      assert_equal(-32602, response[:error][:code])
    end

    test "#handle completion/complete returns error when completions capability is not declared" do
      server = Server.new(
        name: "test_server",
        prompts: [],
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/prompt", name: "test" },
          argument: { name: "arg", value: "" },
        },
      })

      assert response[:error]
      assert_includes response[:error][:data], "completions"
    end

    test "#handle resources/subscribe returns empty result" do
      server = Server.new(
        name: "test_server",
        capabilities: { resources: { subscribe: true } },
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "resources/subscribe",
        params: { uri: "https://example.com/resource" },
      })

      assert_equal(
        {
          jsonrpc: "2.0",
          id: 2,
          result: {},
        },
        response,
      )
    end

    test "#handle resources/unsubscribe returns empty result" do
      server = Server.new(
        name: "test_server",
        capabilities: { resources: { subscribe: true } },
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "resources/unsubscribe",
        params: { uri: "https://example.com/resource" },
      })

      assert_equal(
        {
          jsonrpc: "2.0",
          id: 2,
          result: {},
        },
        response,
      )
    end

    test "#handle resources/subscribe with custom handler calls the handler" do
      server = Server.new(
        name: "test_server",
        capabilities: { resources: { subscribe: true } },
      )

      received_params = nil
      server.resources_subscribe_handler do |params|
        received_params = params
        {}
      end

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "resources/subscribe",
        params: { uri: "https://example.com/resource" },
      })

      assert_equal(
        {
          jsonrpc: "2.0",
          id: 2,
          result: {},
        },
        response,
      )
      assert_equal "https://example.com/resource", received_params[:uri]
    end

    test "#handle resources/unsubscribe with custom handler calls the handler" do
      server = Server.new(
        name: "test_server",
        capabilities: { resources: { subscribe: true } },
      )

      received_params = nil
      server.resources_unsubscribe_handler do |params|
        received_params = params
        {}
      end

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "resources/unsubscribe",
        params: { uri: "https://example.com/resource" },
      })

      assert_equal(
        {
          jsonrpc: "2.0",
          id: 2,
          result: {},
        },
        response,
      )
      assert_equal "https://example.com/resource", received_params[:uri]
    end

    test "#handle resources/subscribe without uri returns -32602" do
      server = Server.new(
        name: "test_server",
        capabilities: { resources: { subscribe: true } },
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "resources/subscribe",
        params: {},
      })

      assert_equal(-32602, response[:error][:code])
      assert_equal "Invalid params", response[:error][:message]
      assert_includes response[:error][:data], "uri"
    end

    test "#handle resources/unsubscribe without uri returns -32602" do
      server = Server.new(
        name: "test_server",
        capabilities: { resources: { subscribe: true } },
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "resources/unsubscribe",
        params: {},
      })

      assert_equal(-32602, response[:error][:code])
      assert_equal "Invalid params", response[:error][:message]
    end

    test "#handle resources/subscribe without uri does not invoke a custom handler" do
      server = Server.new(
        name: "test_server",
        capabilities: { resources: { subscribe: true } },
      )

      handler_called = false
      server.resources_subscribe_handler do |_params|
        handler_called = true
        {}
      end

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "resources/subscribe",
        params: {},
      })

      assert_equal(-32602, response[:error][:code])
      refute handler_called
    end

    test "tools/call with no args" do
      server = Server.new(tools: [@tool_with_no_args])

      response = server.handle(
        {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: {
            name: "tool_with_no_args",
          },
        },
      )

      assert_equal "2.0", response[:jsonrpc]
      assert_equal 1, response[:id]
      assert response[:result], "Expected result key in response"
      assert_equal "text", response[:result][:content][0][:type]
      assert_equal "OK", response[:result][:content][0][:content]
    end

    class TestTool < Tool
      tool_name "test_tool"
      description "a test tool for testing"
      input_schema({ properties: { message: { type: "string" } }, required: ["message"] })

      class << self
        def call(server_context: nil, **kwargs)
          Tool::Response.new([{ type: "text", content: "OK" }])
        end
      end
    end

    class TestToolWithAdditionalPropertiesSetToFalse < Tool
      tool_name "test_tool_with_additional_properties_set_to_false"
      description "a test tool with additionalProperties set to false for testing"
      input_schema({ properties: { message: { type: "string" } }, required: ["message"], additionalProperties: false })

      class << self
        def call(server_context: nil, **kwargs)
          Tool::Response.new([{ type: "text", content: "OK" }])
        end
      end
    end

    class ComplexTypesTool < Tool
      tool_name "complex_types_tool"
      description "a test tool with complex types"
      input_schema({
        properties: {
          numbers: { type: "array", items: { type: "number" } },
          strings: { type: "array", items: { type: "string" } },
          objects: {
            type: "array",
            items: {
              type: "object",
              properties: {
                name: { type: "string" },
              },
              required: ["name"],
            },
          },
        },
        required: ["numbers", "strings", "objects"],
      })

      class << self
        def call(numbers:, strings:, objects:, server_context: nil)
          Tool::Response.new([{ type: "text", content: "OK" }])
        end
      end
    end

    class JsonObjectValue
      def initialize(value)
        @value = value
      end

      def to_json(*args)
        @value.to_json(*args)
      end
    end

    test "server_context_with_meta uses accessor method, not ivar directly" do
      subclass = Class.new(Server) do
        def server_context
          { custom: "from_accessor" }
        end
      end

      server = subclass.new(name: "test", tools: [])

      received_context = nil
      server.define_tool(name: "ctx_tool") do |server_context:|
        received_context = server_context
        Tool::Response.new([{ type: "text", text: "ok" }])
      end

      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        id: 1,
        params: { name: "ctx_tool", arguments: {} },
      }

      server.handle(request)
      assert_equal "from_accessor", received_context[:custom]
    end

    test "#handle tools/call passes W3C trace context _meta keys through to the handler" do
      # Per SEP-414, `traceparent`, `tracestate`, and `baggage` are reserved
      # un-prefixed `_meta` keys and must never be stripped by the SDK.
      server = Server.new(name: "trace_test", tools: [])
      received_context = nil
      server.define_tool(name: "trace_tool") do |server_context:|
        received_context = server_context
        Tool::Response.new([{ type: "text", text: "ok" }])
      end

      server.handle({
        jsonrpc: "2.0",
        method: "tools/call",
        id: 1,
        params: {
          name: "trace_tool",
          arguments: {},
          _meta: {
            traceparent: "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
            tracestate: "vendor=value",
            baggage: "userId=alice",
            progressToken: "token-1",
          },
        },
      })

      meta = received_context[:_meta]
      assert_equal "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01", meta[:traceparent]
      assert_equal "vendor=value", meta[:tracestate]
      assert_equal "userId=alice", meta[:baggage]
      assert_equal "token-1", meta[:progressToken]
    end

    test "#handle prompts/get passes W3C trace context _meta keys through to the handler" do
      server = Server.new(name: "trace_test", prompts: [])
      received_context = nil
      server.define_prompt(name: "trace_prompt", arguments: []) do |_args, server_context:|
        received_context = server_context
        Prompt::Result.new(
          description: "a prompt description",
          messages: [Prompt::Message.new(role: "user", content: Content::Text.new("a prompt message"))],
        )
      end

      server.handle({
        jsonrpc: "2.0",
        method: "prompts/get",
        id: 1,
        params: {
          name: "trace_prompt",
          arguments: {},
          _meta: {
            traceparent: "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
            tracestate: "vendor=value",
            baggage: "userId=alice",
          },
        },
      })

      meta = received_context[:_meta]
      MCP::TraceContext::META_KEYS.each do |key|
        assert meta.key?(key.to_sym), "expected _meta to retain #{key}"
      end
    end

    test "#handle tools/call mirrors non-object structuredContent when content is omitted or nil" do
      # Per SEP-2106, `structuredContent` may be any JSON value. Older clients may only read `content`,
      # so the server adds a serialized fallback when the tool provided no content blocks.
      server = Server.new(name: "structured_test", tools: [])
      server.define_tool(name: "nil_content_tool") do
        Tool::Response.new(nil, structured_content: [1, 2])
      end
      server.define_tool(name: "omitted_content_tool") do
        Tool::Response.new(structured_content: [1, 2])
      end

      ["nil_content_tool", "omitted_content_tool"].each_with_index do |tool_name, index|
        response = server.handle({
          jsonrpc: "2.0",
          method: "tools/call",
          id: index + 1,
          params: { name: tool_name, arguments: {} },
        })

        assert_equal [1, 2], response.dig(:result, :structuredContent)
        assert_equal [{ type: "text", text: "[1,2]" }], response.dig(:result, :content)
      end
    end

    test "#handle tools/call does not overwrite explicit content when structuredContent is non-object" do
      server = Server.new(name: "structured_test", tools: [])
      server.define_tool(name: "array_tool") do
        Tool::Response.new([{ type: "text", text: "two items" }], structured_content: [1, 2])
      end

      response = server.handle({
        jsonrpc: "2.0",
        method: "tools/call",
        id: 1,
        params: { name: "array_tool", arguments: {} },
      })

      assert_equal [{ type: "text", text: "two items" }], response.dig(:result, :content)
    end

    test "#handle tools/call leaves object structuredContent without a text fallback" do
      server = Server.new(name: "structured_test", tools: [])
      server.define_tool(name: "object_tool") do
        Tool::Response.new(nil, structured_content: { answer: 42 })
      end

      response = server.handle({
        jsonrpc: "2.0",
        method: "tools/call",
        id: 1,
        params: { name: "object_tool", arguments: {} },
      })

      assert_equal({ answer: 42 }, response.dig(:result, :structuredContent))
      assert_empty response.dig(:result, :content)
    end

    test "#handle tools/call recognizes object-like structuredContent by its JSON shape" do
      structured_content = JsonObjectValue.new(answer: 42)
      server = Server.new(name: "structured_test", tools: [])
      server.define_tool(name: "object_tool") do
        Tool::Response.new(nil, structured_content: structured_content)
      end

      response = server.handle({
        jsonrpc: "2.0",
        method: "tools/call",
        id: 1,
        params: { name: "object_tool", arguments: {} },
      })

      assert_equal structured_content, response.dig(:result, :structuredContent)
      assert_empty response.dig(:result, :content)
    end

    test "#handle tools/call preserves explicit empty content for non-object structuredContent" do
      server = Server.new(name: "structured_test", tools: [])
      server.define_tool(name: "array_tool") do
        Tool::Response.new([], structured_content: [1, 2])
      end

      response = server.handle({
        jsonrpc: "2.0",
        method: "tools/call",
        id: 1,
        params: { name: "array_tool", arguments: {} },
      })

      assert_equal [1, 2], response.dig(:result, :structuredContent)
      assert_empty response.dig(:result, :content)
    end

    test "#handle tools/call preserves explicit empty content for object-like structuredContent" do
      structured_content = JsonObjectValue.new(answer: 42)

      server = Server.new(name: "structured_test", tools: [])
      server.define_tool(name: "object_tool") do
        Tool::Response.new([], structured_content: structured_content)
      end

      response = server.handle({
        jsonrpc: "2.0",
        method: "tools/call",
        id: 1,
        params: { name: "object_tool", arguments: {} },
      })

      assert_equal structured_content, response.dig(:result, :structuredContent)
      assert_empty response.dig(:result, :content)
    end

    test "list results carry ttlMs and cacheScope when ttl_ms is configured" do
      # SEP-2549 cache hints. The unset cacheScope fills as "private", the side that cannot
      # leak a user-dependent result through a shared cache, matching the TypeScript and
      # Python SDK defaults (the spec names no default scope).
      server = Server.new(name: "ttl_test", ttl_ms: 5000)

      ["tools/list", "prompts/list", "resources/list", "resources/templates/list"].each_with_index do |method, index|
        result = server.handle({ jsonrpc: "2.0", method: method, id: index + 1 })[:result]

        assert_equal 5000, result[:ttlMs], "#{method} missing ttlMs"
        assert_equal "private", result[:cacheScope], "#{method} missing cacheScope"
      end
    end

    test "resources/read carries cache hints when cache_scope is configured" do
      # The ttlMs default is 0 (do not cache), the only universally safe value.
      server = Server.new(name: "ttl_test", cache_scope: "private")

      result = server.handle({
        jsonrpc: "2.0",
        method: "resources/read",
        id: 1,
        params: { uri: "file:///x" },
      })[:result]

      assert_equal 0, result[:ttlMs]
      assert_equal "private", result[:cacheScope]
    end

    test "results omit cache hints when ttl_ms and cache_scope are not configured" do
      # Wire-format regression: opt-in emission keeps default output unchanged.
      list_result = @server.handle({ jsonrpc: "2.0", method: "tools/list", id: 1 })[:result]
      read_result = @server.handle({
        jsonrpc: "2.0",
        method: "resources/read",
        id: 2,
        params: { uri: "file:///x" },
      })[:result]

      refute list_result.key?(:ttlMs)
      refute list_result.key?(:cacheScope)
      refute read_result.key?(:ttlMs)
      refute read_result.key?(:cacheScope)
    end

    test "cache hints appear alongside nextCursor when paginating" do
      tool_a = Tool.define(name: "tool_a", description: "Tool A")
      tool_b = Tool.define(name: "tool_b", description: "Tool B")
      server = Server.new(name: "ttl_test", tools: [tool_a, tool_b], page_size: 1, ttl_ms: 1000, cache_scope: "private")

      result = server.handle({ jsonrpc: "2.0", method: "tools/list", id: 1 })[:result]

      assert_not_nil result[:nextCursor]
      assert_equal 1000, result[:ttlMs]
      assert_equal "private", result[:cacheScope]
    end

    test "a resources_read_handler can override the server-level cache hints per result" do
      server = Server.new(name: "ttl_test", ttl_ms: 5000)
      server.resources_read_handler do |params|
        { contents: [{ uri: params[:uri], mimeType: "text/plain", text: "hi" }], ttlMs: 60_000 }
      end

      result = server.handle({
        jsonrpc: "2.0",
        method: "resources/read",
        id: 1,
        params: { uri: "file:///x" },
      })[:result]

      assert_equal 60_000, result[:ttlMs]
      assert_equal "private", result[:cacheScope]
      assert_equal [{ uri: "file:///x", mimeType: "text/plain", text: "hi" }], result[:contents]
    end

    test "ttl_ms and cache_scope writers reject invalid values" do
      assert_raises(ArgumentError) { Server.new(name: "ttl_test", ttl_ms: -1) }
      assert_raises(ArgumentError) { Server.new(name: "ttl_test", ttl_ms: 1.5) }
      assert_raises(ArgumentError) { Server.new(name: "ttl_test", cache_scope: "internal") }
    end

    test "#handle tools/list returns paginated results when page_size is set" do
      tool_a = Tool.define(name: "tool_a", title: "Tool A", description: "Tool A")
      tool_b = Tool.define(name: "tool_b", title: "Tool B", description: "Tool B")
      tool_c = Tool.define(name: "tool_c", title: "Tool C", description: "Tool C")

      server = Server.new(
        name: "pagination_test",
        tools: [tool_a, tool_b, tool_c],
        page_size: 2,
      )

      first_request = { jsonrpc: "2.0", method: "tools/list", id: 1 }
      first_response = server.handle(first_request)
      first_result = first_response[:result]

      assert_equal 2, first_result[:tools].size
      assert_equal "tool_a", first_result[:tools][0][:name]
      assert_equal "tool_b", first_result[:tools][1][:name]
      assert_not_nil first_result[:nextCursor]

      second_request = { jsonrpc: "2.0", method: "tools/list", id: 2, params: { cursor: first_result[:nextCursor] } }
      second_response = server.handle(second_request)
      second_result = second_response[:result]

      assert_equal 1, second_result[:tools].size
      assert_equal "tool_c", second_result[:tools][0][:name]
      # Final page omits the nextCursor key entirely (not just sets it to nil).
      refute second_result.key?(:nextCursor)
    end

    test "#handle tools/list returns all tools when page_size is not set" do
      response = @server.handle({ jsonrpc: "2.0", method: "tools/list", id: 1 })
      result = response[:result]

      assert_kind_of Array, result[:tools]
      assert_nil result[:nextCursor]
    end

    test "#handle tools/list returns error for invalid cursor" do
      server = Server.new(name: "pagination_test", tools: [@tool], page_size: 1)

      request = { jsonrpc: "2.0", method: "tools/list", id: 1, params: { cursor: "!!!invalid!!!" } }
      response = server.handle(request)

      assert_not_nil response[:error]
      assert_equal(-32602, response[:error][:code])
    end

    test "#handle prompts/list returns paginated results when page_size is set" do
      prompt_a = Prompt.define(name: "prompt_a", title: "Prompt A", description: "A") { Prompt::Result.new(description: "A", messages: []) }
      prompt_b = Prompt.define(name: "prompt_b", title: "Prompt B", description: "B") { Prompt::Result.new(description: "B", messages: []) }

      server = Server.new(name: "pagination_test", prompts: [prompt_a, prompt_b], page_size: 1)

      first_response = server.handle({ jsonrpc: "2.0", method: "prompts/list", id: 1 })
      first_result = first_response[:result]

      assert_equal 1, first_result[:prompts].size
      assert_equal "prompt_a", first_result[:prompts][0][:name]
      assert_not_nil first_result[:nextCursor]

      second_response = server.handle({ jsonrpc: "2.0", method: "prompts/list", id: 2, params: { cursor: first_result[:nextCursor] } })
      second_result = second_response[:result]

      assert_equal 1, second_result[:prompts].size
      assert_equal "prompt_b", second_result[:prompts][0][:name]
      assert_nil second_result[:nextCursor]
    end

    test "#handle resources/list returns paginated results when page_size is set" do
      resource_a = Resource.new(uri: "https://a.invalid", name: "a", description: "A", mime_type: "text/plain")
      resource_b = Resource.new(uri: "https://b.invalid", name: "b", description: "B", mime_type: "text/plain")

      server = Server.new(name: "pagination_test", resources: [resource_a, resource_b], page_size: 1)

      first_response = server.handle({ jsonrpc: "2.0", method: "resources/list", id: 1 })
      first_result = first_response[:result]

      assert_equal 1, first_result[:resources].size
      assert_equal "a", first_result[:resources][0][:name]
      assert_not_nil first_result[:nextCursor]

      second_response = server.handle({ jsonrpc: "2.0", method: "resources/list", id: 2, params: { cursor: first_result[:nextCursor] } })
      second_result = second_response[:result]

      assert_equal 1, second_result[:resources].size
      assert_equal "b", second_result[:resources][0][:name]
      assert_nil second_result[:nextCursor]
    end

    test "Server.new raises ArgumentError when page_size is zero" do
      assert_raises(ArgumentError) do
        Server.new(name: "test", page_size: 0)
      end
    end

    test "Server.new raises ArgumentError when page_size is negative" do
      assert_raises(ArgumentError) do
        Server.new(name: "test", page_size: -1)
      end
    end

    test "Server.new raises ArgumentError when page_size is non-Integer" do
      assert_raises(ArgumentError) do
        Server.new(name: "test", page_size: "10")
      end
    end

    test "page_size= raises ArgumentError for invalid values" do
      server = Server.new(name: "test")

      assert_raises(ArgumentError) { server.page_size = 0 }
      assert_raises(ArgumentError) { server.page_size = -1 }
      assert_raises(ArgumentError) { server.page_size = "5" }

      server.page_size = nil
      server.page_size = 10
      assert_equal 10, server.page_size
    end

    test "#handle tools/list returns -32602 for non-Hash params" do
      server = Server.new(name: "test", tools: [@tool], page_size: 1)

      request = { jsonrpc: "2.0", method: "tools/list", id: 1, params: [1, 2, 3] }
      response = server.handle(request)

      assert_not_nil response[:error]
      assert_equal(-32602, response[:error][:code])
    end

    test "#handle_json tools/list returns -32602 for numeric cursor (spec requires string)" do
      server = Server.new(name: "test", tools: [@tool], page_size: 1)

      request_json = '{"jsonrpc":"2.0","method":"tools/list","id":1,"params":{"cursor":0}}'
      response = JSON.parse(server.handle_json(request_json), symbolize_names: true)

      assert_not_nil response[:error]
      assert_equal(-32602, response[:error][:code])
    end

    test "#handle resources/templates/list returns paginated results when page_size is set" do
      template_a = ResourceTemplate.new(uri_template: "https://a.invalid/{id}", name: "a", description: "A", mime_type: "text/plain")
      template_b = ResourceTemplate.new(uri_template: "https://b.invalid/{id}", name: "b", description: "B", mime_type: "text/plain")

      server = Server.new(name: "pagination_test", resource_templates: [template_a, template_b], page_size: 1)

      first_response = server.handle({ jsonrpc: "2.0", method: "resources/templates/list", id: 1 })
      first_result = first_response[:result]

      assert_equal 1, first_result[:resourceTemplates].size
      assert_equal "a", first_result[:resourceTemplates][0][:name]
      assert_not_nil first_result[:nextCursor]

      second_response = server.handle({ jsonrpc: "2.0", method: "resources/templates/list", id: 2, params: { cursor: first_result[:nextCursor] } })
      second_result = second_response[:result]

      assert_equal 1, second_result[:resourceTemplates].size
      assert_equal "b", second_result[:resourceTemplates][0][:name]
      assert_nil second_result[:nextCursor]
    end

    test "an MCP Apps server advertises the extension and serves ui:// templates" do
      # SEP-1865: the extension rides the SEP-2133 `capabilities.extensions` machinery,
      # UI templates are ordinary resources, and tools link to them via `_meta.ui.resourceUri`.
      dashboard = Apps.ui_resource(uri: "ui://weather/dashboard", name: "weather_dashboard")
      capabilities = Server::Capabilities.new
      capabilities.support_tools
      capabilities.support_resources
      capabilities.support_extensions(Apps.capability)
      server = Server.new(name: "apps_test", capabilities: capabilities, resources: [dashboard])
      server.define_tool(
        name: "get_weather",
        meta: Apps.tool_meta(resource_uri: "ui://weather/dashboard"),
      ) do
        Tool::Response.new([{ type: "text", text: "Sunny" }])
      end

      server.resources_read_handler do |params|
        [{ uri: params[:uri], mimeType: Apps::RESOURCE_MIME_TYPE, text: "<html>dashboard</html>" }]
      end

      init_response = server.handle({
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: {
          protocolVersion: "2025-11-25",
          clientInfo: { name: "host", version: "1.0" },
          capabilities: { extensions: Apps.capability },
        },
      })

      tools_response = server.handle({
        jsonrpc: "2.0",
        method: "tools/list",
        id: 2,
      })

      read_response = server.handle({
        jsonrpc: "2.0",
        method: "resources/read",
        id: 3,
        params: { uri: "ui://weather/dashboard" },
      })

      assert_equal(
        { mimeTypes: [Apps::RESOURCE_MIME_TYPE] },
        init_response.dig(:result, :capabilities, :extensions, Apps::EXTENSION_ID),
      )
      tool_entry = tools_response.dig(:result, :tools, 0)

      assert_equal "ui://weather/dashboard", tool_entry.dig(:_meta, :ui, :resourceUri)
      assert_equal "<html>dashboard</html>", read_response.dig(:result, :contents, 0, :text)
      # The server can gate the text-only fallback on the client's declaration.
      assert Apps.client_supports?(server.client_capabilities)
    end

    test "an MCP Apps tool falls back to text for clients without the extension" do
      capabilities = Server::Capabilities.new
      capabilities.support_extensions(Apps.capability)
      server = Server.new(name: "apps_test", capabilities: capabilities)

      server.handle({
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: {
          protocolVersion: "2025-11-25",
          clientInfo: { name: "plain_client", version: "1.0" },
          capabilities: {},
        },
      })

      refute Apps.client_supports?(server.client_capabilities)
    end

    # SEP-2322 makes `resultType` REQUIRED on every result of a 2026-07-28 server;
    # `"complete"` is the standard shape, and legacy results stay unstamped.
    test "modern results carry resultType complete" do
      server = Server.new(name: "result_type_test", tools: [result_type_tool])

      # Every method here has to be one the modern lifecycle still has. `ping` does not qualify:
      # SEP-2575 removed it, so a modern request naming it is answered with -32601, not a stamped result.
      [
        modern_request(Methods::TOOLS_LIST, {}),
        modern_request(Methods::PROMPTS_LIST, {}),
        modern_request(Methods::TOOLS_CALL, { name: "result_type_tool", arguments: {} }),
      ].each do |request|
        response = server.handle(request)
        assert_equal "complete", response.dig(:result, :resultType), "expected stamp for #{request[:method]}"
      end
    end

    test "legacy results carry no resultType" do
      server = Server.new(name: "result_type_test", tools: [result_type_tool])

      [
        { jsonrpc: "2.0", method: Methods::TOOLS_LIST, id: 1 },
        { jsonrpc: "2.0", method: Methods::PING, id: 2 },
        { jsonrpc: "2.0", method: Methods::TOOLS_CALL, id: 3, params: { name: "result_type_tool", arguments: {} } },
      ].each do |request|
        response = server.handle(request)
        refute response[:result].key?(:resultType), "expected no stamp for #{request[:method]}"
      end
    end

    test "results after a counter-offered modern initialize carry no resultType" do
      # The scenario from issue #512: a client asking `initialize` for 2026-07-28 lands on
      # 2025-11-25, where `resultType` does not exist, so its absence is the correct shape
      # (clients MUST read an absent `resultType` as "complete" on that revision).
      server = Server.new(name: "result_type_test", tools: [result_type_tool])
      session = ServerSession.new(server: server, transport: mock)

      init_response = server.handle(
        { jsonrpc: "2.0", method: "initialize", id: 1, params: initialize_params(protocolVersion: "2026-07-28") },
        session: session,
      )
      response = server.handle({ jsonrpc: "2.0", method: Methods::TOOLS_LIST, id: 2 }, session: session)

      assert_equal Configuration::LATEST_HANDSHAKE_PROTOCOL_VERSION, init_response.dig(:result, :protocolVersion)
      refute response[:result].key?(:resultType)
    end

    test "server/discover carries resultType complete" do
      server = Server.new(name: "result_type_test", tools: [result_type_tool])

      response = server.handle({ jsonrpc: "2.0", method: Methods::SERVER_DISCOVER, id: 1 })

      assert_equal "complete", response.dig(:result, :resultType)
    end

    # SEP-2549 makes the `ttlMs`/`cacheScope` cache hints REQUIRED on cacheable results at 2026-07-28;
    # unset hints get the spec defaults, and stable protocol versions keep the opt-in emission.
    test "modern cacheable results carry the default cache hints" do
      server = Server.new(name: "cache_hints_test", tools: [result_type_tool])

      response = server.handle(modern_request(Methods::TOOLS_LIST, {}))

      assert_equal 0, response.dig(:result, :ttlMs)
      assert_equal "private", response.dig(:result, :cacheScope)
    end

    test "modern non-cacheable results carry no cache hints" do
      server = Server.new(name: "cache_hints_test", tools: [result_type_tool])

      # `tools/call` is the non-cacheable example here: the spec types `CallToolResult` as a plain `Result`,
      # while the results it types as `CacheableResult` are the discover, list, and read families.
      # `ping` cannot stand in for it - SEP-2575 removed that method, so a modern request naming it is refused.
      response = server.handle(modern_request(Methods::TOOLS_CALL, { name: "result_type_tool", arguments: {} }))

      refute response[:result].key?(:ttlMs)
      refute response[:result].key?(:cacheScope)
    end

    test "configured cache hints win over the modern defaults" do
      server = Server.new(name: "cache_hints_test", tools: [result_type_tool], ttl_ms: 5000, cache_scope: "private")

      response = server.handle(modern_request(Methods::TOOLS_LIST, {}))

      assert_equal 5000, response.dig(:result, :ttlMs)
      assert_equal "private", response.dig(:result, :cacheScope)
    end

    test "modern resources/read results carry the default cache hints" do
      server = Server.new(name: "cache_hints_test")
      server.resources_read_handler do |params|
        [{ uri: params[:uri], mimeType: "text/plain", text: "hi" }]
      end

      response = server.handle(modern_request(Methods::RESOURCES_READ, { uri: "file:///x" }))

      assert_equal 0, response.dig(:result, :ttlMs)
      assert_equal "private", response.dig(:result, :cacheScope)
    end

    test "legacy cacheable results keep the opt-in cache hint emission" do
      server = Server.new(name: "cache_hints_test", tools: [result_type_tool])

      response = server.handle({ jsonrpc: "2.0", method: Methods::TOOLS_LIST, id: 1 })

      refute response[:result].key?(:ttlMs)
      refute response[:result].key?(:cacheScope)
    end

    private

    # Builds a request carrying the SEP-2575 modern `_meta` envelope.
    def modern_request(method, params, version: "2026-07-28", capabilities: {})
      {
        jsonrpc: "2.0",
        method: method,
        id: 1,
        params: params.merge(
          _meta: {
            "io.modelcontextprotocol/protocolVersion": version,
            "io.modelcontextprotocol/clientInfo": { name: "modern_client", version: "2.0" },
            "io.modelcontextprotocol/clientCapabilities": capabilities,
          },
        ),
      }
    end

    def result_type_tool
      @result_type_tool ||= Tool.define(name: "result_type_tool") do |**|
        Tool::Response.new([{ type: "text", text: "ok" }])
      end
    end
  end
end
