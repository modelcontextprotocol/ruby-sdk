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

      def url
        "http://example.com"
      end

      def client
        @client ||= HTTP.new(url: url)
      end
    end
  end
end
