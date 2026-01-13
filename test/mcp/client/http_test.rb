# frozen_string_literal: true

require "test_helper"
require "event_stream_parser"
require "faraday"
require "webmock/minitest"
require "mcp/client/http"
require "mcp/client"

module MCP
  class Client
    class HTTPTest < Minitest::Test
      def test_raises_load_error_when_faraday_not_available
        transport = HTTP.new(url: url)

        HTTP.any_instance.stubs(:require).with("faraday").raises(LoadError, "cannot load such file -- faraday")

        error = assert_raises(LoadError) do
          transport.post(body: {})
        end

        assert_includes(error.message, "The 'faraday' gem is required to use the MCP client HTTP transport")
        assert_includes(error.message, "Add it to your Gemfile: gem 'faraday', '>= 2.0'")
      end

      def test_post_with_default_headers
        body = { jsonrpc: "2.0", id: "test_id", method: "tools/list" }

        stub_request(:post, url)
          .with(
            headers: {
              "Content-Type" => "application/json",
              "Accept" => "application/json, text/event-stream",
            },
            body: body.to_json,
          )
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: { tools: [] } }.to_json,
          )

        response = transport.post(body: body)

        assert_instance_of(HTTP::Response, response)
        assert_equal({ "result" => { "tools" => [] } }, response.body)
      end

      def test_post_with_custom_transport_headers
        custom_transport = HTTP.new(url: url, headers: { "Authorization" => "Bearer token" })
        body = { jsonrpc: "2.0", id: "test_id", method: "tools/list" }

        stub_request(:post, url)
          .with(
            headers: {
              "Authorization" => "Bearer token",
              "Content-Type" => "application/json",
              "Accept" => "application/json, text/event-stream",
            },
          )
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: { tools: [] } }.to_json,
          )

        custom_transport.post(body: body)
      end

      def test_post_with_request_specific_headers
        body = { jsonrpc: "2.0", id: "test_id", method: "tools/list" }

        stub_request(:post, url)
          .with(
            headers: {
              "MCP-Session-Id" => "session-123",
              "MCP-Protocol-Version" => "2024-11-05",
            },
          )
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: { tools: [] } }.to_json,
          )

        transport.post(
          body: body,
          headers: {
            "MCP-Session-Id" => "session-123",
            "MCP-Protocol-Version" => "2024-11-05",
          },
        )
      end

      def test_post_returns_response_with_headers
        body = { jsonrpc: "2.0", id: "test_id", method: "initialize" }

        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
              "MCP-Session-Id" => "session-abc",
            },
            body: { result: {} }.to_json,
          )

        response = transport.post(body: body)

        # Faraday normalizes header keys to lowercase
        assert_equal("session-abc", response.headers["mcp-session-id"])
      end

      def test_post_raises_bad_request_error
        stub_request(:post, url).to_return(status: 400)

        error = assert_raises(RequestHandlerError) do
          transport.post(body: {})
        end

        assert_includes(error.message, "request is invalid")
        assert_equal(:bad_request, error.error_type)
      end

      def test_post_raises_unauthorized_error
        stub_request(:post, url).to_return(status: 401)

        error = assert_raises(RequestHandlerError) do
          transport.post(body: {})
        end

        assert_includes(error.message, "unauthorized")
        assert_equal(:unauthorized, error.error_type)
      end

      def test_post_raises_forbidden_error
        stub_request(:post, url).to_return(status: 403)

        error = assert_raises(RequestHandlerError) do
          transport.post(body: {})
        end

        assert_includes(error.message, "forbidden")
        assert_equal(:forbidden, error.error_type)
      end

      def test_post_raises_session_expired_error_on_404
        stub_request(:post, url).to_return(status: 404)

        error = assert_raises(SessionExpiredError) do
          transport.post(body: {})
        end

        assert_includes(error.message, "Session expired")
      end

      def test_send_request_raises_request_handler_error_on_404_for_backward_compatibility
        stub_request(:post, url).to_return(status: 404)

        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: { method: "tools/list" })
        end

        assert_includes(error.message, "not found")
        assert_equal(:not_found, error.error_type)
      end

      def test_post_raises_unprocessable_entity_error
        stub_request(:post, url).to_return(status: 422)

        error = assert_raises(RequestHandlerError) do
          transport.post(body: {})
        end

        assert_includes(error.message, "unprocessable")
        assert_equal(:unprocessable_entity, error.error_type)
      end

      def test_post_raises_internal_error_on_500
        stub_request(:post, url).to_return(status: 500)

        error = assert_raises(RequestHandlerError) do
          transport.post(body: {})
        end

        assert_includes(error.message, "Internal error")
        assert_equal(:internal_error, error.error_type)
      end

      def test_post_raises_error_for_unsupported_content_type
        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "text/html" },
            body: "<html></html>",
          )

        error = assert_raises(RequestHandlerError) do
          transport.post(body: {})
        end

        assert_includes(error.message, "Unsupported Content-Type")
        assert_equal(:unsupported_media_type, error.error_type)
      end

      def test_post_parses_sse_response
        sse_body = <<~SSE
          : comment
          data: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}

          data: {"jsonrpc":"2.0","id":"test_id","result":{"tools":[{"name":"echo"}]}}

        SSE

        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "text/event-stream" },
            body: sse_body,
          )

        response = transport.post(body: {})

        assert_equal({ "tools" => [{ "name" => "echo" }] }, response.body["result"])
      end

      def test_post_parses_sse_error_response
        sse_body = <<~SSE
          data: {"jsonrpc":"2.0","id":"test_id","error":{"code":-32600,"message":"Invalid request"}}

        SSE

        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "text/event-stream" },
            body: sse_body,
          )

        response = transport.post(body: {})

        assert_equal(-32600, response.body.dig("error", "code"))
        assert_equal("Invalid request", response.body.dig("error", "message"))
      end

      def test_post_raises_error_for_sse_without_response
        sse_body = <<~SSE
          : just a comment
          data: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}

        SSE

        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "text/event-stream" },
            body: sse_body,
          )

        error = assert_raises(RequestHandlerError) do
          transport.post(body: {})
        end

        assert_includes(error.message, "No valid JSON-RPC response found in SSE stream")
        assert_equal(:parse_error, error.error_type)
      end

      def test_delete_sends_request_with_headers
        stub_request(:delete, url)
          .with(
            headers: {
              "MCP-Session-Id" => "session-123",
              "MCP-Protocol-Version" => "2024-11-05",
            },
          )
          .to_return(status: 200)

        transport.delete(
          headers: {
            "MCP-Session-Id" => "session-123",
            "MCP-Protocol-Version" => "2024-11-05",
          },
        )
      end

      def test_delete_handles_errors_gracefully
        stub_request(:delete, url).to_return(status: 500)

        # Should not raise, just returns nil
        result = transport.delete(headers: {})
        assert_nil(result)
      end

      private

      def stub_request(method, url)
        WebMock.stub_request(method, url)
      end

      def url
        "http://example.com"
      end

      def transport
        @transport ||= HTTP.new(url: url)
      end
    end
  end
end
