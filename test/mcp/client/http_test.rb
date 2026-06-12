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
        HTTP.const_get(:SSEStream).any_instance.stubs(:require).with("event_stream_parser")
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

      def test_mcp_method_and_name_headers_for_tools_call
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/call",
          params: { name: "get_weather", arguments: { city: "Tokyo" } },
        }

        stub_request(:post, url).with(
          headers: { "Mcp-Method" => "tools/call", "Mcp-Name" => "get_weather" },
        ).to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: {} }.to_json,
        )

        client.send_request(request: request)
      end

      def test_mcp_name_header_falls_back_to_uri_for_resources_read
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "resources/read",
          params: { uri: "file:///README.md" },
        }

        stub_request(:post, url).with(
          headers: { "Mcp-Method" => "resources/read", "Mcp-Name" => "file:///README.md" },
        ).to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: {} }.to_json,
        )

        client.send_request(request: request)
      end

      def test_mcp_method_and_name_headers_for_prompts_get
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "prompts/get",
          params: { name: "greeting" },
        }

        stub_request(:post, url).with(
          headers: { "Mcp-Method" => "prompts/get", "Mcp-Name" => "greeting" },
        ).to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: {} }.to_json,
        )

        client.send_request(request: request)
      end

      def test_mcp_method_header_without_name_when_params_lack_name_and_uri
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url).with(
          headers: { "Mcp-Method" => "tools/list" },
        ) do |req|
          !req.headers.key?("Mcp-Name")
        end.to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: { tools: [] } }.to_json,
        )

        client.send_request(request: request)
      end

      def test_mcp_name_header_is_base64_encoded_when_unsafe
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/call",
          params: { name: "café" },
        }

        stub_request(:post, url).with(
          headers: { "Mcp-Method" => "tools/call", "Mcp-Name" => "=?base64?Y2Fmw6k=?=" },
        ).to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: {} }.to_json,
        )

        client.send_request(request: request)
      end

      def test_mcp_method_header_for_notification_without_id
        request = {
          jsonrpc: "2.0",
          method: "notifications/initialized",
        }

        stub_request(:post, url).with(
          headers: { "Mcp-Method" => "notifications/initialized" },
        ) do |req|
          !req.headers.key?("Mcp-Name")
        end.to_return(
          status: 202,
          headers: { "Content-Type" => "application/json" },
          body: "",
        )

        client.send_request(request: request)
      end

      def test_mcp_method_header_for_initialize_without_params
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "initialize",
        }

        stub_request(:post, url).with(
          headers: { "Mcp-Method" => "initialize" },
        ) do |req|
          !req.headers.key?("Mcp-Name")
        end.to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: {} }.to_json,
        )

        client.send_request(request: request)
      end

      def test_mcp_name_header_with_string_keyed_params
        request = {
          "jsonrpc" => "2.0",
          "id" => "test_id",
          "method" => "tools/call",
          "params" => { "name" => "get_weather" },
        }

        stub_request(:post, url).with(
          headers: { "Mcp-Method" => "tools/call", "Mcp-Name" => "get_weather" },
        ).to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: {} }.to_json,
        )

        client.send_request(request: request)
      end

      def test_mcp_name_header_is_base64_encoded_when_value_has_surrounding_whitespace
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/call",
          params: { name: " padded " },
        }

        stub_request(:post, url).with(
          headers: { "Mcp-Method" => "tools/call", "Mcp-Name" => "=?base64?IHBhZGRlZCA=?=" },
        ).to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: {} }.to_json,
        )

        client.send_request(request: request)
      end

      def test_mcp_name_header_is_base64_encoded_when_value_has_crlf
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/call",
          params: { name: "evil\r\nX-Injected: 1" },
        }

        stub_request(:post, url).with(
          headers: { "Mcp-Method" => "tools/call", "Mcp-Name" => "=?base64?ZXZpbA0KWC1JbmplY3RlZDogMQ==?=" },
        ) do |req|
          !req.headers.key?("X-Injected")
        end.to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: {} }.to_json,
        )

        client.send_request(request: request)
      end

      def test_mcp_name_header_re_encodes_value_matching_base64_sentinel
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/call",
          params: { name: "=?base64?literal?=" },
        }

        stub_request(:post, url).with(
          headers: { "Mcp-Method" => "tools/call", "Mcp-Name" => "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=" },
        ).to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: {} }.to_json,
        )

        client.send_request(request: request)
      end

      def test_mcp_method_header_without_name_for_non_hash_params
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "custom/method",
          params: ["positional"],
        }

        stub_request(:post, url).with(headers: { "Mcp-Method" => "custom/method" }) do |req|
          !req.headers.key?("Mcp-Name")
        end.to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { result: {} }.to_json,
        )

        client.send_request(request: request)
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

      def test_send_request_raises_not_found_error_on_404_without_session
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

        refute_kind_of(SessionExpiredError, error)
        assert_equal("The tools/list request is not found", error.message)
        assert_equal(:not_found, error.error_type)
        assert_equal({ method: "tools/list", params: nil }, error.request)
      end

      def test_send_request_raises_session_expired_error_on_404_with_session
        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
              "Mcp-Session-Id" => "session-abc",
            },
            body: { result: { protocolVersion: "2025-11-25" } }.to_json,
          )

        client.send_request(request: { jsonrpc: "2.0", id: "1", method: "initialize" })

        stub_request(:post, url).to_return(status: 404)

        error = assert_raises(SessionExpiredError) do
          client.send_request(request: { jsonrpc: "2.0", id: "2", method: "tools/list" })
        end

        assert_equal(:not_found, error.error_type)
      end

      def test_session_expired_error_is_a_request_handler_error
        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
              "Mcp-Session-Id" => "session-abc",
            },
            body: { result: { protocolVersion: "2025-11-25" } }.to_json,
          )

        client.send_request(request: { jsonrpc: "2.0", id: "1", method: "initialize" })

        stub_request(:post, url).to_return(status: 404)

        error = assert_raises(RequestHandlerError) do
          client.send_request(request: { jsonrpc: "2.0", id: "2", method: "tools/list" })
        end

        assert_kind_of(SessionExpiredError, error)
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
        assert_not_requested(:get, url)
      end

      def test_send_request_reconnects_with_last_event_id_after_primed_graceful_close
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/call",
          params: { name: "test_reconnection", arguments: {} },
        }

        stub_request(:post, url).with(
          body: request.to_json,
        ).to_return(
          status: 200,
          headers: { "Content-Type" => "text/event-stream" },
          body: "id: event-1\nretry: 100\ndata:\n\n",
        )

        get_body = "id: event-2\nretry: 100\ndata:\n\n" \
          "event: message\nid: event-3\n" \
          'data: {"jsonrpc":"2.0","id":"test_id","result":{"content":[]}}' \
          "\n\n"
        get_stub = stub_request(:get, url).with(
          headers: { "Accept" => "text/event-stream", "Last-Event-ID" => "event-1" },
        ).to_return(
          status: 200,
          headers: { "Content-Type" => "text/event-stream" },
          body: get_body,
        )

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = client.send_request(request: request)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

        assert_equal({ "content" => [] }, response["result"])
        assert_requested(get_stub)

        # The server-specified `retry:` interval must elapse before the reconnection GET.
        assert_operator(elapsed, :>=, 0.1)
      end

      def test_send_request_uses_default_reconnection_delay_when_retry_field_absent
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/call",
          params: { name: "test_reconnection", arguments: {} },
        }

        stub_request(:post, url).with(
          body: request.to_json,
        ).to_return(
          status: 200,
          headers: { "Content-Type" => "text/event-stream" },
          body: "id: event-1\ndata:\n\n",
        )

        get_body = 'data: {"jsonrpc":"2.0","id":"test_id","result":{"content":[]}}' \
          "\n\n"
        stub_request(:get, url).with(
          headers: { "Last-Event-ID" => "event-1" },
        ).to_return(
          status: 200,
          headers: { "Content-Type" => "text/event-stream" },
          body: get_body,
        )

        client.expects(:sleep).with(HTTP::DEFAULT_RECONNECTION_DELAY_MS / 1000.0)

        response = client.send_request(request: request)

        assert_equal({ "content" => [] }, response["result"])
      end

      def test_send_request_raises_after_reconnection_attempts_are_exhausted
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/call",
          params: { name: "test_reconnection", arguments: {} },
        }

        stub_request(:post, url).with(
          body: request.to_json,
        ).to_return(
          status: 200,
          headers: { "Content-Type" => "text/event-stream" },
          body: "id: event-1\nretry: 10\ndata:\n\n",
        )

        first_get = stub_request(:get, url).with(
          headers: { "Last-Event-ID" => "event-1" },
        ).to_return(
          status: 200,
          headers: { "Content-Type" => "text/event-stream" },
          body: "id: event-2\nretry: 10\ndata:\n\n",
        )
        second_get = stub_request(:get, url).with(
          headers: { "Last-Event-ID" => "event-2" },
        ).to_return(
          status: 200,
          headers: { "Content-Type" => "text/event-stream" },
          body: "id: event-3\nretry: 10\ndata:\n\n",
        )

        error = assert_raises(RequestHandlerError) do
          client.send_request(request: request)
        end

        assert_includes(error.message, "after 2 reconnection attempts")
        assert_equal(:internal_error, error.error_type)
        assert_requested(first_get)
        assert_requested(second_get)
      end

      def test_send_request_parses_json_response_when_adapter_does_not_stream
        # The Faraday test adapter ignores `on_data`, like adapters without
        # streaming support; the body must be read from `response.body`.
        stubs = Faraday::Adapter::Test::Stubs.new do |stub|
          stub.post("/") do
            [200, { "Content-Type" => "application/json" }, { result: { tools: [] } }.to_json]
          end
        end
        client = HTTP.new(url: url) { |faraday| faraday.adapter(:test, stubs) }

        response = client.send_request(request: { jsonrpc: "2.0", id: "test_id", method: "tools/list" })

        assert_equal({ "result" => { "tools" => [] } }, response)
      end

      def test_send_request_parses_sse_response_when_adapter_does_not_stream
        sse_body = "event: message\n" \
          'data: {"jsonrpc":"2.0","id":"test_id","result":{"tools":[]}}' \
          "\n\n"
        stubs = Faraday::Adapter::Test::Stubs.new do |stub|
          stub.post("/") do
            [200, { "Content-Type" => "text/event-stream" }, sse_body]
          end
        end
        client = HTTP.new(url: url) { |faraday| faraday.adapter(:test, stubs) }

        response = client.send_request(request: { jsonrpc: "2.0", id: "test_id", method: "tools/list" })

        assert_equal({ "tools" => [] }, response["result"])
      end

      def test_sse_stream_parses_buffered_chunks_when_env_is_unavailable
        # Faraday < 2.1 invokes `on_data` without `env`; the content type
        # cannot be detected, so SSE chunks accumulate in the buffer and are
        # parsed by the `ingest_pending!` fallback.
        stream = HTTP.const_get(:SSEStream).new(abortable: true)
        chunk = "data: {\"jsonrpc\":\"2.0\",\"id\":\"test_id\",\"result\":{}}\n\n"

        stream.on_data.call(chunk, chunk.bytesize)

        assert_nil(stream.response)
        assert_equal(chunk, stream.buffer)

        stream.ingest_pending!(nil)

        assert_equal({ "jsonrpc" => "2.0", "id" => "test_id", "result" => {} }, stream.response)
        assert_empty(stream.buffer)
      end

      def test_send_request_dispatches_server_request_to_registered_handler
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/call",
          params: { name: "test_client_elicitation_defaults", arguments: {} },
        }

        elicitation_request = {
          jsonrpc: "2.0",
          id: 0,
          method: "elicitation/create",
          params: {
            message: "Please accept with defaults",
            requestedSchema: {
              type: "object",
              properties: { name: { type: "string", default: "John Doe" } },
              required: [],
            },
          },
        }
        tool_result = { jsonrpc: "2.0", id: "test_id", result: { content: [] } }
        sse_body = "event: message\ndata: #{elicitation_request.to_json}\n\n" \
          "event: message\ndata: #{tool_result.to_json}\n\n"

        stub_request(:post, url).with(
          body: request.to_json,
        ).to_return(
          status: 200,
          headers: { "Content-Type" => "text/event-stream" },
          body: sse_body,
        )

        expected_response = {
          jsonrpc: "2.0",
          id: 0,
          result: { action: "accept", content: { name: "John Doe" } },
        }
        response_stub = stub_request(:post, url).with(
          body: expected_response.to_json,
        ).to_return(
          status: 202, body: "",
        )

        received_params = nil
        client.on_server_request("elicitation/create") do |params|
          received_params = params
          {
            action: "accept",
            content: { name: params.dig("requestedSchema", "properties", "name", "default") },
          }
        end

        response = client.send_request(request: request)

        assert_equal({ "content" => [] }, response["result"])
        assert_requested(response_stub)
        assert_equal("Please accept with defaults", received_params["message"])
      end

      def test_send_request_answers_unregistered_server_request_with_method_not_found
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/call",
          params: { name: "some_tool", arguments: {} },
        }

        server_request = {
          jsonrpc: "2.0",
          id: 5,
          method: "sampling/createMessage",
          params: {},
        }
        tool_result = { jsonrpc: "2.0", id: "test_id", result: { content: [] } }
        sse_body = "event: message\ndata: #{server_request.to_json}\n\n" \
          "event: message\ndata: #{tool_result.to_json}\n\n"

        stub_request(:post, url).with(
          body: request.to_json,
        ).to_return(
          status: 200,
          headers: { "Content-Type" => "text/event-stream" },
          body: sse_body,
        )

        expected_error_response = {
          jsonrpc: "2.0",
          id: 5,
          error: { code: -32601, message: "Method not found: sampling/createMessage" },
        }
        error_stub = stub_request(:post, url).with(
          body: expected_error_response.to_json,
        ).to_return(
          status: 202, body: "",
        )

        response = client.send_request(request: request)

        assert_equal({ "content" => [] }, response["result"])
        assert_requested(error_stub)
      end

      def test_send_request_answers_raising_handler_with_internal_error
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/call",
          params: { name: "some_tool", arguments: {} },
        }

        server_request = {
          jsonrpc: "2.0",
          id: 9,
          method: "elicitation/create",
          params: {},
        }
        tool_result = { jsonrpc: "2.0", id: "test_id", result: { content: [] } }
        sse_body = "event: message\ndata: #{server_request.to_json}\n\n" \
          "event: message\ndata: #{tool_result.to_json}\n\n"

        stub_request(:post, url).with(
          body: request.to_json,
        ).to_return(
          status: 200,
          headers: { "Content-Type" => "text/event-stream" },
          body: sse_body,
        )

        expected_error_response = {
          jsonrpc: "2.0",
          id: 9,
          error: { code: -32603, message: "Internal error handling elicitation/create request: boom" },
        }
        error_stub = stub_request(:post, url).with(
          body: expected_error_response.to_json,
        ).to_return(
          status: 202, body: "",
        )

        client.on_server_request("elicitation/create") { raise "boom" }

        response = client.send_request(request: request)

        assert_equal({ "content" => [] }, response["result"])
        assert_requested(error_stub)
      end

      def test_send_request_answers_server_request_error_with_its_code
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/call",
          params: { name: "ask_llm", arguments: {} },
        }

        server_request = {
          jsonrpc: "2.0",
          id: 11,
          method: "sampling/createMessage",
          params: {},
        }
        tool_result = { jsonrpc: "2.0", id: "test_id", result: { content: [] } }
        sse_body = "event: message\ndata: #{server_request.to_json}\n\n" \
          "event: message\ndata: #{tool_result.to_json}\n\n"

        stub_request(:post, url).with(
          body: request.to_json,
        ).to_return(
          status: 200,
          headers: { "Content-Type" => "text/event-stream" },
          body: sse_body,
        )

        expected_error_response = {
          jsonrpc: "2.0",
          id: 11,
          error: { code: -1, message: "User rejected sampling request" },
        }
        error_stub = stub_request(:post, url).with(
          body: expected_error_response.to_json,
        ).to_return(
          status: 202, body: "",
        )

        client.on_server_request("sampling/createMessage") do
          raise MCP::Client::ServerRequestError.new("User rejected sampling request", code: -1)
        end

        response = client.send_request(request: request)

        assert_equal({ "content" => [] }, response["result"])
        assert_requested(error_stub)
      end

      def test_on_server_request_requires_a_block
        assert_raises(ArgumentError) do
          client.on_server_request("elicitation/create")
        end
      end

      def test_registering_a_handler_after_connect_listens_on_standalone_get_stream
        stub_initialize
        stub_notification
        stub_request(:delete, url).to_return(status: 200)

        elicitation_request = {
          jsonrpc: "2.0",
          id: 7,
          method: "elicitation/create",
          params: {
            message: "Please accept with defaults",
            requestedSchema: {
              type: "object",
              properties: { name: { type: "string", default: "John Doe" } },
              required: [],
            },
          },
        }
        stub_request(:get, url)
          .with(
            headers: { "Accept" => "text/event-stream", "Mcp-Session-Id" => "session-abc" },
          ).to_return(
            status: 200,
            headers: { "Content-Type" => "text/event-stream" },
            body: "event: message\ndata: #{elicitation_request.to_json}\n\n",
          )

        expected_response = {
          jsonrpc: "2.0",
          id: 7,
          result: { action: "accept", content: { name: "John Doe" } },
        }
        response_stub = stub_request(:post, url).with(
          body: expected_response.to_json,
        ).to_return(
          status: 202, body: "",
        )

        client.connect
        client.on_server_request("elicitation/create") do |params|
          {
            action: "accept",
            content: { name: params.dig("requestedSchema", "properties", "name", "default") },
          }
        end

        wait_until { requested?(response_stub) }

        assert_requested(response_stub)
      ensure
        client.close
      end

      def test_connect_listens_on_standalone_get_stream_when_a_handler_is_registered
        stub_initialize
        stub_notification
        stub_request(:delete, url).to_return(status: 200)

        get_stub = stub_request(:get, url).with(
          headers: { "Accept" => "text/event-stream" },
        ).to_return(
          status: 200,
          headers: { "Content-Type" => "text/event-stream" },
          body: "",
        )

        client.on_server_request("elicitation/create") { { action: "decline" } }

        assert_not_requested(:get, url)

        client.connect

        wait_until { requested?(get_stub) }

        assert_requested(get_stub)
      ensure
        client.close
      end

      def test_listener_stops_after_consecutive_connection_failures
        stub_initialize
        stub_notification
        stub_request(:delete, url).to_return(status: 200)
        stub_request(:get, url).to_return(status: 500)

        client.stubs(:sleep)
        client.connect
        client.on_server_request("elicitation/create") { { action: "decline" } }
        listener = client.instance_variable_get(:@listener_thread)

        wait_until { !listener.alive? }

        assert_requested(:get, url, times: HTTP::MAX_RECONNECTION_ATTEMPTS)
      ensure
        client.close
      end

      def test_listener_failure_count_resets_after_a_successful_stream
        stub_initialize
        stub_notification
        stub_request(:delete, url).to_return(status: 200)
        stub_request(:get, url).to_return(
          { status: 500 },
          { status: 200, headers: { "Content-Type" => "text/event-stream" }, body: "" },
          { status: 500 },
          { status: 500 },
        )

        client.stubs(:sleep)
        client.connect
        client.on_server_request("elicitation/create") { { action: "decline" } }
        listener = client.instance_variable_get(:@listener_thread)

        wait_until { !listener.alive? }

        # Without the reset, the second failure (the third request) would
        # already reach the cap and the fourth request would never be made.
        assert_requested(:get, url, times: 4)
      ensure
        client.close
      end

      def test_listener_stops_immediately_when_server_does_not_offer_a_get_stream
        stub_initialize
        stub_notification
        stub_request(:delete, url).to_return(status: 200)
        stub_request(:get, url).to_return(status: 405)

        client.stubs(:sleep)
        client.connect
        client.on_server_request("elicitation/create") { { action: "decline" } }
        listener = client.instance_variable_get(:@listener_thread)

        wait_until { !listener.alive? }

        assert_requested(:get, url, times: 1)
      ensure
        client.close
      end

      def test_captures_session_id_and_protocol_version_on_initialize
        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
              "Mcp-Session-Id" => "session-abc",
            },
            body: { result: { protocolVersion: "2025-11-25" } }.to_json,
          )

        client.send_request(request: { jsonrpc: "2.0", id: "1", method: "initialize" })

        assert_equal("session-abc", client.session_id)
        assert_equal("2025-11-25", client.protocol_version)
      end

      def test_includes_session_and_protocol_version_headers_after_initialize
        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
              "Mcp-Session-Id" => "session-abc",
            },
            body: { result: { protocolVersion: "2025-11-25" } }.to_json,
          )

        client.send_request(request: { jsonrpc: "2.0", id: "1", method: "initialize" })

        stub_request(:post, url)
          .with(
            headers: {
              "Mcp-Session-Id" => "session-abc",
              "MCP-Protocol-Version" => "2025-11-25",
            },
          )
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: { tools: [] } }.to_json,
          )

        client.send_request(request: { jsonrpc: "2.0", id: "2", method: "tools/list" })
      end

      def test_does_not_send_protocol_version_header_before_initialize
        stub_request(:post, url)
          .with { |req| !req.headers.keys.map(&:downcase).include?("mcp-protocol-version") }
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: { protocolVersion: "2025-11-25" } }.to_json,
          )

        client.send_request(request: { jsonrpc: "2.0", id: "1", method: "initialize" })
      end

      def test_ignores_empty_session_id_header
        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
              "Mcp-Session-Id" => "",
            },
            body: { result: { protocolVersion: "2025-11-25" } }.to_json,
          )

        client.send_request(request: { jsonrpc: "2.0", id: "1", method: "initialize" })

        assert_nil(client.session_id)
      end

      def test_session_id_not_overwritten_by_subsequent_responses
        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
              "Mcp-Session-Id" => "original-session",
            },
            body: { result: { protocolVersion: "2025-11-25" } }.to_json,
          )

        client.send_request(request: { jsonrpc: "2.0", id: "1", method: "initialize" })

        assert_equal("original-session", client.session_id)

        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
              "Mcp-Session-Id" => "different-session",
            },
            body: { result: { tools: [] } }.to_json,
          )

        client.send_request(request: { jsonrpc: "2.0", id: "2", method: "tools/list" })

        assert_equal("original-session", client.session_id)
      end

      def test_stateless_server_without_session_id_header
        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: { protocolVersion: "2025-11-25" } }.to_json,
          )

        client.send_request(request: { jsonrpc: "2.0", id: "1", method: "initialize" })

        assert_nil(client.session_id)
        assert_equal("2025-11-25", client.protocol_version)
      end

      def test_clears_session_state_on_404
        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
              "Mcp-Session-Id" => "session-abc",
            },
            body: { result: { protocolVersion: "2025-11-25" } }.to_json,
          )

        client.send_request(request: { jsonrpc: "2.0", id: "1", method: "initialize" })

        assert_equal("session-abc", client.session_id)

        stub_request(:post, url).to_return(status: 404)

        assert_raises(SessionExpiredError) do
          client.send_request(request: { jsonrpc: "2.0", id: "2", method: "tools/list" })
        end

        assert_nil(client.session_id)
        assert_nil(client.protocol_version)
      end

      def test_close_sends_delete_with_session_headers
        initialize_session

        stub_request(:delete, url)
          .with(
            headers: {
              "Mcp-Session-Id" => "session-abc",
              "MCP-Protocol-Version" => "2025-11-25",
            },
          )
          .to_return(status: 200)

        client.close
      end

      def test_close_clears_session_state
        initialize_session
        stub_request(:delete, url).to_return(status: 200)

        client.close

        assert_nil(client.session_id)
        assert_nil(client.protocol_version)
      end

      def test_close_without_session_is_noop
        client.close

        assert_not_requested(:delete, url)
        assert_nil(client.session_id)
      end

      def test_close_clears_stateless_connection_state
        stub_request(:post, url)
          .with { |req| JSON.parse(req.body)["method"] == "initialize" }
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: { protocolVersion: "2025-11-25" } }.to_json,
          )
        stub_notification

        client.connect
        client.close

        assert_not_requested(:delete, url)
        refute_predicate(client, :connected?)
        assert_nil(client.protocol_version)
        assert_nil(client.server_info)
      end

      def test_close_tolerates_405_response
        initialize_session
        stub_request(:delete, url).to_return(status: 405)

        client.close

        assert_nil(client.session_id)
      end

      def test_close_tolerates_404_response
        initialize_session
        stub_request(:delete, url).to_return(status: 404)

        client.close

        assert_nil(client.session_id)
      end

      def test_close_propagates_server_error_and_still_clears_state
        initialize_session
        stub_request(:delete, url).to_return(status: 500)

        assert_raises(Faraday::ServerError) do
          client.close
        end

        assert_nil(client.session_id)
        assert_nil(client.protocol_version)
      end

      def test_close_propagates_unauthorized_and_still_clears_state
        initialize_session
        stub_request(:delete, url).to_return(status: 401)

        assert_raises(Faraday::UnauthorizedError) do
          client.close
        end

        assert_nil(client.session_id)
      end

      def test_close_propagates_connection_failure_and_still_clears_state
        initialize_session
        stub_request(:delete, url).to_raise(Faraday::ConnectionFailed.new("connection refused"))

        assert_raises(Faraday::ConnectionFailed) do
          client.close
        end

        assert_nil(client.session_id)
      end

      def test_close_is_idempotent
        initialize_session
        stub_request(:delete, url).to_return(status: 200)

        client.close
        client.close

        assert_requested(:delete, url, times: 1)
      end

      def test_connect_performs_initialize_handshake
        init_stub = stub_request(:post, url)
          .with { |req| JSON.parse(req.body)["method"] == "initialize" }
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json", "Mcp-Session-Id" => "s1" },
            body: {
              result: {
                protocolVersion: "2025-11-25",
                capabilities: { tools: {} },
                serverInfo: { name: "test-server", version: "1.0" },
              },
            }.to_json,
          )

        notification_stub = stub_request(:post, url)
          .with { |req| JSON.parse(req.body)["method"] == "notifications/initialized" }
          .to_return(status: 202, body: "")

        result = client.connect

        assert_requested(init_stub)
        assert_requested(notification_stub)
        assert_equal("2025-11-25", result["protocolVersion"])
        assert_equal({ "tools" => {} }, result["capabilities"])
        assert_equal({ "name" => "test-server", "version" => "1.0" }, result["serverInfo"])
      end

      def test_connect_caches_server_info
        stub_initialize
        stub_notification

        client.connect

        assert_equal("2025-11-25", client.server_info["protocolVersion"])
      end

      def test_connect_uses_default_client_info_and_protocol_version
        notification_stub = stub_notification

        init_stub = stub_request(:post, url)
          .with do |req|
            body = JSON.parse(req.body)
            body["method"] == "initialize" &&
              body["params"]["protocolVersion"] == MCP::Configuration::LATEST_STABLE_PROTOCOL_VERSION &&
              body["params"]["clientInfo"] == { "name" => "mcp-ruby-client", "version" => MCP::VERSION } &&
              body["params"]["capabilities"] == {}
          end
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: { protocolVersion: MCP::Configuration::LATEST_STABLE_PROTOCOL_VERSION } }.to_json,
          )

        client.connect

        assert_requested(init_stub)
        assert_requested(notification_stub)
      end

      def test_connect_accepts_custom_parameters
        notification_stub = stub_notification

        init_stub = stub_request(:post, url)
          .with do |req|
            body = JSON.parse(req.body)
            body["method"] == "initialize" &&
              body["params"]["protocolVersion"] == "2025-03-26" &&
              body["params"]["clientInfo"] == { "name" => "my-app", "version" => "9.9" } &&
              body["params"]["capabilities"] == { "roots" => { "listChanged" => true } }
          end
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: { protocolVersion: "2025-03-26" } }.to_json,
          )

        client.connect(
          client_info: { name: "my-app", version: "9.9" },
          protocol_version: "2025-03-26",
          capabilities: { roots: { listChanged: true } },
        )

        assert_requested(init_stub)
        assert_requested(notification_stub)
      end

      def test_connect_is_idempotent
        init_stub = stub_initialize
        notification_stub = stub_notification

        first_result = client.connect
        second_result = client.connect

        assert_same(first_result, second_result)
        assert_requested(init_stub, times: 1)
        assert_requested(notification_stub, times: 1)
      end

      def test_connect_raises_on_jsonrpc_error_response
        stub_request(:post, url).to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Mcp-Session-Id" => "session-abc" },
          body: { error: { code: -32602, message: "Unsupported protocol version" } }.to_json,
        )

        error = assert_raises(RequestHandlerError) do
          client.connect
        end

        assert_includes(error.message, "Unsupported protocol version")
        refute_predicate(client, :connected?)
        assert_nil(client.session_id)
        assert_nil(client.protocol_version)
        assert_nil(client.server_info)
      end

      def test_connect_raises_on_missing_result
        stub_request(:post, url).to_return(
          status: 200,
          headers: { "Content-Type" => "application/json", "Mcp-Session-Id" => "session-abc" },
          body: { jsonrpc: "2.0", id: "x" }.to_json,
        )

        error = assert_raises(RequestHandlerError) do
          client.connect
        end

        assert_includes(error.message, "missing result in response")
        refute_predicate(client, :connected?)
        assert_nil(client.session_id)
        assert_nil(client.protocol_version)
        assert_nil(client.server_info)
      end

      def test_connect_raises_on_unsupported_negotiated_protocol_version
        stub_request(:post, url)
          .with { |req| JSON.parse(req.body)["method"] == "initialize" }
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json", "Mcp-Session-Id" => "session-abc" },
            body: { result: { protocolVersion: "2099-01-01" } }.to_json,
          )

        error = assert_raises(RequestHandlerError) do
          client.connect
        end

        assert_includes(error.message, 'unsupported protocol version "2099-01-01"')
        refute_predicate(client, :connected?)
        assert_nil(client.session_id)
        assert_nil(client.protocol_version)
        assert_nil(client.server_info)
      end

      def test_connect_clears_session_when_initialized_notification_fails
        stub_initialize
        stub_request(:post, url)
          .with { |req| JSON.parse(req.body)["method"] == "notifications/initialized" }
          .to_return(status: 500)

        assert_raises(RequestHandlerError) do
          client.connect
        end

        refute_predicate(client, :connected?)
        assert_nil(client.session_id)
        assert_nil(client.protocol_version)
        assert_nil(client.server_info)
      end

      def test_connected_lifecycle
        refute_predicate(client, :connected?)

        stub_initialize
        stub_notification
        client.connect

        assert_predicate(client, :connected?)

        stub_request(:delete, url).to_return(status: 200)
        client.close

        refute_predicate(client, :connected?)
      end

      def test_reconnect_after_close
        stub_initialize
        stub_notification
        client.connect
        stub_request(:delete, url).to_return(status: 200)
        client.close

        stub_request(:post, url)
          .with { |req| JSON.parse(req.body)["method"] == "initialize" }
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json", "Mcp-Session-Id" => "s2" },
            body: { result: { protocolVersion: "2025-11-25" } }.to_json,
          )

        client.connect

        assert_predicate(client, :connected?)
        assert_equal("s2", client.session_id)
      end

      def test_close_allows_reinitializing_a_fresh_session
        initialize_session
        stub_request(:delete, url).to_return(status: 200)
        client.close

        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
              "Mcp-Session-Id" => "session-xyz",
            },
            body: { result: { protocolVersion: "2025-11-25" } }.to_json,
          )

        client.send_request(request: { jsonrpc: "2.0", id: "2", method: "initialize" })

        assert_equal("session-xyz", client.session_id)
        assert_equal("2025-11-25", client.protocol_version)
      end

      def test_send_notification_posts_body_and_accepts_202
        notification = {
          jsonrpc: "2.0",
          method: MCP::Methods::NOTIFICATIONS_CANCELLED,
          params: { requestId: "req-1", reason: "user cancel" },
        }

        stub_request(:post, url).with(body: notification.to_json).to_return(status: 202, body: "")

        result = client.send_notification(notification: notification)

        assert_nil(result, "send_notification must return nil")
      end

      def test_send_notification_surfaces_faraday_errors
        notification = {
          jsonrpc: "2.0",
          method: MCP::Methods::NOTIFICATIONS_CANCELLED,
          params: { requestId: "req-1" },
        }

        stub_request(:post, url).to_return(status: 500)

        error = assert_raises(RequestHandlerError) do
          client.send_notification(notification: notification)
        end

        assert_equal(:internal_error, error.error_type)
        assert_match(%r{notifications/cancelled}, error.message)
      end

      private

      def initialize_session
        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
              "Mcp-Session-Id" => "session-abc",
            },
            body: { result: { protocolVersion: "2025-11-25" } }.to_json,
          )

        client.send_request(request: { jsonrpc: "2.0", id: "1", method: "initialize" })
      end

      def stub_initialize
        stub_request(:post, url)
          .with { |req| JSON.parse(req.body)["method"] == "initialize" }
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json", "Mcp-Session-Id" => "session-abc" },
            body: { result: { protocolVersion: "2025-11-25" } }.to_json,
          )
      end

      def stub_notification
        stub_request(:post, url)
          .with { |req| JSON.parse(req.body)["method"] == "notifications/initialized" }
          .to_return(status: 202, body: "")
      end

      def stub_request(method, url)
        WebMock.stub_request(method, url)
      end

      # Polls until the block is truthy; the listener runs on a background
      # thread, so its requests are observed asynchronously.
      def wait_until(timeout: 5)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        until yield
          flunk("Timed out waiting for condition") if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          sleep(0.01)
        end
      end

      def requested?(stub)
        WebMock::RequestRegistry.instance.times_executed(stub.request_pattern).positive?
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
