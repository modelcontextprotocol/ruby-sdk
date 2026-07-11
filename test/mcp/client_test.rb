# frozen_string_literal: true

require "test_helper"
require "securerandom"

module MCP
  class ClientTest < Minitest::Test
    def test_connect_delegates_to_transport_and_forwards_keyword_args
      transport = mock
      init_result = {
        "protocolVersion" => "2025-11-25",
        "capabilities" => { "tools" => {} },
        "serverInfo" => { "name" => "test-server", "version" => "1.0" },
      }
      transport.expects(:connect).with(
        client_info: { name: "my-app", version: "1.0" },
        protocol_version: "2025-11-25",
        capabilities: { roots: {} },
      ).returns(init_result).once

      result = Client.new(transport: transport).connect(
        client_info: { name: "my-app", version: "1.0" },
        protocol_version: "2025-11-25",
        capabilities: { roots: {} },
      )

      assert_equal(init_result, result)
    end

    def test_connect_passes_nil_defaults_to_transport
      transport = mock
      transport.expects(:connect)
        .with(client_info: nil, protocol_version: nil, capabilities: {})
        .returns({ "protocolVersion" => "2025-11-25" }).once

      Client.new(transport: transport).connect
    end

    def test_connect_is_noop_when_transport_does_not_respond_to_connect
      transport = mock
      transport.stubs(:respond_to?).with(:connect).returns(false)
      transport.stubs(:respond_to?).with(:server_info).returns(false)

      client = Client.new(transport: transport)

      assert_nil(client.connect)
      assert_nil(client.server_info)
    end

    def test_on_elicitation_registers_handler_on_transport
      transport = mock
      handler = proc { { action: "accept", content: {} } }
      transport.expects(:on_server_request).with("elicitation/create")

      Client.new(transport: transport).on_elicitation(&handler)
    end

    def test_on_elicitation_raises_when_transport_does_not_support_server_requests
      transport = mock
      transport.stubs(:respond_to?).with(:on_server_request).returns(false)

      error = assert_raises(ArgumentError) do
        Client.new(transport: transport).on_elicitation { { action: "accept", content: {} } }
      end

      assert_includes(error.message, "does not support server-to-client requests")
    end

    def test_connected_delegates_to_transport_when_supported
      transport = mock
      transport.expects(:connected?).returns(true)

      assert_predicate(Client.new(transport: transport), :connected?)
    end

    def test_connected_returns_true_when_transport_does_not_respond_to_connected
      transport = mock
      transport.stubs(:respond_to?).with(:connected?).returns(false)

      assert_predicate(Client.new(transport: transport), :connected?)
    end

    def test_server_info_delegates_to_transport_when_supported
      transport = mock
      init_result = { "protocolVersion" => "2025-11-25" }
      transport.expects(:server_info).returns(init_result)

      assert_equal(init_result, Client.new(transport: transport).server_info)
    end

    def test_server_info_returns_nil_when_transport_does_not_expose_it
      transport = mock
      transport.stubs(:respond_to?).with(:server_info).returns(false)

      assert_nil(Client.new(transport: transport).server_info)
    end

    def test_tools_sends_request_to_transport_and_returns_tools_array
      transport = mock
      mock_response = {
        "result" => {
          "tools" => [
            {
              "name" => "tool1",
              "description" => "tool1",
              "inputSchema" => {},
              "outputSchema" => { "type" => "object", "properties" => { "result" => { "type" => "string" } } },
            },
            { "name" => "tool2", "description" => "tool2", "inputSchema" => {} },
          ],
        },
      }

      # Only checking for the essential parts of the request
      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "tools/list" && args.dig(:request, :jsonrpc) == "2.0"
      end.returns(mock_response).once

      client = Client.new(transport: transport)
      tools = client.tools

      assert_equal(2, tools.size)
      assert_equal("tool1", tools.first.name)
      assert_equal({ "type" => "object", "properties" => { "result" => { "type" => "string" } } }, tools.first.output_schema)
      assert_equal("tool2", tools.last.name)
      assert_nil(tools.last.output_schema)
    end

    def test_tools_returns_empty_array_when_no_tools
      transport = mock
      mock_response = { "result" => { "tools" => [] } }

      # Only checking for the essential parts of the request
      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "tools/list" && args.dig(:request, :jsonrpc) == "2.0"
      end.returns(mock_response).once

      client = Client.new(transport: transport)
      tools = client.tools

      assert_equal([], tools)
    end

    def test_call_tool_sends_request_to_transport_and_returns_content
      transport = mock
      tool = MCP::Client::Tool.new(name: "tool1", description: "tool1", input_schema: {})
      arguments = { foo: "bar" }
      mock_response = {
        "result" => { "content" => [{ "type": "text", "text": "Hello, world!" }] },
      }

      # Only checking for the essential parts of the request
      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "tools/call" &&
          args.dig(:request, :jsonrpc) == "2.0" &&
          args.dig(:request, :params, :name) == "tool1" &&
          args.dig(:request, :params, :arguments) == arguments
      end.returns(mock_response).once

      client = Client.new(transport: transport)
      result = client.call_tool(tool: tool, arguments: arguments)
      content = result.dig("result", "content")

      assert_equal([{ type: "text", text: "Hello, world!" }], content)
    end

    def test_call_tool_by_name
      transport = mock
      arguments = { foo: "bar" }
      mock_response = {
        "result" => { "content" => [{ "type": "text", "text": "Hello, world!" }] },
      }

      transport.expects(:send_request).with do |args|
        args.dig(:request, :params, :name) == "tool1" &&
          args.dig(:request, :params, :arguments) == arguments
      end.returns(mock_response).once

      client = Client.new(transport: transport)
      result = client.call_tool(name: "tool1", arguments: arguments)
      content = result.dig("result", "content")

      assert_equal([{ type: "text", text: "Hello, world!" }], content)
    end

    def test_call_tool_raises_input_required_error_when_result_type_is_input_required
      # Per SEP-2322, a result with `resultType: "input_required"` is not a final result;
      # surface it instead of returning it as a normal result.
      transport = mock
      tool = MCP::Client::Tool.new(name: "tool1", description: "tool1", input_schema: {})
      mock_response = {
        "result" => {
          "resultType" => "input_required",
          "inputRequests" => {
            "1" => { "method" => "elicitation/create", "params" => { "mode" => "form", "message" => "Name?" } },
          },
          "requestState" => "opaque-state",
        },
      }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      error = assert_raises(Client::InputRequiredError) do
        client.call_tool(tool: tool, arguments: {})
      end

      assert_equal(
        { "1" => { "method" => "elicitation/create", "params" => { "mode" => "form", "message" => "Name?" } } },
        error.input_requests,
      )
      assert_equal("opaque-state", error.request_state)
      assert_equal(mock_response["result"], error.result)
    end

    def test_call_tool_returns_normally_when_result_type_is_complete
      transport = mock
      tool = MCP::Client::Tool.new(name: "tool1", description: "tool1", input_schema: {})
      mock_response = {
        "result" => {
          "resultType" => "complete",
          "content" => [{ "type" => "text", "text" => "done" }],
        },
      }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      result = client.call_tool(tool: tool, arguments: {})

      assert_equal("done", result.dig("result", "content", 0, "text"))
    end

    def test_call_tool_returns_normally_when_result_type_is_absent
      # Regression guard: stable-protocol servers never send `resultType`.
      transport = mock
      tool = MCP::Client::Tool.new(name: "tool1", description: "tool1", input_schema: {})
      mock_response = {
        "result" => { "content" => [{ "type" => "text", "text" => "done" }] },
      }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      result = client.call_tool(tool: tool, arguments: {})

      assert_equal("done", result.dig("result", "content", 0, "text"))
    end

    def test_list_tools_raises_input_required_error_for_input_required_results
      # The recognition lives in the shared request path, so every client method is covered, not only tools/call.
      transport = mock
      mock_response = {
        "result" => { "resultType" => "input_required", "inputRequests" => {} },
      }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      assert_raises(Client::InputRequiredError) { client.list_tools }
    end

    def test_call_tool_raises_when_no_name_or_tool
      client = Client.new(transport: mock)

      error = assert_raises(ArgumentError) { client.call_tool(arguments: { foo: "bar" }) }
      assert_equal("Either `name:` or `tool:` must be provided.", error.message)
    end

    def test_resources_sends_request_to_transport_and_returns_resources_array
      transport = mock
      mock_response = {
        "result" => {
          "resources" => [
            { "name" => "resource1", "uri" => "file:///path/to/resource1", "description" => "First resource" },
            { "name" => "resource2", "uri" => "file:///path/to/resource2", "description" => "Second resource" },
          ],
        },
      }

      # Only checking for the essential parts of the request
      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "resources/list" && args.dig(:request, :jsonrpc) == "2.0"
      end.returns(mock_response).once

      client = Client.new(transport: transport)
      resources = client.resources

      assert_equal(2, resources.size)
      assert_equal("resource1", resources.first["name"])
      assert_equal("file:///path/to/resource1", resources.first["uri"])
      assert_equal("resource2", resources.last["name"])
      assert_equal("file:///path/to/resource2", resources.last["uri"])
    end

    def test_resources_returns_empty_array_when_no_resources
      transport = mock
      mock_response = { "result" => { "resources" => [] } }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      resources = client.resources

      assert_equal([], resources)
    end

    def test_read_resource_sends_request_to_transport_and_returns_contents
      transport = mock
      uri = "file:///path/to/resource.txt"
      mock_response = {
        "result" => {
          "contents" => [
            { "uri" => uri, "mimeType" => "text/plain", "text" => "Hello, world!" },
          ],
        },
      }

      # Only checking for the essential parts of the request
      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "resources/read" &&
          args.dig(:request, :jsonrpc) == "2.0" &&
          args.dig(:request, :params, :uri) == uri
      end.returns(mock_response).once

      client = Client.new(transport: transport)
      contents = client.read_resource(uri: uri)

      assert_equal(1, contents.size)
      assert_equal(uri, contents.first["uri"])
      assert_equal("text/plain", contents.first["mimeType"])
      assert_equal("Hello, world!", contents.first["text"])
    end

    def test_read_resource_returns_empty_array_when_no_contents
      transport = mock
      uri = "file:///path/to/nonexistent.txt"
      mock_response = { "result" => {} }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      contents = client.read_resource(uri: uri)

      assert_equal([], contents)
    end

    def test_resource_templates_sends_request_to_transport_and_returns_resource_templates_array
      transport = mock
      mock_response = {
        "result" => {
          "resourceTemplates" => [
            { "name" => "template1", "uriTemplate" => "file:///path/{filename}", "description" => "First template" },
            { "name" => "template2", "uriTemplate" => "http://example.com/{id}", "description" => "Second template" },
          ],
        },
      }

      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "resources/templates/list" && args.dig(:request, :jsonrpc) == "2.0"
      end.returns(mock_response).once

      client = Client.new(transport: transport)
      resource_templates = client.resource_templates

      assert_equal(2, resource_templates.size)
      assert_equal("template1", resource_templates.first["name"])
      assert_equal("file:///path/{filename}", resource_templates.first["uriTemplate"])
      assert_equal("template2", resource_templates.last["name"])
      assert_equal("http://example.com/{id}", resource_templates.last["uriTemplate"])
    end

    def test_resource_templates_returns_empty_array_when_no_resource_templates
      transport = mock
      mock_response = { "result" => { "resourceTemplates" => [] } }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      resource_templates = client.resource_templates

      assert_equal([], resource_templates)
    end

    def test_prompts_sends_request_to_transport_and_returns_prompts_array
      transport = mock
      mock_response = {
        "result" => {
          "prompts" => [
            {
              "name" => "prompt_1",
              "description" => "First prompt",
              "arguments" => [
                {
                  "name" => "code_1",
                  "description" => "The code_1 to review",
                  "required" => true,
                },
              ],
            },
            {
              "name" => "prompt_2",
              "description" => "Second prompt",
              "arguments" => [
                {
                  "name" => "code_2",
                  "description" => "The code_2 to review",
                  "required" => true,
                },
              ],
            },
          ],
        },
      }

      # Only checking for the essential parts of the request
      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "prompts/list" && args.dig(:request, :jsonrpc) == "2.0"
      end.returns(mock_response).once

      client = Client.new(transport: transport)
      prompts = client.prompts

      assert_equal(2, prompts.size)
      assert_equal("prompt_1", prompts.first["name"])
      assert_equal("First prompt", prompts.first["description"])
      assert_equal("code_1", prompts.first["arguments"].first["name"])
      assert_equal("The code_1 to review", prompts.first["arguments"].first["description"])
      assert(prompts.first["arguments"].first["required"])

      assert_equal("prompt_2", prompts.last["name"])
      assert_equal("Second prompt", prompts.last["description"])
      assert_equal("code_2", prompts.last["arguments"].first["name"])
      assert_equal("The code_2 to review", prompts.last["arguments"].first["description"])
      assert(prompts.last["arguments"].first["required"])
    end

    def test_prompts_returns_empty_array_when_no_prompts
      transport = mock
      mock_response = { "result" => { "prompts" => [] } }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      prompts = client.prompts

      assert_equal([], prompts)
    end

    def test_get_prompt_sends_request_to_transport_and_returns_contents
      transport = mock
      name = "first_prompt"
      mock_response = {
        "result" => {
          "description" => "First prompt",
          "messages" => [
            {
              "role" => "user",
              "content" => {
                "text" => "First prompt content",
                "type" => "text",
              },
            },
          ],
        },
      }

      # Only checking for the essential parts of the request
      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "prompts/get" &&
          args.dig(:request, :jsonrpc) == "2.0" &&
          args.dig(:request, :params, :name) == name
      end.returns(mock_response).once

      client = Client.new(transport: transport)
      contents = client.get_prompt(name: name)

      assert_equal("First prompt", contents["description"])
      assert_equal("user", contents["messages"].first["role"])
      assert_equal("First prompt content", contents["messages"].first["content"]["text"])
    end

    def test_get_prompt_returns_empty_hash_when_no_contents
      transport = mock
      name = "nonexistent_prompt"
      mock_response = { "result" => {} }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      contents = client.get_prompt(name: name)

      assert_equal({}, contents)
    end

    def test_get_prompt_returns_empty_hash
      transport = mock
      name = "nonexistent_prompt"
      mock_response = {}

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      contents = client.get_prompt(name: name)

      assert_equal({}, contents)
    end

    def test_call_tool_includes_meta_progress_token_when_provided
      transport = mock
      tool = MCP::Client::Tool.new(name: "tool1", description: "tool1", input_schema: {})
      arguments = { foo: "bar" }
      progress_token = "my-progress-token"
      mock_response = {
        "result" => { "content" => [{ "type": "text", "text": "Hello, world!" }] },
      }

      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "tools/call" &&
          args.dig(:request, :params, :_meta, :progressToken) == progress_token &&
          args.dig(:request, :params, :name) == "tool1" &&
          args.dig(:request, :params, :arguments) == arguments
      end.returns(mock_response).once

      client = Client.new(transport: transport)
      client.call_tool(tool: tool, arguments: arguments, progress_token: progress_token)
    end

    def test_call_tool_sends_trace_context_meta_entries
      transport = mock
      tool = MCP::Client::Tool.new(name: "tool1", description: "tool1", input_schema: {})
      meta = {
        MCP::TraceContext::TRACEPARENT_META_KEY => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
        MCP::TraceContext::TRACESTATE_META_KEY => "vendor=value",
        MCP::TraceContext::BAGGAGE_META_KEY => "userId=alice",
      }
      mock_response = {
        "result" => { "content" => [{ "type": "text", "text": "Hello, world!" }] },
      }

      transport.expects(:send_request).with do |args|
        sent_meta = args.dig(:request, :params, :_meta)
        sent_meta["traceparent"] == meta["traceparent"] &&
          sent_meta["tracestate"] == meta["tracestate"] &&
          sent_meta["baggage"] == meta["baggage"]
      end.returns(mock_response).once

      client = Client.new(transport: transport)
      client.call_tool(tool: tool, arguments: {}, meta: meta)
    end

    def test_call_tool_merges_meta_with_progress_token_taking_precedence
      transport = mock
      tool = MCP::Client::Tool.new(name: "tool1", description: "tool1", input_schema: {})
      meta = { "traceparent" => "00-trace-span-01", "progressToken" => "from-meta" }
      mock_response = {
        "result" => { "content" => [{ "type": "text", "text": "Hello, world!" }] },
      }

      transport.expects(:send_request).with do |args|
        sent_meta = args.dig(:request, :params, :_meta)
        sent_meta["traceparent"] == "00-trace-span-01" &&
          sent_meta[:progressToken] == "explicit-token" &&
          !sent_meta.key?("progressToken")
      end.returns(mock_response).once

      client = Client.new(transport: transport)
      client.call_tool(tool: tool, arguments: {}, progress_token: "explicit-token", meta: meta)
    end

    def test_call_tool_omits_meta_when_empty_meta_hash_given
      transport = mock
      tool = MCP::Client::Tool.new(name: "tool1", description: "tool1", input_schema: {})
      mock_response = {
        "result" => { "content" => [{ "type": "text", "text": "Hello, world!" }] },
      }

      transport.expects(:send_request).with do |args|
        args.dig(:request, :params).key?(:_meta) == false
      end.returns(mock_response).once

      client = Client.new(transport: transport)
      client.call_tool(tool: tool, arguments: {}, meta: {})
    end

    def test_call_tool_does_not_mutate_caller_meta
      transport = mock
      tool = MCP::Client::Tool.new(name: "tool1", description: "tool1", input_schema: {})
      meta = { "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01" }
      mock_response = {
        "result" => { "content" => [{ "type": "text", "text": "Hello, world!" }] },
      }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      client.call_tool(tool: tool, arguments: {}, progress_token: "t", meta: meta)

      assert_equal({ "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01" }, meta)
    end

    def test_read_resource_sends_meta_when_provided
      transport = mock
      traceparent = "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01"
      mock_response = { "result" => { "contents" => [] } }

      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "resources/read" &&
          args.dig(:request, :params, :uri) == "file:///foo" &&
          args.dig(:request, :params, :_meta, :traceparent) == traceparent
      end.returns(mock_response).once

      client = Client.new(transport: transport)
      client.read_resource(uri: "file:///foo", meta: { traceparent: traceparent })
    end

    def test_request_methods_send_meta_when_provided
      # Per SEP-414, trace context should flow on every request, so the `meta:` keyword
      # is available on all client request methods.
      traceparent = "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01"
      meta = { traceparent: traceparent }

      [
        ["tools/list", { "tools" => [] }, ->(client) { client.list_tools(meta: meta) }],
        ["resources/list", { "resources" => [] }, ->(client) { client.list_resources(meta: meta) }],
        ["resources/templates/list", { "resourceTemplates" => [] }, ->(client) { client.list_resource_templates(meta: meta) }],
        ["prompts/list", { "prompts" => [] }, ->(client) { client.list_prompts(meta: meta) }],
        ["prompts/get", {}, ->(client) { client.get_prompt(name: "p", meta: meta) }],
        [
          "completion/complete",
          { "completion" => { "values" => [] } },
          ->(client) {
            client.complete(ref: { type: "ref/prompt", name: "p" }, argument: { name: "a", value: "v" }, meta: meta)
          },
        ],
        ["ping", {}, ->(client) { client.ping(meta: meta) }],
      ].each do |method, result, invoke|
        transport = mock
        transport.expects(:send_request).with do |args|
          args.dig(:request, :method) == method &&
            args.dig(:request, :params, :_meta, :traceparent) == traceparent
        end.returns({ "result" => result }).once

        invoke.call(Client.new(transport: transport))
      end
    end

    def test_request_methods_omit_meta_when_not_provided
      # Wire-format regression: without `meta:`, list requests keep sending no `params` at all.
      transport = mock
      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "tools/list" && !args[:request].key?(:params)
      end.returns({ "result" => { "tools" => [] } }).once

      Client.new(transport: transport).list_tools
    end

    def test_call_tool_omits_meta_when_no_progress_token
      transport = mock
      tool = MCP::Client::Tool.new(name: "tool1", description: "tool1", input_schema: {})
      arguments = { foo: "bar" }
      mock_response = {
        "result" => { "content" => [{ "type": "text", "text": "Hello, world!" }] },
      }

      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "tools/call" &&
          args.dig(:request, :params, :name) == "tool1" &&
          args.dig(:request, :params).key?(:_meta) == false
      end.returns(mock_response).once

      client = Client.new(transport: transport)
      client.call_tool(tool: tool, arguments: arguments)
    end

    def test_tools_raises_server_error_on_error_response
      transport = mock
      mock_response = { "error" => { "code" => -32_601, "message" => "Method not found" } }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      error = assert_raises(Client::ServerError) { client.tools }
      assert_equal(-32_601, error.code)
      assert_equal("Method not found", error.message)
    end

    def test_resources_raises_server_error_on_error_response
      transport = mock
      mock_response = { "error" => { "code" => -32_602, "message" => "Invalid params" } }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      error = assert_raises(Client::ServerError) { client.resources }
      assert_equal(-32_602, error.code)
    end

    def test_read_resource_raises_server_error_on_error_response
      transport = mock
      mock_response = { "error" => { "code" => -32_602, "message" => "Resource not found" } }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      assert_raises(Client::ServerError) { client.read_resource(uri: "file:///missing") }
    end

    def test_read_resource_surfaces_resource_not_found_code_and_data
      # Per SEP-2164, servers report unknown resource URIs with -32602 and
      # the URI in the error `data`; the client must expose both unmodified.
      transport = mock
      mock_response = {
        "error" => {
          "code" => -32_602,
          "message" => "Resource not found: file:///missing.txt",
          "data" => { "uri" => "file:///missing.txt" },
        },
      }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      error = assert_raises(Client::ServerError) { client.read_resource(uri: "file:///missing.txt") }

      assert_equal(-32_602, error.code)
      assert_equal({ "uri" => "file:///missing.txt" }, error.data)
    end

    def test_get_prompt_raises_server_error_on_error_response
      transport = mock
      mock_response = { "error" => { "code" => -32_602, "message" => "Prompt not found" } }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      assert_raises(Client::ServerError) { client.get_prompt(name: "missing") }
    end

    def test_prompts_raises_server_error_on_error_response
      transport = mock
      mock_response = { "error" => { "code" => -32_601, "message" => "Method not found" } }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      assert_raises(Client::ServerError) { client.prompts }
    end

    def test_resource_templates_raises_server_error_on_error_response
      transport = mock
      mock_response = { "error" => { "code" => -32_601, "message" => "Method not found" } }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      assert_raises(Client::ServerError) { client.resource_templates }
    end

    def test_call_tool_raises_server_error_on_error_response
      transport = mock
      mock_response = { "error" => { "code" => -32_602, "message" => "Tool not found" } }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      error = assert_raises(Client::ServerError) { client.call_tool(name: "missing") }
      assert_equal(-32_602, error.code)
    end

    def test_server_error_includes_data_field
      transport = mock
      mock_response = {
        "error" => { "code" => -32_603, "message" => "Internal error", "data" => "extra details" },
      }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      error = assert_raises(Client::ServerError) { client.tools }
      assert_equal("extra details", error.data)
    end

    def test_complete_raises_server_error_on_error_response
      transport = mock
      mock_response = { "error" => { "code" => -32_602, "message" => "Invalid params" } }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      error = assert_raises(Client::ServerError) { client.complete(ref: { type: "ref/prompt", name: "missing" }, argument: { name: "arg", value: "" }) }
      assert_equal(-32_602, error.code)
    end

    def test_complete_sends_request_and_returns_completion_result
      transport = mock
      mock_response = {
        "result" => {
          "completion" => {
            "values" => ["python", "pytorch"],
            "hasMore" => false,
          },
        },
      }

      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "completion/complete" &&
          args.dig(:request, :jsonrpc) == "2.0" &&
          args.dig(:request, :params, :ref) == { type: "ref/prompt", name: "code_review" } &&
          args.dig(:request, :params, :argument) == { name: "language", value: "py" } &&
          !args.dig(:request, :params).key?(:context)
      end.returns(mock_response).once

      client = Client.new(transport: transport)
      result = client.complete(
        ref: { type: "ref/prompt", name: "code_review" },
        argument: { name: "language", value: "py" },
      )

      assert_equal(["python", "pytorch"], result["values"])
      refute(result["hasMore"])
    end

    def test_complete_includes_context_when_provided
      transport = mock
      mock_response = {
        "result" => {
          "completion" => {
            "values" => ["flask"],
            "hasMore" => false,
          },
        },
      }

      transport.expects(:send_request).with do |args|
        args.dig(:request, :params, :context) == { arguments: { language: "python" } }
      end.returns(mock_response).once

      client = Client.new(transport: transport)
      result = client.complete(
        ref: { type: "ref/prompt", name: "code_review" },
        argument: { name: "framework", value: "fla" },
        context: { arguments: { language: "python" } },
      )

      assert_equal(["flask"], result["values"])
    end

    def test_complete_returns_default_when_result_is_missing
      transport = mock
      mock_response = { "result" => {} }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      result = client.complete(
        ref: { type: "ref/prompt", name: "test" },
        argument: { name: "arg", value: "" },
      )

      assert_equal([], result["values"])
      refute(result["hasMore"])
    end

    def test_ping_sends_request_and_returns_empty_hash
      transport = mock
      mock_response = { "result" => {} }

      transport.expects(:send_request).with do |args|
        req = args[:request]
        req[:method] == "ping" &&
          req[:jsonrpc] == "2.0" &&
          !req.key?(:params)
      end.returns(mock_response).once

      client = Client.new(transport: transport)
      result = client.ping

      assert_equal({}, result)
    end

    def test_ping_raises_server_error_on_error_response
      transport = mock
      mock_response = { "error" => { "code" => -32_603, "message" => "Internal error" } }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      error = assert_raises(Client::ServerError) { client.ping }
      assert_equal(-32_603, error.code)
      assert_equal("Internal error", error.message)
    end

    def test_ping_raises_validation_error_when_result_is_missing
      transport = mock
      mock_response = {}

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      error = assert_raises(Client::ValidationError) { client.ping }
      assert_equal("Response validation failed: missing or invalid `result`", error.message)
    end

    def test_ping_raises_validation_error_when_result_is_wrong_type
      transport = mock
      mock_response = { "result" => "ok" }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      error = assert_raises(Client::ValidationError) { client.ping }
      assert_equal("Response validation failed: missing or invalid `result`", error.message)
    end

    def test_ping_propagates_transport_errors
      transport = mock
      transport_error = StandardError.new("read timeout")
      transport.expects(:send_request).raises(transport_error).once

      client = Client.new(transport: transport)
      error = assert_raises(StandardError) { client.ping }
      assert_equal("read timeout", error.message)
    end

    def test_tools_auto_paginates_across_multiple_pages
      transport = mock

      page1_response = {
        "result" => {
          "tools" => [{ "name" => "tool1", "description" => "tool1", "inputSchema" => {} }],
          "nextCursor" => "cursor1",
        },
      }
      page2_response = {
        "result" => {
          "tools" => [{ "name" => "tool2", "description" => "tool2", "inputSchema" => {} }],
        },
      }

      call_count = 0
      transport.expects(:send_request).twice.with do |args|
        call_count += 1
        req = args[:request]
        if call_count == 1
          req[:method] == "tools/list" && req[:params].nil?
        else
          req[:method] == "tools/list" && req[:params] == { cursor: "cursor1" }
        end
      end.returns(page1_response).then.returns(page2_response)

      client = Client.new(transport: transport)
      tools = client.tools

      assert_equal(2, tools.size)
      assert_equal("tool1", tools[0].name)
      assert_equal("tool2", tools[1].name)
    end

    def test_list_tools_returns_single_page_with_cursor
      transport = mock

      mock_response = {
        "result" => {
          "tools" => [{ "name" => "tool1", "description" => "tool1", "inputSchema" => {} }],
          "nextCursor" => "cursor1",
        },
      }

      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "tools/list"
      end.returns(mock_response).once

      client = Client.new(transport: transport)
      result = client.list_tools

      assert_equal(1, result.tools.size)
      assert_equal("tool1", result.tools[0].name)
      assert_equal("cursor1", result.next_cursor)
    end

    def test_list_results_expose_ttl_ms_and_cache_scope
      # SEP-2549 cache hints are surfaced on every paginated result struct.
      [
        ["tools/list", "tools", :list_tools],
        ["prompts/list", "prompts", :list_prompts],
        ["resources/list", "resources", :list_resources],
        ["resources/templates/list", "resourceTemplates", :list_resource_templates],
      ].each do |method, items_key, client_method|
        transport = mock
        mock_response = {
          "result" => { items_key => [], "ttlMs" => 5000, "cacheScope" => "private" },
        }
        transport.expects(:send_request).with do |args|
          args.dig(:request, :method) == method
        end.returns(mock_response).once

        result = Client.new(transport: transport).public_send(client_method)

        assert_equal(5000, result.ttl_ms, "#{method} missing ttl_ms")
        assert_equal("private", result.cache_scope, "#{method} missing cache_scope")
      end
    end

    def test_list_results_have_nil_cache_hints_when_server_omits_them
      transport = mock
      mock_response = { "result" => { "tools" => [] } }
      transport.expects(:send_request).returns(mock_response).once

      result = Client.new(transport: transport).list_tools

      assert_nil(result.ttl_ms)
      assert_nil(result.cache_scope)
    end

    def test_list_tools_with_cursor_param
      transport = mock

      mock_response = {
        "result" => {
          "tools" => [{ "name" => "tool2", "description" => "tool2", "inputSchema" => {} }],
        },
      }

      transport.expects(:send_request).with do |args|
        args.dig(:request, :params) == { cursor: "cursor1" }
      end.returns(mock_response).once

      client = Client.new(transport: transport)
      result = client.list_tools(cursor: "cursor1")

      assert_equal(1, result.tools.size)
      assert_equal("tool2", result.tools[0].name)
      assert_nil(result.next_cursor)
    end

    def test_resources_auto_paginates_across_multiple_pages
      transport = mock

      page1_response = {
        "result" => {
          "resources" => [{ "uri" => "https://a.invalid", "name" => "a" }],
          "nextCursor" => "cursor1",
        },
      }
      page2_response = {
        "result" => {
          "resources" => [{ "uri" => "https://b.invalid", "name" => "b" }],
        },
      }

      transport.expects(:send_request).twice.returns(page1_response).then.returns(page2_response)

      client = Client.new(transport: transport)
      resources = client.resources

      assert_equal(2, resources.size)
      assert_equal("a", resources[0]["name"])
      assert_equal("b", resources[1]["name"])
    end

    def test_list_resources_returns_single_page_with_cursor
      transport = mock

      mock_response = {
        "result" => {
          "resources" => [{ "uri" => "https://a.invalid", "name" => "a" }],
          "nextCursor" => "cursor1",
        },
      }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      result = client.list_resources

      assert_equal(1, result.resources.size)
      assert_equal("cursor1", result.next_cursor)
    end

    def test_resource_templates_auto_paginates_across_multiple_pages
      transport = mock

      page1_response = {
        "result" => {
          "resourceTemplates" => [{ "uriTemplate" => "https://a.invalid/{id}", "name" => "a" }],
          "nextCursor" => "cursor1",
        },
      }
      page2_response = {
        "result" => {
          "resourceTemplates" => [{ "uriTemplate" => "https://b.invalid/{id}", "name" => "b" }],
        },
      }

      transport.expects(:send_request).twice.returns(page1_response).then.returns(page2_response)

      client = Client.new(transport: transport)
      templates = client.resource_templates

      assert_equal(2, templates.size)
      assert_equal("a", templates[0]["name"])
      assert_equal("b", templates[1]["name"])
    end

    def test_list_resource_templates_returns_single_page_with_cursor
      transport = mock

      mock_response = {
        "result" => {
          "resourceTemplates" => [{ "uriTemplate" => "https://a.invalid/{id}", "name" => "a" }],
          "nextCursor" => "cursor1",
        },
      }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      result = client.list_resource_templates

      assert_equal(1, result.resource_templates.size)
      assert_equal("cursor1", result.next_cursor)
    end

    def test_prompts_auto_paginates_across_multiple_pages
      transport = mock

      page1_response = {
        "result" => {
          "prompts" => [{ "name" => "prompt_a", "description" => "A" }],
          "nextCursor" => "cursor1",
        },
      }
      page2_response = {
        "result" => {
          "prompts" => [{ "name" => "prompt_b", "description" => "B" }],
        },
      }

      transport.expects(:send_request).twice.returns(page1_response).then.returns(page2_response)

      client = Client.new(transport: transport)
      prompts = client.prompts

      assert_equal(2, prompts.size)
      assert_equal("prompt_a", prompts[0]["name"])
      assert_equal("prompt_b", prompts[1]["name"])
    end

    def test_tools_breaks_when_server_returns_same_cursor_repeatedly
      transport = mock

      stuck_response = {
        "result" => {
          "tools" => [{ "name" => "tool1", "description" => "tool1", "inputSchema" => {} }],
          "nextCursor" => "stuck_cursor",
        },
      }

      # If the server keeps returning the same cursor, the client must not loop forever.
      # Expect at most 2 calls: the initial request (cursor=nil) and one retry (cursor="stuck_cursor")
      # that detects the repeat and breaks out.
      transport.expects(:send_request).twice.returns(stuck_response)

      client = Client.new(transport: transport)
      tools = client.tools

      assert_equal(2, tools.size)
    end

    def test_tools_breaks_when_server_cycles_between_cursors
      transport = mock

      page_a = {
        "result" => {
          "tools" => [{ "name" => "tool1", "description" => "tool1", "inputSchema" => {} }],
          "nextCursor" => "A",
        },
      }
      page_b = {
        "result" => {
          "tools" => [{ "name" => "tool2", "description" => "tool2", "inputSchema" => {} }],
          "nextCursor" => "B",
        },
      }
      # Server cycles A -> B -> A. Client must detect the revisited cursor and break.
      page_a_again = {
        "result" => {
          "tools" => [{ "name" => "tool3", "description" => "tool3", "inputSchema" => {} }],
          "nextCursor" => "A",
        },
      }

      transport.expects(:send_request).times(3).returns(page_a, page_b, page_a_again)

      client = Client.new(transport: transport)
      tools = client.tools

      assert_equal(3, tools.size)
      assert_equal(["tool1", "tool2", "tool3"], tools.map(&:name))
    end

    def test_resources_breaks_when_server_returns_same_cursor_repeatedly
      transport = mock

      stuck_response = {
        "result" => {
          "resources" => [{ "uri" => "https://a.invalid", "name" => "a" }],
          "nextCursor" => "stuck_cursor",
        },
      }

      transport.expects(:send_request).twice.returns(stuck_response)

      client = Client.new(transport: transport)
      resources = client.resources

      assert_equal(2, resources.size)
    end

    def test_resource_templates_breaks_when_server_returns_same_cursor_repeatedly
      transport = mock

      stuck_response = {
        "result" => {
          "resourceTemplates" => [{ "uriTemplate" => "https://a.invalid/{id}", "name" => "a" }],
          "nextCursor" => "stuck_cursor",
        },
      }

      transport.expects(:send_request).twice.returns(stuck_response)

      client = Client.new(transport: transport)
      templates = client.resource_templates

      assert_equal(2, templates.size)
    end

    def test_prompts_breaks_when_server_returns_same_cursor_repeatedly
      transport = mock

      stuck_response = {
        "result" => {
          "prompts" => [{ "name" => "prompt_a", "description" => "A" }],
          "nextCursor" => "stuck_cursor",
        },
      }

      transport.expects(:send_request).twice.returns(stuck_response)

      client = Client.new(transport: transport)
      prompts = client.prompts

      assert_equal(2, prompts.size)
    end

    def test_list_prompts_returns_single_page_with_cursor
      transport = mock

      mock_response = {
        "result" => {
          "prompts" => [{ "name" => "prompt_a", "description" => "A" }],
          "nextCursor" => "cursor1",
        },
      }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      result = client.list_prompts

      assert_equal(1, result.prompts.size)
      assert_equal("cursor1", result.next_cursor)
    end

    def test_cancellation_without_reason_omits_reason_in_notification
      # The token-driven cancel path must omit `reason` from the `notifications/cancelled` params
      # when the token is cancelled without one.
      sent = Queue.new
      cancellation = MCP::Cancellation.new

      transport = Object.new
      transport.define_singleton_method(:send_request) do |**|
        cancellation.cancel # no reason
        { "result" => {} }
      end
      transport.define_singleton_method(:send_notification) do |notification:|
        sent.push(notification)
        nil
      end

      client = Client.new(transport: transport)

      assert_raises(MCP::CancelledError) do
        client.call_tool(name: "slow", arguments: {}, cancellation: cancellation)
      end

      notification = sent.pop
      assert_equal(Methods::NOTIFICATIONS_CANCELLED, notification[:method])
      refute(notification[:params].key?(:reason))
    end

    def test_call_tool_with_cancellation_returns_response_when_no_cancel
      transport = mock
      transport.expects(:send_request).returns({ "result" => { "content" => [{ "type" => "text", "text" => "ok" }] } }).once
      transport.stubs(:send_notification) # required for `cancellation:` capability check

      cancellation = MCP::Cancellation.new
      client = Client.new(transport: transport)

      response = client.call_tool(name: "noop", arguments: {}, cancellation: cancellation)

      assert_equal("ok", response.dig("result", "content", 0, "text"))
    end

    def test_call_tool_with_cancellation_already_cancelled_raises_without_sending
      transport = mock
      transport.expects(:send_request).never
      transport.expects(:send_notification).never

      cancellation = MCP::Cancellation.new
      cancellation.cancel(reason: "pre-cancelled")

      client = Client.new(transport: transport)

      assert_raises(MCP::CancelledError) do
        client.call_tool(name: "noop", arguments: {}, cancellation: cancellation)
      end
    end

    def test_call_tool_with_cancellation_mid_flight_raises_and_sends_notification
      cancellation = MCP::Cancellation.new
      notification_queue = Queue.new

      transport = Object.new
      transport.define_singleton_method(:send_request) do |**|
        # Cancel while the request is "in flight".
        cancellation.cancel(reason: "user abort")
        sleep(0.05)
        { "result" => {} }
      end
      transport.define_singleton_method(:send_notification) do |notification:|
        notification_queue.push(notification)
        nil
      end

      client = Client.new(transport: transport)

      error = assert_raises(MCP::CancelledError) do
        client.call_tool(name: "slow", arguments: {}, cancellation: cancellation)
      end

      assert_equal("user abort", error.reason)

      # Cancel notification is dispatched fire-and-forget on a separate thread;
      # block here until it reaches the transport.
      notification = notification_queue.pop
      assert_equal(Methods::NOTIFICATIONS_CANCELLED, notification[:method])
      assert_equal("user abort", notification[:params][:reason])
    end

    def test_loop_methods_accept_cancellation_keyword
      # Regression: `tools` / `resources` / `resource_templates` / `prompts` are the high-level pagination loops.
      # They must accept `cancellation:` so the README's "all request methods accept the cancellation: keyword"
      # claim holds. The token is propagated to each underlying `list_*` page.
      cancellation = MCP::Cancellation.new

      transport = mock
      transport.stubs(:send_request).returns({ "result" => { "tools" => [] } })
      transport.stubs(:send_notification) # required for `cancellation:` capability check

      client = Client.new(transport: transport)

      [
        -> { client.tools(cancellation: cancellation) },
        -> { client.resources(cancellation: cancellation) },
        -> { client.resource_templates(cancellation: cancellation) },
        -> { client.prompts(cancellation: cancellation) },
      ].each do |loop_call|
        transport.stubs(:send_request).returns({ "result" => {} })
        loop_call.call
      end
    end

    def test_cancel_callback_does_not_deadlock_when_transport_holds_a_mutex
      # Regression: when the cancellation callback fires on the same thread that is currently inside
      # `transport.send_request` (and therefore holds a transport-level mutex), a synchronous `send_notification`
      # from the callback would deadlock by re-entering the same mutex. The fix wakes the calling thread first
      # and dispatches the notification on a separate thread.
      transport_mutex = Mutex.new
      cancellation = MCP::Cancellation.new

      # Custom transport class so we can model a mutex held during send_request.
      transport = Object.new
      transport.define_singleton_method(:send_request) do |**|
        transport_mutex.synchronize do
          # Trigger cancel while we hold the mutex. The callback must NOT try to synchronously acquire
          # the same mutex via send_notification.
          cancellation.cancel(reason: "mid-flight")
          # Hold the mutex briefly to give the callback time to (incorrectly) try to re-enter.
          sleep(0.05)
          { "result" => {} }
        end
      end

      # send_notification also needs the mutex - this is the path that would deadlock under synchronous dispatch.
      send_notification_called = Queue.new
      transport.define_singleton_method(:send_notification) do |notification:|
        transport_mutex.synchronize do
          send_notification_called.push(notification)
        end
      end

      client = Client.new(transport: transport)

      assert_raises(MCP::CancelledError) do
        client.call_tool(name: "noop", arguments: {}, cancellation: cancellation)
      end

      # The notification must reach the transport eventually (after the mutex is released by the now-finished send_request).
      notification = send_notification_called.pop
      assert_equal(Methods::NOTIFICATIONS_CANCELLED, notification[:method])
      assert_equal("mid-flight", notification[:params][:reason])
    end

    def test_late_cancel_after_response_does_not_send_stray_notification
      # Regression: between the worker thread pushing `:response` and the main thread leaving `dispatch_with_cancellation`,
      # a cancellation firing in that gap must not emit a stray `notifications/cancelled` for the already-completed request.
      # The completion-mutex gate makes the worker and the on_cancel callback fight for a single slot; whichever sets
      # `completed` first wins, the loser bails.
      cancellation = MCP::Cancellation.new
      notification_count = 0
      notification_count_mutex = Mutex.new

      transport = Object.new
      transport.define_singleton_method(:send_request) do |**, &on_sent|
        on_sent&.call
        { "result" => {} }
      end
      transport.define_singleton_method(:send_notification) do |**|
        notification_count_mutex.synchronize { notification_count += 1 }
        nil
      end

      client = Client.new(transport: transport)
      response = client.call_tool(name: "noop", arguments: {}, cancellation: cancellation)

      assert_equal({}, response["result"])

      # Cancel after the call returned. The on_cancel hook was deregistered in the `ensure` block;
      # even if a callback raced with the response handoff, `completed` would already be true and
      # `queue.push :cancelled` plus the cancel-dispatch thread would not run.
      cancellation.cancel(reason: "late")

      sleep(0.05) # let any erroneous cancel-dispatch thread complete.

      count = notification_count_mutex.synchronize { notification_count }
      assert_equal(0, count, "no stray notifications/cancelled for an already-completed request")
    end

    def test_call_tool_with_cancellation_raises_NoMethodError_when_transport_lacks_send_notification
      # Regression: a transport that only implements `send_request` cannot deliver `notifications/cancelled`.
      # We must surface this upfront with a clear `NoMethodError` rather than silently swallow
      # the failure inside the cancel-dispatch thread - otherwise the user sees `CancelledError` but
      # the server never receives the notification.
      transport = Object.new
      transport.define_singleton_method(:send_request) do |**|
        { "result" => {} }
      end
      # NOTE: no send_notification.

      cancellation = MCP::Cancellation.new
      client = Client.new(transport: transport)

      error = assert_raises(NoMethodError) do
        client.call_tool(name: "noop", arguments: {}, cancellation: cancellation)
      end

      assert_match(/send_notification/, error.message)
    end

    def test_cancel_notification_is_dispatched_after_request_write_via_on_sent_block
      # Regression for the wire-order race: a transport that yields from `send_request` after writing
      # the request must see `:request` recorded before `:cancel` even when the cancel signal arrives concurrently.
      recorded = []
      recorded_mutex = Mutex.new
      cancellation = MCP::Cancellation.new
      cancel_complete = Queue.new

      transport = Object.new
      transport.define_singleton_method(:send_request) do |request:, &on_sent|
        # Trigger cancel BEFORE the simulated wire-write so the cancel-dispatch thread starts racing immediately.
        # The `on_sent` block is yielded only after we have recorded the request - so any cancel-write that obeys
        # the block must land afterwards.
        cancellation.cancel(reason: "race")
        sleep(0.02) # give cancel-dispatch thread time to spawn and start waiting
        recorded_mutex.synchronize { recorded << [:request, request[:id]] }
        on_sent&.call
        { "result" => {} }
      end
      transport.define_singleton_method(:send_notification) do |notification:|
        recorded_mutex.synchronize { recorded << [:cancel, notification[:params][:requestId]] }
        cancel_complete.push(:done)
        nil
      end

      client = Client.new(transport: transport)
      client.stubs(:generate_request_id).returns("req-A")

      assert_raises(MCP::CancelledError) do
        client.call_tool(name: "slow", arguments: {}, cancellation: cancellation)
      end

      cancel_complete.pop # wait for the fire-and-forget cancel dispatch

      # Wire-order must be: request first, then cancel.
      assert_equal([[:request, "req-A"], [:cancel, "req-A"]], recorded)
    end

    def test_cancel_notification_waits_for_delayed_on_sent_signal
      # Regression: the cancel-dispatch thread must wait for `&on_sent` no matter how long it takes -
      # it cannot fall back to wall-clock-based timeout. An earlier 100 ms fixed-duration fallback
      # could release the cancel thread before the worker reached its send-boundary at all, allowing
      # the cancel to be issued without any prior request commitment - which the spec only covers under
      # the receiver's MAY-ignore-unknown-id clause. The wait is now bounded by worker termination
      # (via `ensure -> signal_sent.call`), not by elapsed time.
      recorded = []
      recorded_mutex = Mutex.new
      cancellation = MCP::Cancellation.new
      cancel_complete = Queue.new

      transport = Object.new
      transport.define_singleton_method(:send_request) do |request:, &on_sent|
        cancellation.cancel(reason: "race")
        # Delay well beyond any plausible fixed-duration fallback (200 ms).
        # If cancel-dispatch fires on a timer rather than waiting for on_sent,
        # the recorded order will be [:cancel, :request] and the assertion below will fail.
        sleep(0.2)
        recorded_mutex.synchronize { recorded << [:request, request[:id]] }
        on_sent&.call
        { "result" => {} }
      end
      transport.define_singleton_method(:send_notification) do |notification:|
        recorded_mutex.synchronize { recorded << [:cancel, notification[:params][:requestId]] }
        cancel_complete.push(:done)
        nil
      end

      client = Client.new(transport: transport)
      client.stubs(:generate_request_id).returns("req-D")

      assert_raises(MCP::CancelledError) do
        client.call_tool(name: "slow", arguments: {}, cancellation: cancellation)
      end

      cancel_complete.pop

      assert_equal([[:request, "req-D"], [:cancel, "req-D"]], recorded)
    end

    def test_cancel_notification_dispatches_when_worker_raises_before_on_sent
      # Regression: if the worker raises before `&on_sent` is called - which can happen if a transport rejects
      # a malformed request synchronously - the cancel-dispatch thread must still terminate AND deliver the notification.
      # The worker's `ensure` block invokes `signal_sent.call`, which broadcasts to the condition variable and unblocks
      # the `until request_sent` wait. Without the ensure-driven unblock, the dispatch thread would leak.
      cancellation = MCP::Cancellation.new
      send_notification_called = Queue.new

      transport = Object.new
      transport.define_singleton_method(:send_request) do |**|
        # Trigger cancel before raising so the cancel hook fires while the worker is mid-flight,
        # then bail out without ever calling on_sent.
        cancellation.cancel(reason: "race")
        raise StandardError, "transport boom"
      end
      transport.define_singleton_method(:send_notification) do |notification:|
        send_notification_called.push(notification)
        nil
      end

      client = Client.new(transport: transport)
      client.stubs(:generate_request_id).returns("req-E")

      assert_raises(MCP::CancelledError) do
        client.call_tool(name: "slow", arguments: {}, cancellation: cancellation)
      end

      # The cancel-dispatch thread should still send the notification because the worker's `ensure` triggers `signal_sent.call`.
      notification = send_notification_called.pop
      assert_equal("req-E", notification[:params][:requestId])
    end

    def test_call_tool_with_cancellation_normal_completion_does_not_send_notification
      transport = mock
      transport.expects(:send_request).returns({ "result" => {} }).once
      transport.expects(:send_notification).never

      cancellation = MCP::Cancellation.new
      client = Client.new(transport: transport)

      client.call_tool(name: "noop", arguments: {}, cancellation: cancellation)

      # Late cancel after normal completion: hook should already be deregistered.
      cancellation.cancel(reason: "late")
    end
  end
end
