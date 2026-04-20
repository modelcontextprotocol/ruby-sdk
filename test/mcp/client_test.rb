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
            { "name" => "tool1", "description" => "tool1", "inputSchema" => {} },
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
      assert_equal("tool2", tools.last.name)
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
  end
end
