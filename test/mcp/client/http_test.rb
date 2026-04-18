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
          transport.send_request(request: { method: "tools/list" })
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
          transport.send_request(request: { method: "tools/list" })
        end

        assert_includes(error.message, "The 'event_stream_parser' gem is required to parse SSE responses")
      end

      def test_send_request_with_default_headers
        request = { jsonrpc: "2.0", id: "test_id", method: "tools/list" }

        stub_request(:post, url)
          .with(
            headers: {
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

        response = transport.send_request(request: request)

        assert_equal({ "result" => { "tools" => [] } }, response)
      end

      def test_send_request_with_custom_transport_headers
        custom_transport = HTTP.new(url: url, headers: { "Authorization" => "Bearer token" })
        request = { jsonrpc: "2.0", id: "test_id", method: "tools/list" }

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

        custom_transport.send_request(request: request)
      end

      def test_send_request_captures_session_id_and_protocol_version_on_initialize
        request = { jsonrpc: "2.0", id: "test_id", method: "initialize" }

        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
              "Mcp-Session-Id" => "session-abc",
            },
            body: { result: { protocolVersion: "2024-11-05" } }.to_json,
          )

        transport.send_request(request: request)

        assert_equal("session-abc", transport.session_id)
        assert_equal("2024-11-05", transport.protocol_version)
      end

      def test_send_request_includes_session_headers_after_initialize
        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
              "Mcp-Session-Id" => "session-abc",
            },
            body: { result: { protocolVersion: "2024-11-05" } }.to_json,
          )

        transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "initialize" })

        stub_request(:post, url)
          .with(
            headers: {
              "Mcp-Session-Id" => "session-abc",
            },
          )
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: { tools: [] } }.to_json,
          )

        transport.send_request(request: { jsonrpc: "2.0", id: "2", method: "tools/list" })
      end

      def test_session_id_not_overwritten_by_subsequent_responses
        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
              "Mcp-Session-Id" => "original-session",
            },
            body: { result: { protocolVersion: "2024-11-05" } }.to_json,
          )

        transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "initialize" })

        assert_equal("original-session", transport.session_id)

        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
              "Mcp-Session-Id" => "different-session",
            },
            body: { result: { tools: [] } }.to_json,
          )

        transport.send_request(request: { jsonrpc: "2.0", id: "2", method: "tools/list" })

        assert_equal("original-session", transport.session_id)
      end

      def test_send_request_works_without_session_id_for_stateless_servers
        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: { protocolVersion: "2024-11-05" } }.to_json,
          )

        transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "initialize" })

        assert_nil(transport.session_id)
        assert_equal("2024-11-05", transport.protocol_version)
      end

      def test_send_request_raises_bad_request_error
        stub_request(:post, url).to_return(status: 400)

        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: { method: "tools/list" })
        end

        assert_includes(error.message, "request is invalid")
        assert_equal(:bad_request, error.error_type)
      end

      def test_send_request_raises_unauthorized_error
        stub_request(:post, url).to_return(status: 401)

        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: { method: "tools/list" })
        end

        assert_includes(error.message, "unauthorized")
        assert_equal(:unauthorized, error.error_type)
      end

      def test_send_request_raises_forbidden_error
        stub_request(:post, url).to_return(status: 403)

        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: { method: "tools/list" })
        end

        assert_includes(error.message, "forbidden")
        assert_equal(:forbidden, error.error_type)
      end

      def test_send_request_raises_session_expired_error_on_404
        stub_request(:post, url).to_return(status: 404)

        error = assert_raises(SessionExpiredError) do
          transport.send_request(request: { method: "tools/list" })
        end

        assert_includes(error.message, "not found")
        assert_equal(:not_found, error.error_type)
      end

      def test_session_expired_error_is_a_request_handler_error
        stub_request(:post, url).to_return(status: 404)

        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: { method: "tools/list" })
        end

        assert_equal(:not_found, error.error_type)
      end

      def test_send_request_clears_session_state_on_404
        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
              "Mcp-Session-Id" => "session-abc",
            },
            body: { result: { protocolVersion: "2024-11-05" } }.to_json,
          )

        transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "initialize" })

        assert_equal("session-abc", transport.session_id)

        stub_request(:post, url).to_return(status: 404)

        assert_raises(SessionExpiredError) do
          transport.send_request(request: { jsonrpc: "2.0", id: "2", method: "tools/list" })
        end

        assert_nil(transport.session_id)
        assert_nil(transport.protocol_version)
      end

      def test_send_request_raises_unprocessable_entity_error
        stub_request(:post, url).to_return(status: 422)

        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: { method: "tools/list" })
        end

        assert_includes(error.message, "unprocessable")
        assert_equal(:unprocessable_entity, error.error_type)
      end

      def test_send_request_raises_internal_error_on_500
        stub_request(:post, url).to_return(status: 500)

        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: { method: "tools/list" })
        end

        assert_includes(error.message, "Internal error")
        assert_equal(:internal_error, error.error_type)
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
        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "text/html" },
            body: "<html></html>",
          )

        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: { method: "tools/list" })
        end

        assert_includes(error.message, "Unsupported Content-Type")
        assert_equal(:unsupported_media_type, error.error_type)
      end

      def test_send_request_parses_sse_response
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

        response = transport.send_request(request: { method: "tools/list" })

        assert_equal({ "tools" => [{ "name" => "echo" }] }, response["result"])
      end

      def test_send_request_parses_sse_error_response
        sse_body = <<~SSE
          data: {"jsonrpc":"2.0","id":"test_id","error":{"code":-32600,"message":"Invalid request"}}

        SSE

        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "text/event-stream" },
            body: sse_body,
          )

        response = transport.send_request(request: { method: "tools/list" })

        assert_equal(-32600, response.dig("error", "code"))
        assert_equal("Invalid request", response.dig("error", "message"))
      end

      def test_send_request_raises_error_for_sse_without_response
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
          transport.send_request(request: { method: "tools/list" })
        end

        assert_includes(error.message, "No valid JSON-RPC response found in SSE stream")
        assert_equal(:parse_error, error.error_type)
      end

      def test_send_request_returns_accepted_for_202_with_no_content_type
        stub_request(:post, url)
          .to_return(status: 202, body: "")

        response = transport.send_request(request: { method: "notifications/initialized" })

        assert_equal({ "accepted" => true }, response)
      end

      def test_close_sends_delete_with_session_headers
        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
              "Mcp-Session-Id" => "session-to-close",
            },
            body: { result: { protocolVersion: "2024-11-05" } }.to_json,
          )

        transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "initialize" })

        delete_stub = stub_request(:delete, url)
          .with(
            headers: {
              "Mcp-Session-Id" => "session-to-close",
            },
          )
          .to_return(status: 200)

        transport.close

        assert_requested(delete_stub)
        assert_nil(transport.session_id)
        assert_nil(transport.protocol_version)
      end

      def test_close_handles_errors_gracefully
        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
              "Mcp-Session-Id" => "session-to-close",
            },
            body: { result: { protocolVersion: "2024-11-05" } }.to_json,
          )

        transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "initialize" })

        stub_request(:delete, url).to_return(status: 405)

        transport.close

        assert_nil(transport.session_id)
        assert_nil(transport.protocol_version)
      end

      def test_close_does_nothing_without_session
        # No DELETE should be sent when there's no session
        transport.close

        assert_not_requested(:delete, url)
        assert_nil(transport.session_id)
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
