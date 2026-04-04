# frozen_string_literal: true

require "test_helper"
require "securerandom"

module MCP
  class ClientTest < Minitest::Test
    # Helper to create a mock response struct like HTTP::Response
    def mock_response(body:, headers: {})
      Struct.new(:body, :headers, keyword_init: true).new(body: body, headers: headers)
    end

    def test_tools_sends_request_to_transport_and_returns_tools_array
      transport = mock
      response_body = {
        "result" => {
          "tools" => [
            { "name" => "tool1", "description" => "tool1", "inputSchema" => {} },
            { "name" => "tool2", "description" => "tool2", "inputSchema" => {} },
          ],
        },
      }

      # Only checking for the essential parts of the request
      transport.expects(:post).with do |args|
        args.dig(:body, :method) == "tools/list" && args.dig(:body, :jsonrpc) == "2.0"
      end.returns(mock_response(body: response_body)).once

      client = Client.new(transport: transport)
      tools = client.tools

      assert_equal(2, tools.size)
      assert_equal("tool1", tools.first.name)
      assert_equal("tool2", tools.last.name)
    end

    def test_tools_returns_empty_array_when_no_tools
      transport = mock
      response_body = { "result" => { "tools" => [] } }

      # Only checking for the essential parts of the request
      transport.expects(:post).with do |args|
        args.dig(:body, :method) == "tools/list" && args.dig(:body, :jsonrpc) == "2.0"
      end.returns(mock_response(body: response_body)).once

      client = Client.new(transport: transport)
      tools = client.tools

      assert_equal([], tools)
    end

    def test_call_tool_sends_request_to_transport_and_returns_content
      transport = mock
      tool = MCP::Client::Tool.new(name: "tool1", description: "tool1", input_schema: {})
      arguments = { foo: "bar" }
      response_body = {
        "result" => { "content" => [{ "type": "text", "text": "Hello, world!" }] },
      }

      # Only checking for the essential parts of the request
      transport.expects(:post).with do |args|
        args.dig(:body, :method) == "tools/call" &&
          args.dig(:body, :jsonrpc) == "2.0" &&
          args.dig(:body, :params, :name) == "tool1" &&
          args.dig(:body, :params, :arguments) == arguments
      end.returns(mock_response(body: response_body)).once

      client = Client.new(transport: transport)
      result = client.call_tool(tool: tool, arguments: arguments)
      content = result.dig("result", "content")

      assert_equal([{ type: "text", text: "Hello, world!" }], content)
    end

    def test_call_tool_by_name
      transport = mock
      arguments = { foo: "bar" }
      response_body = {
        "result" => { "content" => [{ "type": "text", "text": "Hello, world!" }] },
      }

      transport.expects(:post).with do |args|
        args.dig(:body, :params, :name) == "tool1" &&
          args.dig(:body, :params, :arguments) == arguments
      end.returns(mock_response(body: response_body)).once

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
      response_body = {
        "result" => {
          "resources" => [
            { "name" => "resource1", "uri" => "file:///path/to/resource1", "description" => "First resource" },
            { "name" => "resource2", "uri" => "file:///path/to/resource2", "description" => "Second resource" },
          ],
        },
      }

      # Only checking for the essential parts of the request
      transport.expects(:post).with do |args|
        args.dig(:body, :method) == "resources/list" && args.dig(:body, :jsonrpc) == "2.0"
      end.returns(mock_response(body: response_body)).once

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
      response_body = { "result" => { "resources" => [] } }

      transport.expects(:post).returns(mock_response(body: response_body)).once

      client = Client.new(transport: transport)
      resources = client.resources

      assert_equal([], resources)
    end

    def test_read_resource_sends_request_to_transport_and_returns_contents
      transport = mock
      uri = "file:///path/to/resource.txt"
      response_body = {
        "result" => {
          "contents" => [
            { "uri" => uri, "mimeType" => "text/plain", "text" => "Hello, world!" },
          ],
        },
      }

      # Only checking for the essential parts of the request
      transport.expects(:post).with do |args|
        args.dig(:body, :method) == "resources/read" &&
          args.dig(:body, :jsonrpc) == "2.0" &&
          args.dig(:body, :params, :uri) == uri
      end.returns(mock_response(body: response_body)).once

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
      response_body = { "result" => {} }

      transport.expects(:post).returns(mock_response(body: response_body)).once

      client = Client.new(transport: transport)
      contents = client.read_resource(uri: uri)

      assert_equal([], contents)
    end

    def test_resource_templates_sends_request_to_transport_and_returns_resource_templates_array
      transport = mock
      response_body = {
        "result" => {
          "resourceTemplates" => [
            { "name" => "template1", "uriTemplate" => "file:///path/{filename}", "description" => "First template" },
            { "name" => "template2", "uriTemplate" => "http://example.com/{id}", "description" => "Second template" },
          ],
        },
      }

      transport.expects(:post).with do |args|
        args.dig(:body, :method) == "resources/templates/list" && args.dig(:body, :jsonrpc) == "2.0"
      end.returns(mock_response(body: response_body)).once

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
      response_body = { "result" => { "resourceTemplates" => [] } }

      transport.expects(:post).returns(mock_response(body: response_body)).once

      client = Client.new(transport: transport)
      resource_templates = client.resource_templates

      assert_equal([], resource_templates)
    end

    def test_prompts_sends_request_to_transport_and_returns_prompts_array
      transport = mock
      response_body = {
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
      transport.expects(:post).with do |args|
        args.dig(:body, :method) == "prompts/list" && args.dig(:body, :jsonrpc) == "2.0"
      end.returns(mock_response(body: response_body)).once

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
      response_body = { "result" => { "prompts" => [] } }

      transport.expects(:post).returns(mock_response(body: response_body)).once

      client = Client.new(transport: transport)
      prompts = client.prompts

      assert_equal([], prompts)
    end

    def test_get_prompt_sends_request_to_transport_and_returns_contents
      transport = mock
      name = "first_prompt"
      response_body = {
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
      transport.expects(:post).with do |args|
        args.dig(:body, :method) == "prompts/get" &&
          args.dig(:body, :jsonrpc) == "2.0" &&
          args.dig(:body, :params, :name) == name
      end.returns(mock_response(body: response_body)).once

      client = Client.new(transport: transport)
      contents = client.get_prompt(name: name)

      assert_equal("First prompt", contents["description"])
      assert_equal("user", contents["messages"].first["role"])
      assert_equal("First prompt content", contents["messages"].first["content"]["text"])
    end

    def test_get_prompt_returns_empty_hash_when_no_contents
      transport = mock
      name = "nonexistent_prompt"
      response_body = { "result" => {} }

      transport.expects(:post).returns(mock_response(body: response_body)).once

      client = Client.new(transport: transport)
      contents = client.get_prompt(name: name)

      assert_equal({}, contents)
    end

    def test_get_prompt_returns_empty_hash
      transport = mock
      name = "nonexistent_prompt"
      response_body = {}

      transport.expects(:post).returns(mock_response(body: response_body)).once

      client = Client.new(transport: transport)
      contents = client.get_prompt(name: name)

      assert_equal({}, contents)
    end

    def test_call_tool_includes_meta_progress_token_when_provided
      transport = mock
      tool = MCP::Client::Tool.new(name: "tool1", description: "tool1", input_schema: {})
      arguments = { foo: "bar" }
      progress_token = "my-progress-token"
      response_body = {
        "result" => { "content" => [{ "type": "text", "text": "Hello, world!" }] },
      }

      transport.expects(:post).with do |args|
        args.dig(:body, :method) == "tools/call" &&
          args.dig(:body, :params, :_meta, :progressToken) == progress_token &&
          args.dig(:body, :params, :name) == "tool1" &&
          args.dig(:body, :params, :arguments) == arguments
      end.returns(mock_response(body: response_body)).once

      client = Client.new(transport: transport)
      client.call_tool(tool: tool, arguments: arguments, progress_token: progress_token)
    end

    def test_call_tool_omits_meta_when_no_progress_token
      transport = mock
      tool = MCP::Client::Tool.new(name: "tool1", description: "tool1", input_schema: {})
      arguments = { foo: "bar" }
      response_body = {
        "result" => { "content" => [{ "type": "text", "text": "Hello, world!" }] },
      }

      transport.expects(:post).with do |args|
        args.dig(:body, :method) == "tools/call" &&
          args.dig(:body, :params, :name) == "tool1" &&
          args.dig(:body, :params).key?(:_meta) == false
      end.returns(mock_response(body: response_body)).once

      client = Client.new(transport: transport)
      client.call_tool(tool: tool, arguments: arguments)
    end

    def test_tools_raises_server_error_on_error_response
      transport = mock
      response_body = { "error" => { "code" => -32_601, "message" => "Method not found" } }

      transport.expects(:post).returns(mock_response(body: response_body)).once

      client = Client.new(transport: transport)
      error = assert_raises(Client::ServerError) { client.tools }
      assert_equal(-32_601, error.code)
      assert_equal("Method not found", error.message)
    end

    def test_resources_raises_server_error_on_error_response
      transport = mock
      response_body = { "error" => { "code" => -32_602, "message" => "Invalid params" } }

      transport.expects(:post).returns(mock_response(body: response_body)).once

      client = Client.new(transport: transport)
      error = assert_raises(Client::ServerError) { client.resources }
      assert_equal(-32_602, error.code)
    end

    def test_read_resource_raises_server_error_on_error_response
      transport = mock
      response_body = { "error" => { "code" => -32_602, "message" => "Resource not found" } }

      transport.expects(:post).returns(mock_response(body: response_body)).once

      client = Client.new(transport: transport)
      assert_raises(Client::ServerError) { client.read_resource(uri: "file:///missing") }
    end

    def test_get_prompt_raises_server_error_on_error_response
      transport = mock
      response_body = { "error" => { "code" => -32_602, "message" => "Prompt not found" } }

      transport.expects(:post).returns(mock_response(body: response_body)).once

      client = Client.new(transport: transport)
      assert_raises(Client::ServerError) { client.get_prompt(name: "missing") }
    end

    def test_prompts_raises_server_error_on_error_response
      transport = mock
      response_body = { "error" => { "code" => -32_601, "message" => "Method not found" } }

      transport.expects(:post).returns(mock_response(body: response_body)).once

      client = Client.new(transport: transport)
      assert_raises(Client::ServerError) { client.prompts }
    end

    def test_resource_templates_raises_server_error_on_error_response
      transport = mock
      response_body = { "error" => { "code" => -32_601, "message" => "Method not found" } }

      transport.expects(:post).returns(mock_response(body: response_body)).once

      client = Client.new(transport: transport)
      assert_raises(Client::ServerError) { client.resource_templates }
    end

    def test_call_tool_raises_server_error_on_error_response
      transport = mock
      response_body = { "error" => { "code" => -32_602, "message" => "Tool not found" } }

      transport.expects(:post).returns(mock_response(body: response_body)).once

      client = Client.new(transport: transport)
      error = assert_raises(Client::ServerError) { client.call_tool(name: "missing") }
      assert_equal(-32_602, error.code)
    end

    def test_server_error_includes_data_field
      transport = mock
      response_body = {
        "error" => { "code" => -32_603, "message" => "Internal error", "data" => "extra details" },
      }

      transport.expects(:post).returns(mock_response(body: response_body)).once

      client = Client.new(transport: transport)
      error = assert_raises(Client::ServerError) { client.tools }
      assert_equal("extra details", error.data)
    end

    def test_complete_raises_server_error_on_error_response
      transport = mock
      response_body = { "error" => { "code" => -32_602, "message" => "Invalid params" } }

      transport.expects(:post).returns(mock_response(body: response_body)).once

      client = Client.new(transport: transport)
      error = assert_raises(Client::ServerError) do
        client.complete(ref: { type: "ref/prompt", name: "missing" }, argument: { name: "arg", value: "" })
      end
      assert_equal(-32_602, error.code)
    end

    def test_complete_sends_request_and_returns_completion_result
      transport = mock
      response_body = {
        "result" => {
          "completion" => {
            "values" => ["python", "pytorch"],
            "hasMore" => false,
          },
        },
      }

      transport.expects(:post).with do |args|
        args.dig(:body, :method) == "completion/complete" &&
          args.dig(:body, :jsonrpc) == "2.0" &&
          args.dig(:body, :params, :ref) == { type: "ref/prompt", name: "code_review" } &&
          args.dig(:body, :params, :argument) == { name: "language", value: "py" } &&
          !args.dig(:body, :params).key?(:context)
      end.returns(mock_response(body: response_body)).once

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
      response_body = {
        "result" => {
          "completion" => {
            "values" => ["flask"],
            "hasMore" => false,
          },
        },
      }

      transport.expects(:post).with do |args|
        args.dig(:body, :params, :context) == { arguments: { language: "python" } }
      end.returns(mock_response(body: response_body)).once

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
      response_body = { "result" => {} }

      transport.expects(:post).returns(mock_response(body: response_body)).once

      client = Client.new(transport: transport)
      result = client.complete(
        ref: { type: "ref/prompt", name: "test" },
        argument: { name: "arg", value: "" },
      )

      assert_equal([], result["values"])
      refute(result["hasMore"])
    end

    def test_connected_returns_false_before_connect
      transport = mock
      client = Client.new(transport: transport)

      refute(client.connected?)
      assert_nil(client.session_id)
      assert_nil(client.protocol_version)
    end

    def test_connect_extracts_session_id_and_protocol_version
      transport = mock
      response_body = {
        "result" => {
          "protocolVersion" => "2024-11-05",
          "serverInfo" => { "name" => "test-server", "version" => "1.0" },
          "capabilities" => {},
        },
      }

      transport.expects(:post).with do |args|
        args.dig(:body, :method) == "initialize" &&
          args.dig(:body, :params, :clientInfo, :name) == "test-client"
      end.returns(mock_response(body: response_body, headers: { "mcp-session-id" => "session-123" })).once

      client = Client.new(transport: transport)
      result = client.connect(client_info: { name: "test-client", version: "1.0" })

      assert(client.connected?)
      assert_equal("session-123", client.session_id)
      assert_equal("2024-11-05", client.protocol_version)
      assert_equal("test-server", result.dig("result", "serverInfo", "name"))
    end

    def test_connect_uses_server_protocol_version
      transport = mock
      response_body = {
        "result" => {
          "protocolVersion" => "2025-03-26",
          "serverInfo" => {},
          "capabilities" => {},
        },
      }

      transport.expects(:post).returns(mock_response(body: response_body, headers: {})).once

      client = Client.new(transport: transport)
      client.connect(
        client_info: { name: "test-client", version: "1.0" },
        protocol_version: "2024-11-05",
      )

      assert_equal("2025-03-26", client.protocol_version)
    end

    def test_request_includes_session_headers_after_initialization
      transport = mock

      init_response = mock_response(
        body: { "result" => { "protocolVersion" => "2024-11-05" } },
        headers: { "mcp-session-id" => "session-abc" },
      )
      transport.expects(:post).returns(init_response).once

      client = Client.new(transport: transport)
      client.connect(client_info: { name: "test", version: "1.0" })

      tools_response = mock_response(body: { "result" => { "tools" => [] } })
      transport.expects(:post).with do |args|
        args[:headers][Client::SESSION_ID_HEADER] == "session-abc" &&
          args[:headers][Client::PROTOCOL_VERSION_HEADER] == "2024-11-05"
      end.returns(tools_response).once

      client.tools
    end

    def test_session_expired_clears_session_state
      transport = mock

      init_response = mock_response(
        body: { "result" => { "protocolVersion" => "2024-11-05" } },
        headers: { "mcp-session-id" => "session-xyz" },
      )
      transport.expects(:post).returns(init_response).once

      client = Client.new(transport: transport)
      client.connect(client_info: { name: "test", version: "1.0" })

      assert_equal("session-xyz", client.session_id)

      transport.expects(:post).raises(Client::SessionExpiredError.new("Session expired", {}))

      assert_raises(Client::SessionExpiredError) do
        client.tools
      end

      assert_nil(client.session_id)
      assert_nil(client.protocol_version)
    end

    def test_close_sends_delete_request_with_session_headers
      transport = mock

      init_response = mock_response(
        body: { "result" => { "protocolVersion" => "2024-11-05" } },
        headers: { "mcp-session-id" => "session-to-close" },
      )
      transport.expects(:post).returns(init_response).once

      client = Client.new(transport: transport)
      client.connect(client_info: { name: "test", version: "1.0" })

      transport.expects(:delete).with do |args|
        args[:headers][Client::SESSION_ID_HEADER] == "session-to-close" &&
          args[:headers][Client::PROTOCOL_VERSION_HEADER] == "2024-11-05"
      end.once

      client.close

      assert_nil(client.session_id)
      assert_nil(client.protocol_version)
    end

    def test_close_does_nothing_without_session
      transport = mock
      client = Client.new(transport: transport)

      # delete should not be called
      transport.expects(:delete).never

      client.close

      assert_nil(client.session_id)
    end

    def test_session_id_not_overwritten_by_subsequent_responses
      transport = mock

      init_response = mock_response(
        body: { "result" => { "protocolVersion" => "2024-11-05" } },
        headers: { "mcp-session-id" => "original-session" },
      )
      transport.expects(:post).returns(init_response).once

      client = Client.new(transport: transport)
      client.connect(client_info: { name: "test", version: "1.0" })

      assert_equal("original-session", client.session_id)

      # Subsequent response has different session ID (shouldn't happen per spec)
      tools_response = mock_response(
        body: { "result" => { "tools" => [] } },
        headers: { "mcp-session-id" => "different-session" },
      )
      transport.expects(:post).returns(tools_response).once

      client.tools

      # Original session ID should be preserved
      assert_equal("original-session", client.session_id)
    end

    def test_connect_works_without_session_id_for_stateless_servers
      transport = mock
      response_body = {
        "result" => {
          "protocolVersion" => "2024-11-05",
          "serverInfo" => { "name" => "stateless-server", "version" => "1.0" },
          "capabilities" => {},
        },
      }

      # Stateless server doesn't return session ID
      transport.expects(:post).returns(mock_response(body: response_body, headers: {})).once

      client = Client.new(transport: transport)
      client.connect(client_info: { name: "test", version: "1.0" })

      # Client is still connected even without session ID
      assert(client.connected?)
      assert_nil(client.session_id)
      assert_equal("2024-11-05", client.protocol_version)
    end

    def test_request_works_without_session_id_for_stateless_servers
      transport = mock

      init_response = mock_response(
        body: { "result" => { "protocolVersion" => "2024-11-05" } },
        headers: {},
      )
      transport.expects(:post).returns(init_response).once

      client = Client.new(transport: transport)
      client.connect(client_info: { name: "test", version: "1.0" })

      tools_response = mock_response(body: { "result" => { "tools" => [] } })
      transport.expects(:post).with do |args|
        # Session ID header should not be present for stateless servers
        !args[:headers].key?(Client::SESSION_ID_HEADER) &&
          args[:headers][Client::PROTOCOL_VERSION_HEADER] == "2024-11-05"
      end.returns(tools_response).once

      client.tools
    end
  end
end
