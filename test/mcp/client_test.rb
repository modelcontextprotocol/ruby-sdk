# frozen_string_literal: true

require "test_helper"

module MCP
  class ClientTest < Minitest::Test
    def test_tools_delegates_to_transport
      transport = mock
      mock_tools = [
        MCP::Client::Tool.new(name: "tool1", description: "tool1", input_schema: {}),
        MCP::Client::Tool.new(name: "tool2", description: "tool2", input_schema: {}),
      ]
      transport.expects(:tools).returns(mock_tools).once
      client = Client.new(transport: transport)
      assert_equal(mock_tools, client.tools)
    end

    def test_call_tool_delegates_to_transport
      transport = mock
      tool = MCP::Client::Tool.new(name: "tool1", description: "tool1", input_schema: {})
      transport.expects(:call_tool).with(tool: tool, input: { foo: "bar" }).returns("result")
      client = Client.new(transport: transport)
      assert_equal("result", client.call_tool(tool: tool, input: { foo: "bar" }))
    end
  end
end
