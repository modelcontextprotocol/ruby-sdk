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
        args in { request: { method: "tools/list", jsonrpc: "2.0" } }
      end.returns(mock_response).once

      client = Client.new(transport: transport)
      tools = client.tools

      assert_equal(2, tools.size)
      assert_equal("tool1", tools.first.name)
      assert_equal("tool2", tools.last.name)
    end

    def test_call_tool_sends_request_to_transport_and_returns_content
      transport = mock
      tool = MCP::Client::Tool.new(name: "tool1", description: "tool1", input_schema: {})
      arguments = { foo: "bar" }
      mock_response = {
        "result" => { "content" => "result" },
      }

      # Only checking for the essential parts of the request
      transport.expects(:send_request).with do |args|
        args in {
          request: {
            method: "tools/call",
            jsonrpc: "2.0",
            params: {
              name: "tool1",
              arguments: arguments,
            },
          },
        }
      end.returns(mock_response).once

      client = Client.new(transport: transport)
      result = client.call_tool(tool: tool, arguments: arguments)
      content = result.dig("result", "content")

      assert_equal("result", content)
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
        args in { request: { method: "resources/list", jsonrpc: "2.0" } }
      end.returns(mock_response).once

      client = Client.new(transport: transport)
      resources = client.resources

      assert_equal(2, resources.size)
      assert_equal("resource1", resources.first["name"])
      assert_equal("file:///path/to/resource1", resources.first["uri"])
      assert_equal("resource2", resources.last["name"])
      assert_equal("file:///path/to/resource2", resources.last["uri"])
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
        args in {
          request: {
            method: "resources/read",
            jsonrpc: "2.0",
            params: {
              uri: uri,
            },
          },
        }
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

      assert_empty(contents)
    end

    def test_resources_returns_empty_array_when_no_resources
      transport = mock
      mock_response = { "result" => {} }

      transport.expects(:send_request).returns(mock_response).once

      client = Client.new(transport: transport)
      resources = client.resources

      assert_empty(resources)
    end
  end
end
