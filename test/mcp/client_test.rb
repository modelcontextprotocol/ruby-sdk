# frozen_string_literal: true

require "test_helper"
require "securerandom"

module MCP
  class ClientTest < Minitest::Test
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
  end
end
