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

      assert_equal("result", result)
    end
  end
end
