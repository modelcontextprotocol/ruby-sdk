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

      def test_raises_bad_request_error
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
          .to_return(status: 400)

        error = assert_raises(RequestHandlerError) do
          client.call_tool(tool: tool, input: input)
        end

        assert_equal("The tools/call request is invalid", error.message)
        assert_equal(:bad_request, error.error_type)
        assert_equal({ method: "tools/call", params: { name: "test_tool", arguments: input } }, error.request)
      end

      def test_raises_unauthorized_error
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
          .to_return(status: 401)

        error = assert_raises(RequestHandlerError) do
          client.call_tool(tool: tool, input: input)
        end

        assert_equal("You are unauthorized to make tools/call requests", error.message)
        assert_equal(:unauthorized, error.error_type)
        assert_equal({ method: "tools/call", params: { name: "test_tool", arguments: input } }, error.request)
      end

      def test_raises_forbidden_error
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
          .to_return(status: 403)

        error = assert_raises(RequestHandlerError) do
          client.call_tool(tool: tool, input: input)
        end

        assert_equal("You are forbidden to make tools/call requests", error.message)
        assert_equal(:forbidden, error.error_type)
        assert_equal({ method: "tools/call", params: { name: "test_tool", arguments: input } }, error.request)
      end

      def test_raises_not_found_error
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
          .to_return(status: 404)

        error = assert_raises(RequestHandlerError) do
          client.call_tool(tool: tool, input: input)
        end

        assert_equal("The tools/call request is not found", error.message)
        assert_equal(:not_found, error.error_type)
        assert_equal({ method: "tools/call", params: { name: "test_tool", arguments: input } }, error.request)
      end

      def test_raises_unprocessable_entity_error
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
          .to_return(status: 422)

        error = assert_raises(RequestHandlerError) do
          client.call_tool(tool: tool, input: input)
        end

        assert_equal("The tools/call request is unprocessable", error.message)
        assert_equal(:unprocessable_entity, error.error_type)
        assert_equal({ method: "tools/call", params: { name: "test_tool", arguments: input } }, error.request)
      end

      def test_raises_internal_error
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
          .to_return(status: 500)

        error = assert_raises(RequestHandlerError) do
          client.call_tool(tool: tool, input: input)
        end

        assert_equal("Internal error handling tools/call request", error.message)
        assert_equal(:internal_error, error.error_type)
        assert_equal({ method: "tools/call", params: { name: "test_tool", arguments: input } }, error.request)
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
