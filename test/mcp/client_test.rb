# frozen_string_literal: true

require "test_helper"
require "securerandom"

module MCP
  class ClientTest < Minitest::Test
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

      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "tools/list" && args.dig(:request, :jsonrpc) == "2.0"
      end.returns(response_body).once

      client = Client.new(transport: transport)
      tools = client.tools

      assert_equal(2, tools.size)
      assert_equal("tool1", tools.first.name)
      assert_equal("tool2", tools.last.name)
    end

    def test_tools_returns_empty_array_when_no_tools
      transport = mock
      response_body = { "result" => { "tools" => [] } }

      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "tools/list" && args.dig(:request, :jsonrpc) == "2.0"
      end.returns(response_body).once

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

      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "tools/call" &&
          args.dig(:request, :jsonrpc) == "2.0" &&
          args.dig(:request, :params, :name) == "tool1" &&
          args.dig(:request, :params, :arguments) == arguments
      end.returns(response_body).once

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

      transport.expects(:send_request).with do |args|
        args.dig(:request, :params, :name) == "tool1" &&
          args.dig(:request, :params, :arguments) == arguments
      end.returns(response_body).once

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

      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "resources/list" && args.dig(:request, :jsonrpc) == "2.0"
      end.returns(response_body).once

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

      transport.expects(:send_request).returns(response_body).once

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

      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "resources/read" &&
          args.dig(:request, :jsonrpc) == "2.0" &&
          args.dig(:request, :params, :uri) == uri
      end.returns(response_body).once

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

      transport.expects(:send_request).returns(response_body).once

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

      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "resources/templates/list" && args.dig(:request, :jsonrpc) == "2.0"
      end.returns(response_body).once

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

      transport.expects(:send_request).returns(response_body).once

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

      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "prompts/list" && args.dig(:request, :jsonrpc) == "2.0"
      end.returns(response_body).once

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

      transport.expects(:send_request).returns(response_body).once

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

      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "prompts/get" &&
          args.dig(:request, :jsonrpc) == "2.0" &&
          args.dig(:request, :params, :name) == name
      end.returns(response_body).once

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

      transport.expects(:send_request).returns(response_body).once

      client = Client.new(transport: transport)
      contents = client.get_prompt(name: name)

      assert_equal({}, contents)
    end

    def test_get_prompt_returns_empty_hash
      transport = mock
      name = "nonexistent_prompt"
      response_body = {}

      transport.expects(:send_request).returns(response_body).once

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

      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "tools/call" &&
          args.dig(:request, :params, :_meta, :progressToken) == progress_token &&
          args.dig(:request, :params, :name) == "tool1" &&
          args.dig(:request, :params, :arguments) == arguments
      end.returns(response_body).once

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

      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "tools/call" &&
          args.dig(:request, :params, :name) == "tool1" &&
          args.dig(:request, :params).key?(:_meta) == false
      end.returns(response_body).once

      client = Client.new(transport: transport)
      client.call_tool(tool: tool, arguments: arguments)
    end

    def test_tools_raises_server_error_on_error_response
      transport = mock
      response_body = { "error" => { "code" => -32_601, "message" => "Method not found" } }

      transport.expects(:send_request).returns(response_body).once

      client = Client.new(transport: transport)
      error = assert_raises(Client::ServerError) { client.tools }
      assert_equal(-32_601, error.code)
      assert_equal("Method not found", error.message)
    end

    def test_resources_raises_server_error_on_error_response
      transport = mock
      response_body = { "error" => { "code" => -32_602, "message" => "Invalid params" } }

      transport.expects(:send_request).returns(response_body).once

      client = Client.new(transport: transport)
      error = assert_raises(Client::ServerError) { client.resources }
      assert_equal(-32_602, error.code)
    end

    def test_read_resource_raises_server_error_on_error_response
      transport = mock
      response_body = { "error" => { "code" => -32_602, "message" => "Resource not found" } }

      transport.expects(:send_request).returns(response_body).once

      client = Client.new(transport: transport)
      assert_raises(Client::ServerError) { client.read_resource(uri: "file:///missing") }
    end

    def test_get_prompt_raises_server_error_on_error_response
      transport = mock
      response_body = { "error" => { "code" => -32_602, "message" => "Prompt not found" } }

      transport.expects(:send_request).returns(response_body).once

      client = Client.new(transport: transport)
      assert_raises(Client::ServerError) { client.get_prompt(name: "missing") }
    end

    def test_prompts_raises_server_error_on_error_response
      transport = mock
      response_body = { "error" => { "code" => -32_601, "message" => "Method not found" } }

      transport.expects(:send_request).returns(response_body).once

      client = Client.new(transport: transport)
      assert_raises(Client::ServerError) { client.prompts }
    end

    def test_resource_templates_raises_server_error_on_error_response
      transport = mock
      response_body = { "error" => { "code" => -32_601, "message" => "Method not found" } }

      transport.expects(:send_request).returns(response_body).once

      client = Client.new(transport: transport)
      assert_raises(Client::ServerError) { client.resource_templates }
    end

    def test_call_tool_raises_server_error_on_error_response
      transport = mock
      response_body = { "error" => { "code" => -32_602, "message" => "Tool not found" } }

      transport.expects(:send_request).returns(response_body).once

      client = Client.new(transport: transport)
      error = assert_raises(Client::ServerError) { client.call_tool(name: "missing") }
      assert_equal(-32_602, error.code)
    end

    def test_server_error_includes_data_field
      transport = mock
      response_body = {
        "error" => { "code" => -32_603, "message" => "Internal error", "data" => "extra details" },
      }

      transport.expects(:send_request).returns(response_body).once

      client = Client.new(transport: transport)
      error = assert_raises(Client::ServerError) { client.tools }
      assert_equal("extra details", error.data)
    end

    def test_complete_raises_server_error_on_error_response
      transport = mock
      response_body = { "error" => { "code" => -32_602, "message" => "Invalid params" } }

      transport.expects(:send_request).returns(response_body).once

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

      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "completion/complete" &&
          args.dig(:request, :jsonrpc) == "2.0" &&
          args.dig(:request, :params, :ref) == { type: "ref/prompt", name: "code_review" } &&
          args.dig(:request, :params, :argument) == { name: "language", value: "py" } &&
          !args.dig(:request, :params).key?(:context)
      end.returns(response_body).once

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

      transport.expects(:send_request).with do |args|
        args.dig(:request, :params, :context) == { arguments: { language: "python" } }
      end.returns(response_body).once

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

      transport.expects(:send_request).returns(response_body).once

      client = Client.new(transport: transport)
      result = client.complete(
        ref: { type: "ref/prompt", name: "test" },
        argument: { name: "arg", value: "" },
      )

      assert_equal([], result["values"])
      refute(result["hasMore"])
    end

    def test_connected_returns_false_when_transport_has_no_protocol_version
      transport = mock
      transport.stubs(:respond_to?).with(:session_id).returns(true)
      transport.stubs(:respond_to?).with(:protocol_version).returns(true)
      transport.stubs(:session_id).returns(nil)
      transport.stubs(:protocol_version).returns(nil)

      client = Client.new(transport: transport)

      refute(client.connected?)
      assert_nil(client.session_id)
      assert_nil(client.protocol_version)
    end

    def test_session_id_and_protocol_version_delegate_to_transport
      transport = mock
      transport.stubs(:respond_to?).with(:session_id).returns(true)
      transport.stubs(:respond_to?).with(:protocol_version).returns(true)
      transport.stubs(:session_id).returns("session-123")
      transport.stubs(:protocol_version).returns("2024-11-05")

      client = Client.new(transport: transport)

      assert(client.connected?)
      assert_equal("session-123", client.session_id)
      assert_equal("2024-11-05", client.protocol_version)
    end

    def test_session_id_nil_when_transport_does_not_respond
      transport = mock
      transport.stubs(:respond_to?).with(:session_id).returns(false)
      transport.stubs(:respond_to?).with(:protocol_version).returns(false)

      client = Client.new(transport: transport)

      assert_nil(client.session_id)
      assert_nil(client.protocol_version)
      refute(client.connected?)
    end

    def test_connect_sends_initialize_request
      transport = mock
      response_body = {
        "result" => {
          "protocolVersion" => "2024-11-05",
          "serverInfo" => { "name" => "test-server", "version" => "1.0" },
          "capabilities" => {},
        },
      }

      transport.expects(:send_request).with do |args|
        args.dig(:request, :method) == "initialize" &&
          args.dig(:request, :params, :clientInfo, :name) == "test-client"
      end.returns(response_body).once

      client = Client.new(transport: transport)
      result = client.connect(client_info: { name: "test-client", version: "1.0" })

      assert_equal("test-server", result.dig("result", "serverInfo", "name"))
    end

    def test_close_delegates_to_transport_when_supported
      transport = mock
      transport.stubs(:respond_to?).with(:close).returns(true)
      transport.expects(:close).once

      client = Client.new(transport: transport)
      client.close
    end

    def test_close_noop_when_transport_does_not_respond
      transport = mock
      transport.stubs(:respond_to?).with(:close).returns(false)
      transport.expects(:close).never

      client = Client.new(transport: transport)
      client.close
    end
  end
end
