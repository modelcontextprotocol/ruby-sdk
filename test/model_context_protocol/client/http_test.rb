# frozen_string_literal: true

require "test_helper"
require "faraday"
require "securerandom"
require "webmock/minitest"

module ModelContextProtocol
  module Client
    class HttpTest < Minitest::Test
      def test_initialization_with_default_version
        assert_equal("0.1.0", client.version)
        assert_equal(url, client.url)
      end

      def test_initialization_with_custom_version
        custom_version = "1.2.3"
        client = Http.new(url:, version: custom_version)
        assert_equal(custom_version, client.version)
      end

      def test_tools_returns_tools_instance
        stub_request(:post, url)
          .with(
            body: {
              method: "tools/list",
              jsonrpc: "2.0",
              id: mock_request_id,
              mcp: {
                method: "tools/list",
                jsonrpc: "2.0",
                id: mock_request_id,
              },
            },
          )
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
            },
            body: {
              result: {
                tools: [
                  {
                    name: "test_tool",
                    description: "A test tool",
                    inputSchema: {
                      type: "object",
                      properties: {},
                    },
                  },
                ],
              },
            }.to_json,
          )

        tools = client.tools
        assert_instance_of(Tools, tools)
        assert_equal(1, tools.count)
        assert_equal("test_tool", tools.first.name)
      end

      def test_call_tool_returns_tool_response
        tool = Tool.new(
          "name" => "test_tool",
          "description" => "A test tool",
          "inputSchema" => {
            "type" => "object",
            "properties" => {},
          },
        )
        input = { "param" => "value" }

        stub_request(:post, url)
          .with(
            body: {
              jsonrpc: "2.0",
              id: mock_request_id,
              method: "tools/call",
              params: {
                name: "test_tool",
                arguments: input,
              },
              mcp: {
                jsonrpc: "2.0",
                id: mock_request_id,
                method: "tools/call",
                params: {
                  name: "test_tool",
                  arguments: input,
                },
              },
            },
          )
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
            },
            body: {
              result: {
                content: [
                  {
                    text: "Tool response",
                  },
                ],
              },
            }.to_json,
          )

        response = client.call_tool(tool: tool, input: input)
        assert_equal("Tool response", response)
      end

      def test_call_tool_handles_empty_response
        tool = Tool.new(
          "name" => "test_tool",
          "description" => "A test tool",
          "inputSchema" => {
            "type" => "object",
            "properties" => {},
          },
        )
        input = { "param" => "value" }

        stub_request(:post, url)
          .with(
            body: {
              jsonrpc: "2.0",
              id: mock_request_id,
              method: "tools/call",
              params: {
                name: "test_tool",
                arguments: input,
              },
              mcp: {
                jsonrpc: "2.0",
                id: mock_request_id,
                method: "tools/call",
                params: {
                  name: "test_tool",
                  arguments: input,
                },
              },
            },
          )
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
            },
            body: {
              result: {
                content: [],
              },
            }.to_json,
          )

        response = client.call_tool(tool: tool, input: input)
        assert_nil(response)
      end

      private

      def stub_request(method, url)
        WebMock.stub_request(method, url)
      end

      def mock_request_id
        "random_request_id"
      end

      def url
        "http://example.com"
      end

      def client
        @client ||= begin
          client = Http.new(url:)
          client.stubs(:request_id).returns(mock_request_id)
          client
        end
      end
    end
  end
end
