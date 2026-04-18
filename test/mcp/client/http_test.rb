# frozen_string_literal: true

require "test_helper"
require "event_stream_parser"
require "faraday"
require "webmock/minitest"
require "mcp/client/http"
require "mcp/client/tool"
require "mcp/client"

module MCP
  class Client
    class HTTPTest < Minitest::Test
      def test_raises_load_error_when_faraday_not_available
        client = HTTP.new(url: url)

        # simulate Faraday not being available
        HTTP.any_instance.stubs(:require).with("faraday").raises(LoadError, "cannot load such file -- faraday")

        error = assert_raises(LoadError) do
          # This should immediately try to instantiate the client and fail
          client.send_request(request: {})
        end

        assert_includes(error.message, "The 'faraday' gem is required to use the MCP client HTTP transport")
        assert_includes(error.message, "Add it to your Gemfile: gem 'faraday', '>= 2.0'")
      end

      def test_raises_load_error_when_event_stream_parser_not_available
        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "text/event-stream" },
            body: "data: {}\n\n",
          )

        HTTP.any_instance.stubs(:require).with("faraday").returns(true)
        HTTP.any_instance.stubs(:require).with("event_stream_parser")
          .raises(LoadError, "cannot load such file -- event_stream_parser")

        error = assert_raises(LoadError) do
          client.send_request(request: { method: "tools/list" })
        end

        assert_includes(error.message, "The 'event_stream_parser' gem is required to parse SSE responses")
        assert_includes(error.message, "Add it to your Gemfile: gem 'event_stream_parser', '>= 1.0'")
      end

      def test_headers_are_added_to_the_request
        headers = { "Authorization" => "Bearer token" }
        client = HTTP.new(url: url, headers: headers)

        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url)
          .with(
            headers: {
              "Authorization" => "Bearer token",
              "Content-Type" => "application/json",
              "Accept" => "application/json, text/event-stream",
            },
            body: request.to_json,
          )
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: { tools: [] } }.to_json,
          )

        # The test passes if the request is made with the correct headers
        # If headers are wrong, the stub_request won't match and will raise
        client.send_request(request: request)
      end

      def test_accept_header_is_included_in_requests
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url)
          .with(
            headers: {
              "Accept" => "application/json, text/event-stream",
            },
          )
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: { tools: [] } }.to_json,
          )

        client.send_request(request: request)
      end

      def test_custom_accept_header_overrides_default
        custom_accept = "application/json"
        custom_client = HTTP.new(url: url, headers: { "Accept" => custom_accept })

        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url)
          .with(
            headers: {
              "Accept" => custom_accept,
            },
          )
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: { tools: [] } }.to_json,
          )

        custom_client.send_request(request: request)
      end

      def test_send_request_returns_faraday_response
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url)
          .with(body: request.to_json)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: { tools: [] } }.to_json,
          )

        response = client.send_request(request: request)
        assert_instance_of(Hash, response)
        assert_equal({ "result" => { "tools" => [] } }, response)
      end

      def test_send_request_raises_bad_request_error
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url)
          .with(body: request.to_json)
          .to_return(status: 400)

        error = assert_raises(RequestHandlerError) do
          client.send_request(request: request)
        end

        assert_equal("The tools/list request is invalid", error.message)
        assert_equal(:bad_request, error.error_type)
        assert_equal({ method: "tools/list", params: nil }, error.request)
      end

      def test_send_request_raises_unauthorized_error
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url)
          .with(body: request.to_json)
          .to_return(status: 401)

        error = assert_raises(RequestHandlerError) do
          client.send_request(request: request)
        end

        assert_equal("You are unauthorized to make tools/list requests", error.message)
        assert_equal(:unauthorized, error.error_type)
        assert_equal({ method: "tools/list", params: nil }, error.request)
      end

      def test_send_request_raises_forbidden_error
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url)
          .with(body: request.to_json)
          .to_return(status: 403)

        error = assert_raises(RequestHandlerError) do
          client.send_request(request: request)
        end

        assert_equal("You are forbidden to make tools/list requests", error.message)
        assert_equal(:forbidden, error.error_type)
        assert_equal({ method: "tools/list", params: nil }, error.request)
      end

      def test_send_request_raises_not_found_error
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url)
          .with(body: request.to_json)
          .to_return(status: 404)

        error = assert_raises(RequestHandlerError) do
          client.send_request(request: request)
        end

        assert_equal("The tools/list request is not found", error.message)
        assert_equal(:not_found, error.error_type)
        assert_equal({ method: "tools/list", params: nil }, error.request)
      end

      def test_send_request_raises_unprocessable_entity_error
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url)
          .with(body: request.to_json)
          .to_return(status: 422)

        error = assert_raises(RequestHandlerError) do
          client.send_request(request: request)
        end

        assert_equal("The tools/list request is unprocessable", error.message)
        assert_equal(:unprocessable_entity, error.error_type)
        assert_equal({ method: "tools/list", params: nil }, error.request)
      end

      def test_send_request_raises_internal_error
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url)
          .with(body: request.to_json)
          .to_return(status: 500)

        error = assert_raises(RequestHandlerError) do
          client.send_request(request: request)
        end

        assert_equal("Internal error handling tools/list request", error.message)
        assert_equal(:internal_error, error.error_type)
        assert_equal({ method: "tools/list", params: nil }, error.request)
      end

      def test_block_customizes_faraday_connection
        custom_client = HTTP.new(url: url) do |faraday|
          faraday.headers["X-Custom"] = "test-value"
        end

        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url).with(
          headers: {
            "X-Custom" => "test-value",
            "Accept" => "application/json, text/event-stream",
          },
        ).to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: { tools: [] } }.to_json,
        )

        custom_client.send_request(request: request)
      end

      def test_send_request_raises_error_for_unsupported_content_type
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url)
          .with(body: request.to_json)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "text/html" },
            body: "<html></html>",
          )

        error = assert_raises(RequestHandlerError) do
          client.send_request(request: request)
        end

        assert_equal(
          'Unsupported Content-Type: "text/html". Expected application/json or text/event-stream.',
          error.message,
        )
        assert_equal(:unsupported_media_type, error.error_type)
        assert_equal({ method: "tools/list", params: nil }, error.request)
      end

      def test_send_request_parses_sse_response
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        sse_body = <<~SSE
          : comment
          data: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}

          data: {"jsonrpc":"2.0","id":"test_id","result":{"tools":[{"name":"echo"}]}}

        SSE

        stub_request(:post, url)
          .with(body: request.to_json)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "text/event-stream" },
            body: sse_body,
          )

        response = client.send_request(request: request)

        assert_equal({ "tools" => [{ "name" => "echo" }] }, response["result"])
      end

      def test_send_request_parses_sse_error_response
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        sse_body = <<~SSE
          data: {"jsonrpc":"2.0","id":"test_id","error":{"code":-32600,"message":"Invalid request"}}

        SSE

        stub_request(:post, url)
          .with(body: request.to_json)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "text/event-stream" },
            body: sse_body,
          )

        response = client.send_request(request: request)

        assert_equal(-32600, response.dig("error", "code"))
        assert_equal("Invalid request", response.dig("error", "message"))
      end

      def test_send_request_returns_nil_for_202_accepted_response
        request = {
          jsonrpc: "2.0",
          method: "notifications/initialized",
        }

        stub_request(:post, url)
          .with(body: request.to_json)
          .to_return(status: 202, body: "")

        response = client.send_request(request: request)

        assert_nil(response)
      end

      def test_send_request_raises_error_for_sse_without_response
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        sse_body = <<~SSE
          : just a comment
          data: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}

        SSE

        stub_request(:post, url)
          .with(body: request.to_json)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "text/event-stream" },
            body: sse_body,
          )

        error = assert_raises(RequestHandlerError) do
          client.send_request(request: request)
        end

        assert_includes(error.message, "No valid JSON-RPC response found in SSE stream")
        assert_equal(:parse_error, error.error_type)
      end

      private

      def stub_request(method, url)
        WebMock.stub_request(method, url)
      end

      def url
        "http://example.com"
      end

      def client
        @client ||= HTTP.new(url: url)
      end
    end
  end
end
