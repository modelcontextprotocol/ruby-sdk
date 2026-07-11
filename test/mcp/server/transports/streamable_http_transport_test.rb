# frozen_string_literal: true

require "test_helper"
require "rack"

module MCP
  class Server
    module Transports
      class StreamableHTTPTransportTest < ActiveSupport::TestCase
        include InitializeParamsTestHelper

        # A stream that buffers writes and remains readable after close.
        class TestStream
          def initialize
            @buffer = "".dup
            @closed = false
          end

          def write(data)
            raise IOError, "closed stream" if @closed

            @buffer << data
          end

          def flush
          end

          def close
            @closed = true
          end

          def string
            @buffer
          end
        end

        setup do
          @server = Server.new(
            name: "test_server",
            tools: [],
            prompts: [],
            resources: [],
          )
          @transport = StreamableHTTPTransport.new(@server)
        end

        teardown do
          @transport.close
        end

        test "handles POST request with valid JSON-RPC message" do
          # First create a session
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Now make the ping request with the session ID
          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            { jsonrpc: "2.0", method: "ping", id: "123" }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]
          assert_equal "text/event-stream", response[1]["Content-Type"]

          io = StringIO.new
          response[2].call(io)
          body = JSON.parse(io.string.match(/^data: (.+)$/)[1])
          assert_equal "2.0", body["jsonrpc"]
          assert_equal "123", body["id"]
          assert_equal({}, body["result"])
        end

        test "id-bearing notification message is rejected with Method not found" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            { jsonrpc: "2.0", method: "notifications/cancelled", id: "123" }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]

          io = StringIO.new
          response[2].call(io)
          body = JSON.parse(io.string.match(/^data: (.+)$/)[1])

          assert_equal "123", body["id"]
          refute body.key?("result")
          assert_equal JsonRpcHandler::ErrorCode::METHOD_NOT_FOUND, body["error"]["code"]
        end

        test "handles POST request with invalid JSON" do
          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            "invalid json",
          )

          response = @transport.handle_request(request)
          assert_equal 400, response[0]
          assert_equal({ "Content-Type" => "application/json" }, response[1])

          body = JSON.parse(response[2][0])
          assert_equal "2.0", body["jsonrpc"]
          assert_nil body["id"]
          assert_equal JsonRpcHandler::ErrorCode::PARSE_ERROR, body["error"]["code"]
          assert_equal "Parse error: Invalid JSON", body["error"]["message"]
        end

        test "POST request with JSON array body returns 400" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            [{ jsonrpc: "2.0", method: "tools/list", id: "list" }].to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 400, response[0]

          body = JSON.parse(response[2][0])
          assert_equal JsonRpcHandler::ErrorCode::INVALID_REQUEST, body["error"]["code"]
          assert_match(/single request object/i, body["error"]["message"])
        end

        test "POST request with non-object JSON body returns 400" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            "\"foo\"",
          )

          response = @transport.handle_request(request)
          assert_equal 400, response[0]

          body = JSON.parse(response[2][0])
          assert_equal JsonRpcHandler::ErrorCode::INVALID_REQUEST, body["error"]["code"]
          assert_match(/single request object/i, body["error"]["message"])
        end

        test "handles POST request with initialize method" do
          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]
          assert_equal "application/json", response[1]["Content-Type"]
          assert response[1]["Mcp-Session-Id"]

          body = JSON.parse(response[2][0])
          assert_equal "2.0", body["jsonrpc"]
          assert_equal "123", body["id"]
          assert_equal Configuration::LATEST_STABLE_PROTOCOL_VERSION, body["result"]["protocolVersion"]
        end

        test "rejects duplicate initialize with existing Mcp-Session-Id and preserves session" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "first", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]
          assert session_id

          duplicate_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "HTTP_MCP_SESSION_ID" => session_id },
            { jsonrpc: "2.0", method: "initialize", id: "second", params: initialize_params }.to_json,
          )
          duplicate_response = @transport.handle_request(duplicate_request)

          assert_equal 400, duplicate_response[0]
          body = JSON.parse(duplicate_response[2][0])
          assert_equal "2.0", body["jsonrpc"]
          assert_equal "second", body["id"]
          assert_equal JsonRpcHandler::ErrorCode::INVALID_REQUEST, body["error"]["code"]
          assert_match(/already initialized/i, body["error"]["message"])

          # Original session should still be usable.
          ping_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "HTTP_MCP_SESSION_ID" => session_id },
            { jsonrpc: "2.0", method: "ping", id: "ping-1" }.to_json,
          )
          ping_response = @transport.handle_request(ping_request)
          assert_equal 200, ping_response[0]
        end

        test "rejects initialize with stale Mcp-Session-Id with 404" do
          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "HTTP_MCP_SESSION_ID" => "unknown-session" },
            { jsonrpc: "2.0", method: "initialize", id: "1", params: initialize_params }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 404, response[0]
          body = JSON.parse(response[2][0])
          assert_equal "2.0", body["jsonrpc"]
          assert_nil body["id"]
          assert_equal JsonRpcHandler::ErrorCode::INVALID_REQUEST, body["error"]["code"]
          assert_equal "Session not found", body["error"]["message"]
        end

        test "rejects duplicate initialize against an idle-expired session with 404 and evicts it" do
          transport = StreamableHTTPTransport.new(@server, session_idle_timeout: 0.05)
          begin
            init_request = create_rack_request(
              "POST",
              "/",
              { "CONTENT_TYPE" => "application/json" },
              { jsonrpc: "2.0", method: "initialize", id: "first", params: initialize_params }.to_json,
            )
            init_response = transport.handle_request(init_request)
            session_id = init_response[1]["Mcp-Session-Id"]
            assert(session_id)

            sleep(0.1)

            duplicate_request = create_rack_request(
              "POST",
              "/",
              { "CONTENT_TYPE" => "application/json", "HTTP_MCP_SESSION_ID" => session_id },
              { jsonrpc: "2.0", method: "initialize", id: "second", params: initialize_params }.to_json,
            )
            duplicate_response = transport.handle_request(duplicate_request)

            assert_equal(404, duplicate_response[0])
            body = JSON.parse(duplicate_response[2][0])
            assert_equal("Session not found", body["error"]["message"])

            refute(transport.send(:session_exists?, session_id), "expired session must be evicted")
          ensure
            transport.close
          end
        end

        test "evicts session and omits Mcp-Session-Id when initialize fails" do
          # An `initialize` whose JSON-RPC envelope is rejected (e.g. wrong `jsonrpc` version)
          # never reaches `Server#init`, so `mark_initialized!` is never called. The transport
          # must drop the registered-but-uninitialized session to keep retries clean.
          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "1.0", method: "initialize", id: "broken" }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]
          refute response[1].key?("Mcp-Session-Id"), "no session id should leak from a failed init"

          body = JSON.parse(response[2][0])
          assert_equal JsonRpcHandler::ErrorCode::INVALID_REQUEST, body["error"]["code"]
          assert_equal({}, @transport.instance_variable_get(:@sessions))
        end

        test "rejects non-Hash JSON-RPC body with HTTP 400 and -32600" do
          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            [{ jsonrpc: "2.0", method: "initialize", id: "batched", params: initialize_params }].to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 400, response[0]
          body = JSON.parse(response[2][0])
          assert_equal "2.0", body["jsonrpc"]
          assert_nil body["id"]
          assert_equal JsonRpcHandler::ErrorCode::INVALID_REQUEST, body["error"]["code"]
          assert_match(/single request object/i, body["error"]["message"])
        end

        test "handles GET request with valid session ID" do
          # First create a session with initialize
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Then try to connect with GET
          request = create_rack_request(
            "GET",
            "/",
            {
              "HTTP_MCP_SESSION_ID" => session_id,
            },
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]
          assert_equal "text/event-stream", response[1]["Content-Type"]
          assert response[2].is_a?(Proc) # The body should be a Proc for streaming
        end

        test "handles POST request as SSE even when GET SSE stream is closed" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Connect with SSE then close it
          io = StringIO.new
          get_request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          response = @transport.handle_request(get_request)
          response[2].call(io) if response[2].is_a?(Proc)
          sleep(0.1)
          io.close

          # POST request should still return SSE response via POST response stream
          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            { jsonrpc: "2.0", method: "ping", id: "456" }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]
          assert_equal "text/event-stream", response[1]["Content-Type"]
        end

        test "handles POST request as SSE even when GET SSE stream has EPIPE" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Connect GET SSE with a broken pipe
          reader, writer = IO.pipe
          get_request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          response = @transport.handle_request(get_request)
          response[2].call(writer) if response[2].is_a?(Proc)
          sleep(0.1)
          reader.close

          # POST request should still return SSE response via POST response stream
          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            { jsonrpc: "2.0", method: "ping", id: "789" }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal(200, response[0])
          assert_equal("text/event-stream", response[1]["Content-Type"])
        ensure
          begin
            writer.close
          rescue StandardError
            nil
          end
        end

        test "handles POST request as SSE even when GET SSE stream has ECONNRESET" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Connect GET SSE with a mock that raises ECONNRESET
          mock_stream = Object.new
          mock_stream.define_singleton_method(:write) { |_data| raise Errno::ECONNRESET }
          mock_stream.define_singleton_method(:close) {}
          get_request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          response = @transport.handle_request(get_request)
          response[2].call(mock_stream) if response[2].is_a?(Proc)
          sleep(0.1)

          # POST request should still return SSE response via POST response stream
          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            { jsonrpc: "2.0", method: "ping", id: "789" }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]
          assert_equal "text/event-stream", response[1]["Content-Type"]
        end

        test "handles GET request with missing session ID" do
          request = create_rack_request(
            "GET",
            "/",
            {},
          )

          response = @transport.handle_request(request)
          assert_equal 400, response[0]
          assert_equal({ "Content-Type" => "application/json" }, response[1])

          body = JSON.parse(response[2][0])
          assert_equal "2.0", body["jsonrpc"]
          assert_nil body["id"]
          assert_equal JsonRpcHandler::ErrorCode::INVALID_REQUEST, body["error"]["code"]
          assert_equal "Missing session ID", body["error"]["message"]
        end

        test "rejects POST request without session ID in stateful mode" do
          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "ping", id: "1" }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 400, response[0]
          body = JSON.parse(response[2][0])
          assert_equal "Missing session ID", body["error"]["message"]
        end

        test "rejects notification without session ID in stateful mode" do
          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "notifications/initialized" }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 400, response[0]
          body = JSON.parse(response[2][0])
          assert_equal "Missing session ID", body["error"]["message"]
        end

        test "rejects response without session ID in stateful mode" do
          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", id: "1", result: {} }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 400, response[0]
          body = JSON.parse(response[2][0])
          assert_equal "Missing session ID", body["error"]["message"]
        end

        test "allows POST request without session ID in stateless mode" do
          stateless_transport = StreamableHTTPTransport.new(@server, stateless: true)

          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "ping", id: "1" }.to_json,
          )

          response = stateless_transport.handle_request(request)
          assert_equal 200, response[0]
        end

        test "allows server/discover POST without session ID in stateful mode" do
          # Per SEP-2575, `server/discover` is sessionless capability discovery and is exempt
          # from the session requirement, like `initialize`.
          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "server/discover", id: "1" }.to_json,
          )

          response = @transport.handle_request(request)

          assert_equal 200, response[0]
          body = JSON.parse(response[2][0])
          assert_equal Configuration::SUPPORTED_STABLE_PROTOCOL_VERSIONS, body.dig("result", "supportedVersions")
          refute response[1].key?("Mcp-Session-Id")
        end

        test "allows server/discover POST without session ID in stateless mode" do
          stateless_transport = StreamableHTTPTransport.new(@server, stateless: true)

          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "server/discover", id: "1" }.to_json,
          )

          response = stateless_transport.handle_request(request)

          assert_equal 200, response[0]
          body = JSON.parse(response[2][0])
          assert_equal Configuration::SUPPORTED_STABLE_PROTOCOL_VERSIONS, body.dig("result", "supportedVersions")
        end

        test "rejects duplicate SSE connection with 409" do
          # Create a session
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Simulate an active SSE stream by storing a stream object in the session
          mock_stream = StringIO.new
          @transport.instance_variable_get(:@sessions)[session_id][:get_sse_stream] = mock_stream

          # Attempt a second GET request for the same session
          get_request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )

          response = @transport.handle_request(get_request)
          assert_equal 409, response[0]
          assert_equal({ "Content-Type" => "application/json" }, response[1])

          body = JSON.parse(response[2][0])
          assert_equal "2.0", body["jsonrpc"]
          assert_nil body["id"]
          assert_equal JsonRpcHandler::ErrorCode::INVALID_REQUEST, body["error"]["code"]
          assert_equal "Conflict: Only one SSE stream is allowed per session", body["error"]["message"]
        end

        test "store_stream_for_session does not overwrite existing stream (TOCTOU guard)" do
          # Create a session
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Establish stream A
          stream_a = StringIO.new
          @transport.send(:store_stream_for_session, session_id, stream_a)
          assert_equal stream_a, @transport.instance_variable_get(:@sessions)[session_id][:get_sse_stream]

          # Attempt to store stream B (simulating a racing request)
          stream_b = StringIO.new
          @transport.send(:store_stream_for_session, session_id, stream_b)

          # Stream A should still be the active stream
          assert_equal stream_a, @transport.instance_variable_get(:@sessions)[session_id][:get_sse_stream]

          # Stream B should have been closed
          assert stream_b.closed?
        end

        test "handles GET request with invalid session ID" do
          request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => "invalid_id" },
          )

          response = @transport.handle_request(request)
          assert_equal 404, response[0]
          assert_equal({ "Content-Type" => "application/json" }, response[1])

          body = JSON.parse(response[2][0])
          assert_equal "Session not found", body["error"]["message"]
        end

        test "handles POST request with invalid session ID" do
          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => "invalid_id",
            },
            { jsonrpc: "2.0", method: "ping", id: "456" }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 404, response[0]
          assert_equal({ "Content-Type" => "application/json" }, response[1])

          body = JSON.parse(response[2][0])
          assert_equal "Session not found", body["error"]["message"]
        end

        test "handles DELETE request with valid session ID" do
          # First create a session with initialize
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Then try to delete it
          request = create_rack_request(
            "DELETE",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]
          assert_equal({ "Content-Type" => "application/json" }, response[1])

          body = JSON.parse(response[2][0])
          assert body["success"]
        end

        test "handles DELETE request with invalid session ID" do
          request = create_rack_request(
            "DELETE",
            "/",
            { "HTTP_MCP_SESSION_ID" => "invalid_id" },
          )

          response = @transport.handle_request(request)
          assert_equal 404, response[0]
          assert_equal({ "Content-Type" => "application/json" }, response[1])

          body = JSON.parse(response[2][0])
          assert_equal "Session not found", body["error"]["message"]
        end

        test "POST returns 404 after session is deleted" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          delete_request = create_rack_request(
            "DELETE",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          @transport.handle_request(delete_request)

          post_request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            { jsonrpc: "2.0", method: "ping", id: "456" }.to_json,
          )
          response = @transport.handle_request(post_request)
          assert_equal 404, response[0]

          body = JSON.parse(response[2][0])
          assert_equal "Session not found", body["error"]["message"]
        end

        test "DELETE returns 404 after session is already deleted" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          first_delete = create_rack_request(
            "DELETE",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          response = @transport.handle_request(first_delete)
          assert_equal 200, response[0]

          second_delete = create_rack_request(
            "DELETE",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          response = @transport.handle_request(second_delete)
          assert_equal 404, response[0]

          body = JSON.parse(response[2][0])
          assert_equal "Session not found", body["error"]["message"]
        end

        test "handles DELETE request with missing session ID" do
          request = create_rack_request(
            "DELETE",
            "/",
            {},
          )

          response = @transport.handle_request(request)
          assert_equal 400, response[0]
          assert_equal({ "Content-Type" => "application/json" }, response[1])

          body = JSON.parse(response[2][0])
          assert_equal "Missing session ID", body["error"]["message"]
        end

        test "closes transport and cleans up session" do
          # First create a session with initialize
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Then connect with GET
          io = StringIO.new
          request = create_rack_request(
            "GET",
            "/",
            {
              "HTTP_MCP_SESSION_ID" => session_id,
            },
          )
          response = @transport.handle_request(request)
          # Call the body proc with our StringIO
          response[2].call(io) if response[2].is_a?(Proc)

          # Give the background thread a moment to set up
          sleep(0.01)

          # Verify session exists before closing
          assert @transport.instance_variable_get(:@sessions).key?(session_id)

          # Close the transport without session context (closes all sessions)
          @transport.close

          # Verify session was cleaned up
          assert_equal({}, @transport.instance_variable_get(:@sessions))
        end

        test "cleanup_session_unsafe closes request_streams" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Simulate multiple request_streams being set on the session.
          closed = []
          2.times do |i|
            mock_stream = Object.new
            mock_stream.define_singleton_method(:close) { closed << i }
            thread = Thread.new {}
            thread.join
            @transport.instance_variable_get(:@sessions)[session_id][:post_request_streams] ||= {}
            @transport.instance_variable_get(:@sessions)[session_id][:post_request_streams][thread] = mock_stream
          end

          delete_request = create_rack_request(
            "DELETE",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          @transport.handle_request(delete_request)

          assert_equal [0, 1], closed.sort
          assert_empty @transport.instance_variable_get(:@sessions)
        end

        test "broadcast notification skips sessions without GET SSE stream" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          @transport.handle_request(init_request)

          # No GET SSE stream connected, only request_streams.
          # Pass **{} to prevent Ruby 2.7 from converting the Hash to keyword arguments.
          result = @transport.send_notification("test/notify", { message: "hello" }, **{})

          assert_equal 0, result
        end

        test "sends notification to correct session with multiple active sessions" do
          # Create first session
          init_request1 = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )
          init_response1 = @transport.handle_request(init_request1)
          session_id1 = init_response1[1]["Mcp-Session-Id"]

          # Create second session
          init_request2 = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "456", params: initialize_params }.to_json,
          )
          init_response2 = @transport.handle_request(init_request2)
          session_id2 = init_response2[1]["Mcp-Session-Id"]

          # Connect first session with GET
          io1 = StringIO.new
          get_request1 = create_rack_request(
            "GET",
            "/",
            {
              "HTTP_MCP_SESSION_ID" => session_id1,
            },
          )
          response1 = @transport.handle_request(get_request1)
          response1[2].call(io1) if response1[2].is_a?(Proc)

          # Connect second session with GET
          io2 = StringIO.new
          get_request2 = create_rack_request(
            "GET",
            "/",
            {
              "HTTP_MCP_SESSION_ID" => session_id2,
            },
          )
          response2 = @transport.handle_request(get_request2)
          response2[2].call(io2) if response2[2].is_a?(Proc)

          # Give the streams time to be fully set up
          sleep(0.2)

          # Verify sessions are set up
          assert @transport.instance_variable_get(:@sessions).key?(session_id1), "Session 1 not found in @sessions"
          assert @transport.instance_variable_get(:@sessions).key?(session_id2), "Session 2 not found in @sessions"

          # Test that notifications go to the correct session based on the request context
          # First, make a request as session 1
          request_as_session1 = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id1,
            },
            { jsonrpc: "2.0", method: "ping", id: "789" }.to_json,
          )

          # Monkey-patch handle_json on the server to send a notification when called
          original_handle_json = @server.method(:handle_json)
          transport = @transport # Capture the transport in a local variable
          @server.define_singleton_method(:handle_json) do |request, **kwargs|
            result = original_handle_json.call(request, **kwargs)
            # Send notification while still in request context - broadcast to all sessions
            transport.send_notification("test_notification", { session: "current" }, **{})
            result
          end

          # Handle request from session 1 (execute SSE proc)
          response1 = @transport.handle_request(request_as_session1)
          response1[2].call(StringIO.new) if response1[2].is_a?(Proc)

          # Make a request as session 2
          request_as_session2 = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id2,
            },
            { jsonrpc: "2.0", method: "ping", id: "890" }.to_json,
          )

          # Handle request from session 2 (execute SSE proc)
          response2_post = @transport.handle_request(request_as_session2)
          response2_post[2].call(StringIO.new) if response2_post[2].is_a?(Proc)

          # Broadcast notifications are sent to GET SSE streams (no related_request_id)
          io1.rewind
          output1 = io1.read
          assert_equal 2, output1.scan(/data: {"jsonrpc":"2.0","method":"test_notification","params":{"session":"current"}}/).count

          io2.rewind
          output2 = io2.read
          assert_equal 2, output2.scan(/data: {"jsonrpc":"2.0","method":"test_notification","params":{"session":"current"}}/).count
        end

        test "send_notification to specific session" do
          # Create and initialize a session
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Connect with SSE
          io = StringIO.new
          get_request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          response = @transport.handle_request(get_request)
          response[2].call(io) if response[2].is_a?(Proc)

          # Give the stream time to set up
          sleep(0.1)

          # Send notification to specific session
          result = @transport.send_notification("test_notification", { message: "Hello" }, session_id: session_id)

          assert result

          # Check the notification was received
          io.rewind
          output = io.read
          assert_includes output,
            "data: {\"jsonrpc\":\"2.0\",\"method\":\"test_notification\",\"params\":{\"message\":\"Hello\"}}"
        end

        test "send_notification broadcasts to all sessions when no session_id" do
          # Create two sessions
          init_request1 = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )
          init_response1 = @transport.handle_request(init_request1)
          session_id1 = init_response1[1]["Mcp-Session-Id"]

          init_request2 = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "456", params: initialize_params }.to_json,
          )
          init_response2 = @transport.handle_request(init_request2)
          session_id2 = init_response2[1]["Mcp-Session-Id"]

          # Connect both sessions with SSE
          io1 = StringIO.new
          get_request1 = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id1 },
          )
          response1 = @transport.handle_request(get_request1)
          response1[2].call(io1) if response1[2].is_a?(Proc)

          io2 = StringIO.new
          get_request2 = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id2 },
          )
          response2 = @transport.handle_request(get_request2)
          response2[2].call(io2) if response2[2].is_a?(Proc)

          # Give the streams time to set up
          sleep(0.1)

          # Broadcast notification to all sessions
          sent_count = @transport.send_notification("broadcast", { message: "Hello everyone" }, **{})

          assert_equal 2, sent_count

          # Check both sessions received the notification
          io1.rewind
          output1 = io1.read
          assert_includes output1,
            "data: {\"jsonrpc\":\"2.0\",\"method\":\"broadcast\",\"params\":{\"message\":\"Hello everyone\"}}"

          io2.rewind
          output2 = io2.read
          assert_includes output2,
            "data: {\"jsonrpc\":\"2.0\",\"method\":\"broadcast\",\"params\":{\"message\":\"Hello everyone\"}}"
        end

        test "send_notification returns false for non-existent session" do
          result = @transport.send_notification("test", { message: "test" }, session_id: "non_existent")
          refute result
        end

        test "send_notification handles closed streams gracefully" do
          # Create and initialize a session
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Connect with SSE
          io = StringIO.new
          get_request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          response = @transport.handle_request(get_request)
          response[2].call(io) if response[2].is_a?(Proc)

          # Give the stream time to set up
          sleep(0.1)

          # Close the stream
          io.close

          # Try to send notification
          result = @transport.send_notification("test", { message: "test" }, session_id: session_id)

          # Should return false and clean up the session
          refute result

          # Verify session was cleaned up
          assert_not @transport.instance_variable_get(:@sessions).key?(session_id)
        end

        test "send_notification handles Errno::ECONNRESET gracefully" do
          # Create and initialize a session.
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Use a mock stream that raises Errno::ECONNRESET on write.
          mock_stream = Object.new
          mock_stream.define_singleton_method(:write) { |_data| raise Errno::ECONNRESET }
          mock_stream.define_singleton_method(:close) {}

          # Connect with SSE using the mock stream.
          get_request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          response = @transport.handle_request(get_request)
          response[2].call(mock_stream) if response[2].is_a?(Proc)

          # Give the stream time to set up.
          sleep(0.1)

          # Try to send notification - should handle ECONNRESET without raising.
          result = @transport.send_notification("test", { message: "test" }, session_id: session_id)

          # Should return false and clean up the session.
          refute result

          # Verify session was cleaned up.
          assert_not @transport.instance_variable_get(:@sessions).key?(session_id)
        end

        test "send_notification closes stream outside mutex on write error" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Use a mock stream that verifies mutex is NOT held during close.
          mutex = @transport.instance_variable_get(:@mutex)
          closed_outside_mutex = false
          mock_stream = Object.new
          mock_stream.define_singleton_method(:write) { |_data| raise Errno::EPIPE }
          mock_stream.define_singleton_method(:close) do
            if mutex.try_lock
              closed_outside_mutex = true
              mutex.unlock
            end
          end

          @transport.instance_variable_get(:@sessions)[session_id][:get_sse_stream] = mock_stream

          result = @transport.send_notification("test", { message: "test" }, session_id: session_id)

          refute result
          assert closed_outside_mutex, "Stream should be closed outside the mutex"
          assert_not @transport.instance_variable_get(:@sessions).key?(session_id)
        end

        test "send_notification on broken request_stream removes only that stream, not the session" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Connect GET SSE.
          io = StringIO.new
          get_request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          response = @transport.handle_request(get_request)
          response[2].call(io) if response[2].is_a?(Proc)
          sleep(0.1)

          # Simulate a broken request_stream.
          broken_stream = Object.new
          broken_stream.define_singleton_method(:write) { |_data| raise Errno::EPIPE }
          broken_stream.define_singleton_method(:close) {}
          related_id = "req-1"
          @transport.instance_variable_get(:@sessions)[session_id][:post_request_streams] = { related_id => broken_stream }

          result = @transport.send_notification("test", { msg: "hello" }, session_id: session_id, related_request_id: related_id)

          refute result
          # Session should still exist.
          assert @transport.instance_variable_get(:@sessions).key?(session_id)
          # The broken request_stream should be removed.
          refute @transport.instance_variable_get(:@sessions)[session_id][:post_request_streams].key?(related_id)
          # GET SSE stream should still be intact.
          assert @transport.instance_variable_get(:@sessions)[session_id][:get_sse_stream]
        end

        test "active_stream does not fall back to GET SSE when related_request_id is given but request_stream is missing" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Connect GET SSE.
          io = StringIO.new
          get_request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          response = @transport.handle_request(get_request)
          response[2].call(io) if response[2].is_a?(Proc)
          sleep(0.1)

          # Send notification with a related_request_id that has no matching request_stream.
          result = @transport.send_notification(
            "test/notify",
            { message: "should not arrive" },
            session_id: session_id,
            related_request_id: "nonexistent-request-id",
          )

          # Should return false because no matching request_stream exists.
          refute result

          # Session should still exist (not cleaned up).
          assert @transport.instance_variable_get(:@sessions).key?(session_id)

          # GET SSE stream should NOT have received the notification.
          io.rewind
          refute_includes io.read, "should not arrive"
        end

        test "send_notification broadcast continues when one session raises Errno::ECONNRESET" do
          # Create two sessions.
          init_request1 = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "1", params: initialize_params }.to_json,
          )
          init_response1 = @transport.handle_request(init_request1)
          session_id1 = init_response1[1]["Mcp-Session-Id"]

          init_request2 = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "2", params: initialize_params }.to_json,
          )
          init_response2 = @transport.handle_request(init_request2)
          session_id2 = init_response2[1]["Mcp-Session-Id"]

          # Session 1: mock stream that raises ECONNRESET.
          broken_stream = Object.new
          broken_stream.define_singleton_method(:write) { |_data| raise Errno::ECONNRESET }
          broken_stream.define_singleton_method(:close) {}

          get_request1 = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id1 },
          )
          response1 = @transport.handle_request(get_request1)
          response1[2].call(broken_stream) if response1[2].is_a?(Proc)

          # Session 2: healthy stream.
          healthy_stream = StringIO.new
          get_request2 = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id2 },
          )
          response2 = @transport.handle_request(get_request2)
          response2[2].call(healthy_stream) if response2[2].is_a?(Proc)

          # Give the streams time to set up.
          sleep(0.1)

          # Broadcast notification - should not abort despite ECONNRESET from session 1.
          sent_count = @transport.send_notification("test", { message: "hello" }, **{})

          # Session 2 should have received the notification.
          assert_equal 1, sent_count

          healthy_stream.rewind
          output = healthy_stream.read
          assert_includes output, '"method":"test"'

          # Session 1 should have been cleaned up.
          assert_not @transport.instance_variable_get(:@sessions).key?(session_id1)

          # Session 2 should still exist.
          assert @transport.instance_variable_get(:@sessions).key?(session_id2)
        end

        test "send_notification to a session writes outside the mutex" do
          session_id = initialize_test_session
          writes = install_mutex_probe_stream(session_id)

          result = @transport.send_notification("test", { message: "hi" }, session_id: session_id)

          assert result
          assert_equal 1, writes[:total]
          assert_equal 0, writes[:under_mutex], "notification write must not hold @mutex"
        end

        test "send_notification broadcast writes outside the mutex" do
          session_id1 = initialize_test_session(id: "1")
          session_id2 = initialize_test_session(id: "2")
          writes1 = install_mutex_probe_stream(session_id1)
          writes2 = install_mutex_probe_stream(session_id2)

          sent_count = @transport.send_notification("broadcast", { message: "hi" }, **{})

          assert_equal 2, sent_count
          assert_equal 0, writes1[:under_mutex], "broadcast write must not hold @mutex"
          assert_equal 0, writes2[:under_mutex], "broadcast write must not hold @mutex"
        end

        test "send_keepalive_ping writes outside the mutex" do
          session_id = initialize_test_session
          writes = install_mutex_probe_stream(session_id)

          @transport.send(:send_keepalive_ping, session_id)

          assert_equal 1, writes[:total]
          assert_equal 0, writes[:under_mutex], "keepalive write must not hold @mutex"
        end

        test "send_request writes outside the mutex" do
          session_id = initialize_test_session
          writes = install_mutex_probe_stream(session_id)

          result_queue = Queue.new
          thread = Thread.new do
            result_queue.push(@transport.send_request("ping", nil, session_id: session_id))
          end

          # Wait until the request has been written to the probe stream.
          Thread.pass until writes[:total].positive?

          request_id = @transport.instance_variable_get(:@pending_responses).keys.first
          @transport.send(:handle_response, { jsonrpc: "2.0", id: request_id, result: {} }, session_id: session_id)

          result_queue.pop
          thread.join

          assert_equal 1, writes[:total]
          assert_equal 0, writes[:under_mutex], "server-to-client request write must not hold @mutex"
        end

        test "send_keepalive_ping handles Errno::ECONNRESET gracefully" do
          # Create and initialize a session.
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Use a mock stream that raises Errno::ECONNRESET on write.
          mock_stream = Object.new
          mock_stream.define_singleton_method(:write) { |_data| raise Errno::ECONNRESET }
          mock_stream.define_singleton_method(:close) {}

          # Connect with SSE using the mock stream.
          get_request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          response = @transport.handle_request(get_request)
          response[2].call(mock_stream) if response[2].is_a?(Proc)

          # Give the stream time to set up.
          sleep(0.1)

          # send_keepalive_ping is private; re-raises to exit the keepalive loop.
          # Errno::ECONNRESET should be caught by the rescue clause (which reports
          # the exception) before being re-raised. Verify that exception_reporter
          # is called — this fails if ECONNRESET is not in the rescue list.
          reported_errors = []
          original_reporter = MCP.configuration.exception_reporter
          MCP.configuration.exception_reporter = ->(error, context) { reported_errors << [error, context] }

          begin
            assert_raises(Errno::ECONNRESET) do
              @transport.send(:send_keepalive_ping, session_id)
            end

            assert_equal(1, reported_errors.size)
            assert_instance_of(Errno::ECONNRESET, reported_errors.first[0])
            assert_equal("Stream closed", reported_errors.first[1][:error])
          ensure
            MCP.configuration.exception_reporter = original_reporter
          end
        end

        test "responds with 405 for unsupported methods" do
          request = create_rack_request(
            "PUT",
            "/",
            {},
          )

          response = @transport.handle_request(request)
          assert_equal 405, response[0]
          assert_equal({ "Content-Type" => "application/json" }, response[1])

          body = JSON.parse(response[2][0])
          assert_equal "2.0", body["jsonrpc"]
          assert_nil body["id"]
          assert_equal JsonRpcHandler::ErrorCode::INVALID_REQUEST, body["error"]["code"]
          assert_equal "Method not allowed", body["error"]["message"]
        end

        test "POST request without Content-Type returns 415" do
          request = create_rack_request_without_accept(
            "POST",
            "/",
            { "HTTP_ACCEPT" => "application/json, text/event-stream" },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 415, response[0]

          body = JSON.parse(response[2][0])
          assert_equal "2.0", body["jsonrpc"]
          assert_nil body["id"]
          assert_equal JsonRpcHandler::ErrorCode::INVALID_REQUEST, body["error"]["code"]
          assert_equal "Unsupported Media Type: Content-Type must be application/json", body["error"]["message"]
        end

        test "POST request with wrong Content-Type returns 415" do
          request = create_rack_request_without_accept(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "text/plain",
              "HTTP_ACCEPT" => "application/json, text/event-stream",
            },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 415, response[0]
        end

        test "POST request with Content-Type including charset succeeds" do
          request = create_rack_request_without_accept(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json; charset=utf-8",
              "HTTP_ACCEPT" => "application/json, text/event-stream",
            },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]
        end

        test "POST request without Accept header returns 406" do
          request = create_rack_request_without_accept(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 406, response[0]
          assert_equal({ "Content-Type" => "application/json" }, response[1])

          body = JSON.parse(response[2][0])
          assert_equal "Not Acceptable: Accept header must include application/json and text/event-stream",
            body["error"]["message"]
        end

        test "POST request with Accept header missing text/event-stream returns 406" do
          request = create_rack_request_without_accept(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_ACCEPT" => "application/json",
            },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 406, response[0]

          body = JSON.parse(response[2][0])
          assert_equal "Not Acceptable: Accept header must include application/json and text/event-stream",
            body["error"]["message"]
        end

        test "POST request with Accept header missing application/json returns 406" do
          request = create_rack_request_without_accept(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_ACCEPT" => "text/event-stream",
            },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 406, response[0]

          body = JSON.parse(response[2][0])
          assert_equal "Not Acceptable: Accept header must include application/json and text/event-stream",
            body["error"]["message"]
        end

        test "POST request with valid Accept header succeeds" do
          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_ACCEPT" => "application/json, text/event-stream",
            },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]
        end

        test "POST request with Accept header containing quality values succeeds" do
          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_ACCEPT" => "application/json;q=0.9, text/event-stream;q=0.8",
            },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]
        end

        test "POST request with Accept: */* succeeds" do
          request = create_rack_request_without_accept(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_ACCEPT" => "*/*",
            },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]
        end

        test "POST request with mixed-case Accept header succeeds" do
          request = create_rack_request_without_accept(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_ACCEPT" => "Application/JSON, Text/Event-Stream",
            },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]
        end

        test "GET request with upper-case Accept header succeeds" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          request = create_rack_request_without_accept(
            "GET",
            "/",
            {
              "HTTP_ACCEPT" => "TEXT/EVENT-STREAM",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]
          assert_equal "text/event-stream", response[1]["Content-Type"]
        end

        test "GET request without Accept header returns 406" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          request = create_rack_request_without_accept(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )

          response = @transport.handle_request(request)
          assert_equal 406, response[0]

          body = JSON.parse(response[2][0])
          assert_equal "2.0", body["jsonrpc"]
          assert_nil body["id"]
          assert_equal JsonRpcHandler::ErrorCode::INVALID_REQUEST, body["error"]["code"]
          assert_equal "Not Acceptable: Accept header must include text/event-stream", body["error"]["message"]
        end

        test "GET request with Accept header missing text/event-stream returns 406" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          request = create_rack_request_without_accept(
            "GET",
            "/",
            {
              "HTTP_MCP_SESSION_ID" => session_id,
              "HTTP_ACCEPT" => "application/json",
            },
          )

          response = @transport.handle_request(request)
          assert_equal 406, response[0]

          body = JSON.parse(response[2][0])
          assert_equal "Not Acceptable: Accept header must include text/event-stream", body["error"]["message"]
        end

        test "GET request with valid Accept header succeeds" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          request = create_rack_request(
            "GET",
            "/",
            {
              "HTTP_MCP_SESSION_ID" => session_id,
              "HTTP_ACCEPT" => "text/event-stream",
            },
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]
          assert_equal "text/event-stream", response[1]["Content-Type"]
        end

        test "GET request with Accept: */* succeeds" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          request = create_rack_request_without_accept(
            "GET",
            "/",
            {
              "HTTP_MCP_SESSION_ID" => session_id,
              "HTTP_ACCEPT" => "*/*",
            },
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]
          assert_equal "text/event-stream", response[1]["Content-Type"]
        end

        test "POST initialize request ignores MCP-Protocol-Version header" do
          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_PROTOCOL_VERSION" => "1900-01-01",
            },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]
        end

        test "POST initialize request negotiates body protocolVersion when header is an older supported version" do
          older_version = "2025-06-18"
          assert_includes Configuration::SUPPORTED_STABLE_PROTOCOL_VERSIONS, older_version
          refute_equal Configuration::LATEST_STABLE_PROTOCOL_VERSION, older_version

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_PROTOCOL_VERSION" => older_version,
            },
            {
              jsonrpc: "2.0",
              method: "initialize",
              id: "init",
              params: initialize_params,
            }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]
          body = JSON.parse(response[2][0])
          assert_equal Configuration::LATEST_STABLE_PROTOCOL_VERSION, body["result"]["protocolVersion"]
        end

        test "POST initialize request negotiates body protocolVersion when header is a newer supported version" do
          older_version = "2025-06-18"
          assert_includes Configuration::SUPPORTED_STABLE_PROTOCOL_VERSIONS, older_version
          refute_equal Configuration::LATEST_STABLE_PROTOCOL_VERSION, older_version

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_PROTOCOL_VERSION" => Configuration::LATEST_STABLE_PROTOCOL_VERSION,
            },
            {
              jsonrpc: "2.0",
              method: "initialize",
              id: "init",
              params: initialize_params(protocolVersion: older_version),
            }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]
          body = JSON.parse(response[2][0])
          assert_equal older_version, body["result"]["protocolVersion"]
        end

        test "POST request with unsupported MCP-Protocol-Version returns 400" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
              "HTTP_MCP_PROTOCOL_VERSION" => "1999-01-01",
            },
            { jsonrpc: "2.0", method: "tools/list", id: "list" }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 400, response[0]
          assert_equal({ "Content-Type" => "application/json" }, response[1])

          body = JSON.parse(response[2][0])
          assert_equal "2.0", body["jsonrpc"]
          assert_nil body["id"]
          assert_equal JsonRpcHandler::ErrorCode::INVALID_REQUEST, body["error"]["code"]
          assert_includes body["error"]["message"], "1999-01-01"
          assert_includes body["error"]["message"], Configuration::LATEST_STABLE_PROTOCOL_VERSION
        end

        test "POST request with malformed MCP-Protocol-Version returns 400" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
              "HTTP_MCP_PROTOCOL_VERSION" => "not-a-version",
            },
            { jsonrpc: "2.0", method: "tools/list", id: "list" }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 400, response[0]

          body = JSON.parse(response[2][0])
          assert_includes body["error"]["message"], "not-a-version"
        end

        test "POST request with supported MCP-Protocol-Version succeeds" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
              "HTTP_MCP_PROTOCOL_VERSION" => Configuration::LATEST_STABLE_PROTOCOL_VERSION,
            },
            { jsonrpc: "2.0", method: "tools/list", id: "list" }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]
        end

        test "POST request without MCP-Protocol-Version header succeeds" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            { jsonrpc: "2.0", method: "tools/list", id: "list" }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]
        end

        test "missing MCP-Protocol-Version header falls back to default for validation" do
          MCP::Configuration::SUPPORTED_STABLE_PROTOCOL_VERSIONS.stubs(:include?).returns(false)

          request = Rack::Request.new(
            "REQUEST_METHOD" => "POST",
            "PATH_INFO" => "/",
            "rack.input" => StringIO.new(""),
          )

          response = @transport.send(:validate_protocol_version_header, request)
          assert_equal 400, response[0]

          body = JSON.parse(response[2][0])
          assert_includes body["error"]["message"], MCP::Configuration::DEFAULT_NEGOTIATED_PROTOCOL_VERSION
        end

        test "POST request with empty MCP-Protocol-Version header returns 400" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
              "HTTP_MCP_PROTOCOL_VERSION" => "",
            },
            { jsonrpc: "2.0", method: "tools/list", id: "list" }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 400, response[0]

          body = JSON.parse(response[2][0])
          assert_equal JsonRpcHandler::ErrorCode::INVALID_REQUEST, body["error"]["code"]
        end

        test "POST request with array body and unsupported MCP-Protocol-Version returns 400" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
              "HTTP_MCP_PROTOCOL_VERSION" => "1999-01-01",
            },
            [{ jsonrpc: "2.0", method: "tools/list", id: "list" }].to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 400, response[0]

          body = JSON.parse(response[2][0])
          assert_equal JsonRpcHandler::ErrorCode::INVALID_REQUEST, body["error"]["code"]
        end

        test "GET request with unsupported MCP-Protocol-Version returns 400" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          request = create_rack_request(
            "GET",
            "/",
            {
              "HTTP_MCP_SESSION_ID" => session_id,
              "HTTP_MCP_PROTOCOL_VERSION" => "1999-01-01",
            },
          )

          response = @transport.handle_request(request)
          assert_equal 400, response[0]

          body = JSON.parse(response[2][0])
          assert_equal JsonRpcHandler::ErrorCode::INVALID_REQUEST, body["error"]["code"]
        end

        test "GET request without MCP-Protocol-Version header succeeds" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]
        end

        test "DELETE request with unsupported MCP-Protocol-Version returns 400" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          request = create_rack_request(
            "DELETE",
            "/",
            {
              "HTTP_MCP_SESSION_ID" => session_id,
              "HTTP_MCP_PROTOCOL_VERSION" => "1999-01-01",
            },
          )

          response = @transport.handle_request(request)
          assert_equal 400, response[0]

          body = JSON.parse(response[2][0])
          assert_equal JsonRpcHandler::ErrorCode::INVALID_REQUEST, body["error"]["code"]
        end

        test "DELETE request with unsupported MCP-Protocol-Version returns 400 in stateless mode" do
          stateless_transport = StreamableHTTPTransport.new(@server, stateless: true)

          request = create_rack_request(
            "DELETE",
            "/",
            { "HTTP_MCP_PROTOCOL_VERSION" => "1999-01-01" },
          )

          response = stateless_transport.handle_request(request)
          assert_equal 400, response[0]
        end

        test "DELETE request validates session before MCP-Protocol-Version" do
          request = create_rack_request(
            "DELETE",
            "/",
            {
              "HTTP_MCP_SESSION_ID" => "unknown-session-id",
              "HTTP_MCP_PROTOCOL_VERSION" => "1999-01-01",
            },
          )

          response = @transport.handle_request(request)
          assert_equal 404, response[0]
        end

        test "stateless mode allows requests without session IDs, responding with no session ID" do
          stateless_transport = StreamableHTTPTransport.new(@server, stateless: true)

          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = stateless_transport.handle_request(init_request)
          assert_nil init_response[1]["Mcp-Session-Id"]
        end

        test "stateless mode responds without any session ID when session ID is present" do
          stateless_transport = StreamableHTTPTransport.new(@server, stateless: true)

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => "unseen_session_id",
            },
            { jsonrpc: "2.0", method: "ping", id: "123" }.to_json,
          )

          response = stateless_transport.handle_request(request)
          assert_equal 200, response[0]
          assert_equal(
            {
              "Content-Type" => "application/json",
            },
            response[1],
          )

          body = JSON.parse(response[2][0])
          assert_equal "2.0", body["jsonrpc"]
          assert_equal "123", body["id"]
        end

        test "stateless mode responds with 405 when SSE is requested" do
          stateless_transport = StreamableHTTPTransport.new(@server, stateless: true)

          get_request = create_rack_request(
            "GET",
            "/",
            {
              "CONTENT_TYPE" => "application/json,text/event-stream",
            },
          )
          response = stateless_transport.handle_request(get_request)
          assert_equal 405, response[0]
          assert_equal({ "Content-Type" => "application/json" }, response[1])

          body = JSON.parse(response[2][0])
          assert_equal "Method not allowed", body["error"]["message"]
        end

        test "stateless mode silently responds with success to session DELETE when session ID is not present" do
          stateless_transport = StreamableHTTPTransport.new(@server, stateless: true)

          delete_request = create_rack_request(
            "DELETE",
            "/",
            {},
          )
          response = stateless_transport.handle_request(delete_request)
          assert_equal 200, response[0]
          assert_equal({ "Content-Type" => "application/json" }, response[1])

          body = JSON.parse(response[2][0])
          assert body["success"]
        end

        test "stateless mode silently responds with success to session DELETE when session ID is provided" do
          stateless_transport = StreamableHTTPTransport.new(@server, stateless: true)

          delete_request = create_rack_request(
            "DELETE",
            "/",
            { "HTTP_MCP_SESSION_ID" => "session_id" },
          )
          response = stateless_transport.handle_request(delete_request)
          assert_equal 200, response[0]
          assert_equal({ "Content-Type" => "application/json" }, response[1])

          body = JSON.parse(response[2][0])
          assert body["success"]
        end

        test "stateless mode does not support server-sent events" do
          # Notifications have no stream to ride in stateless mode; the transport reports non-delivery
          # instead of raising so per-request session notify_* helpers degrade gracefully (SEP-2567).
          stateless_transport = StreamableHTTPTransport.new(@server, stateless: true)

          result = stateless_transport.send_notification(
            "test_notification",
            { message: "Hello" },
            session_id: "some_session_id",
          )

          refute result
        end

        test "stateless mode does not leak client info onto the shared server" do
          # Each stateless POST runs against an ephemeral per-request session (SEP-2567); concurrent requests
          # must never observe another client's identity through the shared Server instance.
          stateless_transport = StreamableHTTPTransport.new(@server, stateless: true)

          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            {
              jsonrpc: "2.0",
              method: "initialize",
              id: 1,
              params: {
                protocolVersion: "2025-11-25",
                capabilities: { roots: {} },
                clientInfo: { name: "client-a", version: "1.0" },
              },
            }.to_json,
          )
          response = stateless_transport.handle_request(request)

          assert_equal 200, response[0]
          assert_nil @server.client_capabilities
          assert_nil @server.instance_variable_get(:@client)
        end

        test "stateless mode allows repeated initialize requests" do
          stateless_transport = StreamableHTTPTransport.new(@server, stateless: true)

          2.times do |i|
            request = create_rack_request(
              "POST",
              "/",
              { "CONTENT_TYPE" => "application/json" },
              {
                jsonrpc: "2.0",
                method: "initialize",
                id: i + 1,
                params: initialize_params(clientInfo: { name: "client-#{i}", version: "1.0" }),
              }.to_json,
            )
            response = stateless_transport.handle_request(request)

            assert_equal 200, response[0]
            body = JSON.parse(response[2][0])
            assert body.key?("result"), "initialize ##{i + 1} should succeed, got #{body.inspect}"
            refute response[1].key?("Mcp-Session-Id")
          end
        end

        test "stateless mode skips progress notifications without raising" do
          reported = []
          configuration = MCP::Configuration.new
          configuration.exception_reporter = ->(exception, _context) { reported << exception }

          server = Server.new(name: "stateless_progress_test", configuration: configuration)
          server.define_tool(name: "progress_tool") do |server_context:|
            server_context.report_progress(50, total: 100)
            Tool::Response.new([{ type: "text", text: "ok" }])
          end
          stateless_transport = StreamableHTTPTransport.new(server, stateless: true)

          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            {
              jsonrpc: "2.0",
              method: "tools/call",
              id: 1,
              params: { name: "progress_tool", arguments: {}, _meta: { progressToken: "tok" } },
            }.to_json,
          )
          response = stateless_transport.handle_request(request)

          assert_equal 200, response[0]
          body = JSON.parse(response[2][0])
          assert_equal "ok", body.dig("result", "content", 0, "text")
          assert_empty reported
        end

        test "stateless mode responds with 202 when client sends a notification/initialized request" do
          stateless_transport = StreamableHTTPTransport.new(@server, stateless: true)

          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "notifications/initialized" }.to_json,
          )

          response = stateless_transport.handle_request(request)
          assert_equal 202, response[0]
          assert_equal({}, response[1])

          body = response[2][0]
          assert_nil(body)
        end

        test "POST request returns SSE response even with GET SSE connected" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Connect with GET SSE
          io = StringIO.new
          get_request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          response = @transport.handle_request(get_request)
          response[2].call(io) if response[2].is_a?(Proc)
          sleep(0.1)

          # POST request should return SSE, not 202
          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            { jsonrpc: "2.0", method: "ping", id: "456" }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]
          assert_equal "text/event-stream", response[1]["Content-Type"]

          post_io = StringIO.new
          response[2].call(post_io)
          body = JSON.parse(post_io.string.match(/^data: (.+)$/)[1])
          assert_equal "456", body["id"]
        end

        test "JSON response mode returns application/json for POST requests" do
          server = Server.new(name: "test", tools: [], prompts: [], resources: [])
          transport = StreamableHTTPTransport.new(server, enable_json_response: true)
          server.transport = transport

          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            { jsonrpc: "2.0", method: "ping", id: "1" }.to_json,
          )

          response = transport.handle_request(request)
          assert_equal(200, response[0])
          assert_equal("application/json", response[1]["Content-Type"])

          body = JSON.parse(response[2][0])
          assert_equal("1", body["id"])
        ensure
          transport.close
        end

        test "JSON response mode accepts application/json only in Accept header" do
          server = Server.new(name: "test", tools: [], prompts: [], resources: [])
          transport = StreamableHTTPTransport.new(server, enable_json_response: true)
          server.transport = transport

          request = create_rack_request_without_accept(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_ACCEPT" => "application/json",
            },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )

          response = transport.handle_request(request)
          assert_equal(200, response[0])
        ensure
          transport.close
        end

        test "JSON response mode returns 406 when Accept header is missing" do
          server = Server.new(name: "test", tools: [], prompts: [], resources: [])
          transport = StreamableHTTPTransport.new(server, enable_json_response: true)
          server.transport = transport

          request = create_rack_request_without_accept(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )

          response = transport.handle_request(request)
          assert_equal(406, response[0])
        ensure
          transport.close
        end

        test "JSON response mode accepts wildcard Accept header" do
          server = Server.new(name: "test", tools: [], prompts: [], resources: [])
          transport = StreamableHTTPTransport.new(server, enable_json_response: true)
          server.transport = transport

          request = create_rack_request_without_accept(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_ACCEPT" => "*/*",
            },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )

          response = transport.handle_request(request)
          assert_equal(200, response[0])
        ensure
          transport.close
        end

        test "JSON response mode drops notifications during tool execution" do
          server = Server.new(name: "test", tools: [], prompts: [], resources: [])
          server.logging_message_notification = MCP::LoggingMessageNotification.new(level: "debug")
          transport = StreamableHTTPTransport.new(server, enable_json_response: true)
          server.transport = transport

          server.define_tool(name: "log_tool") do |server_context:|
            server_context.notify_log_message(data: "should be dropped", level: "info")
            Tool::Response.new([{ type: "text", text: "ok" }])
          end
          server.server_context = server

          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            {
              jsonrpc: "2.0",
              method: "initialize",
              id: "init",
              params: initialize_params,
            }.to_json,
          )
          init_response = transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          tool_request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            {
              jsonrpc: "2.0",
              id: "call-1",
              method: "tools/call",
              params: { name: "log_tool", arguments: {} },
            }.to_json,
          )

          response = transport.handle_request(tool_request)
          assert_equal(200, response[0])
          assert_equal("application/json", response[1]["Content-Type"])

          body = JSON.parse(response[2][0])
          assert_equal("call-1", body["id"])
          refute_includes(response[2][0], "should be dropped")
        ensure
          transport.close
        end

        test "JSON response mode drops notifications even with GET SSE connected" do
          server = Server.new(name: "test", tools: [], prompts: [], resources: [])
          server.logging_message_notification = MCP::LoggingMessageNotification.new(level: "debug")
          transport = StreamableHTTPTransport.new(server, enable_json_response: true)
          server.transport = transport

          server.define_tool(name: "log_tool") do |server_context:|
            server_context.notify_log_message(data: "should not leak", level: "info")
            Tool::Response.new([{ type: "text", text: "ok" }])
          end
          server.server_context = server

          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            {
              jsonrpc: "2.0",
              method: "initialize",
              id: "init",
              params: initialize_params,
            }.to_json,
          )
          init_response = transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Connect GET SSE.
          io = StringIO.new
          get_request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          get_response = transport.handle_request(get_request)
          get_response[2].call(io) if get_response[2].is_a?(Proc)
          sleep(0.1)

          # Call tool that sends a notification.
          tool_request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            {
              jsonrpc: "2.0",
              id: "call-1",
              method: "tools/call",
              params: { name: "log_tool", arguments: {} },
            }.to_json,
          )

          response = transport.handle_request(tool_request)
          assert_equal(200, response[0])
          assert_equal("application/json", response[1]["Content-Type"])

          # Notification should NOT leak to GET SSE stream.
          io.rewind
          refute_includes(io.read, "should not leak")
        ensure
          transport.close
        end

        test "JSON response mode raises on send_request (sampling)" do
          server = Server.new(name: "test", tools: [], prompts: [], resources: [])
          transport = StreamableHTTPTransport.new(server, enable_json_response: true)
          server.transport = transport

          error = assert_raises(RuntimeError) do
            transport.send_request("sampling/createMessage", { messages: [] }, session_id: "s1")
          end

          assert_equal("JSON response mode does not support server-to-client requests.", error.message)
        ensure
          transport.close
        end

        test "JSON response mode raises on send_request (roots/list)" do
          server = Server.new(name: "test", tools: [], prompts: [], resources: [])
          transport = StreamableHTTPTransport.new(server, enable_json_response: true)
          server.transport = transport

          error = assert_raises(RuntimeError) do
            transport.send_request("roots/list", nil, session_id: "s1")
          end

          assert_equal("JSON response mode does not support server-to-client requests.", error.message)
        ensure
          transport.close
        end

        test "JSON response mode raises on send_request (elicitation/create)" do
          server = Server.new(name: "test", tools: [], prompts: [], resources: [])
          transport = StreamableHTTPTransport.new(server, enable_json_response: true)
          server.transport = transport

          error = assert_raises(RuntimeError) do
            transport.send_request(
              "elicitation/create",
              { mode: "form", message: "test", requestedSchema: {} },
              session_id: "s1",
            )
          end

          assert_equal("JSON response mode does not support server-to-client requests.", error.message)
        ensure
          transport.close
        end

        test "JSON response mode allows broadcast notifications via GET SSE" do
          server = Server.new(name: "test", tools: [], prompts: [], resources: [])
          transport = StreamableHTTPTransport.new(server, enable_json_response: true)
          server.transport = transport
          server.server_context = server

          server.define_tool(name: "notify_tool") do |server_context:|
            server_context.notify_tools_list_changed
            Tool::Response.new([{ type: "text", text: "ok" }])
          end

          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            {
              jsonrpc: "2.0",
              method: "initialize",
              id: "init",
              params: initialize_params,
            }.to_json,
          )
          init_response = transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Connect GET SSE.
          io = StringIO.new
          get_request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          get_response = transport.handle_request(get_request)
          get_response[2].call(io) if get_response[2].is_a?(Proc)
          sleep(0.1)

          # Call tool that triggers a broadcast notification.
          tool_request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            {
              jsonrpc: "2.0",
              id: "call-1",
              method: "tools/call",
              params: { name: "notify_tool", arguments: {} },
            }.to_json,
          )

          response = transport.handle_request(tool_request)
          assert_equal(200, response[0])
          assert_equal("application/json", response[1]["Content-Type"])

          # Broadcast notification should arrive on GET SSE stream.
          io.rewind
          assert_includes(io.read, "notifications/tools/list_changed")
        ensure
          transport.close
        end

        test "JSON response mode with stateless returns application/json without session ID" do
          server = Server.new(name: "test", tools: [], prompts: [], resources: [])
          transport = StreamableHTTPTransport.new(server, stateless: true, enable_json_response: true)
          server.transport = transport

          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "ping", id: "1" }.to_json,
          )

          response = transport.handle_request(request)
          assert_equal(200, response[0])
          assert_equal("application/json", response[1]["Content-Type"])
          assert_nil(response[1]["Mcp-Session-Id"])

          body = JSON.parse(response[2][0])
          assert_equal("1", body["id"])
        ensure
          transport.close
        end

        test "JSON response mode with stateless returns 405 on GET" do
          server = Server.new(name: "test", tools: [], prompts: [], resources: [])
          transport = StreamableHTTPTransport.new(server, stateless: true, enable_json_response: true)
          server.transport = transport

          request = create_rack_request("GET", "/", {})

          response = transport.handle_request(request)
          assert_equal(405, response[0])
        ensure
          transport.close
        end

        test "JSON response mode delivers session-scoped standalone notifications via GET SSE" do
          server = Server.new(name: "test", tools: [], prompts: [], resources: [])
          transport = StreamableHTTPTransport.new(server, enable_json_response: true)
          server.transport = transport
          server.server_context = server

          server.define_tool(name: "touch_tool") do |server_context:|
            server_context.notify_resources_updated(uri: "file:///example.txt")
            Tool::Response.new([{ type: "text", text: "ok" }])
          end

          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            {
              jsonrpc: "2.0",
              method: "initialize",
              id: "init",
              params: initialize_params,
            }.to_json,
          )
          init_response = transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          io = StringIO.new
          get_request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          get_response = transport.handle_request(get_request)
          get_response[2].call(io) if get_response[2].is_a?(Proc)
          sleep(0.1)

          tool_request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            {
              jsonrpc: "2.0",
              id: "call-1",
              method: "tools/call",
              params: { name: "touch_tool", arguments: {} },
            }.to_json,
          )

          response = transport.handle_request(tool_request)
          assert_equal(200, response[0])
          assert_equal("application/json", response[1]["Content-Type"])

          io.rewind
          assert_includes(io.read, "notifications/resources/updated")
        ensure
          transport.close
        end

        test "handle post request with a standard error" do
          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "4567", params: initialize_params }.to_json,
          )

          @transport.define_singleton_method(:extract_session_id) do |_request|
            raise StandardError, "Test error"
          end

          response = @transport.handle_request(request)
          assert_equal 500, response[0]
          assert_equal({ "Content-Type" => "application/json" }, response[1])

          body = JSON.parse(response[2][0])
          assert_equal "2.0", body["jsonrpc"]
          assert_nil body["id"]
          assert_equal JsonRpcHandler::ErrorCode::INTERNAL_ERROR, body["error"]["code"]
          assert_equal "Internal server error", body["error"]["message"]
        end

        test "send_request raises error in stateless mode" do
          stateless_transport = StreamableHTTPTransport.new(@server, stateless: true)

          error = assert_raises(RuntimeError) do
            stateless_transport.send_request("sampling/createMessage", { "messages" => [] })
          end

          assert_equal("Stateless mode does not support server-to-client requests.", error.message)
        end

        test "send_request raises error when session_id is not provided" do
          error = assert_raises(RuntimeError) do
            @transport.send_request("sampling/createMessage", { "messages" => [] })
          end

          assert_equal("session_id is required for server-to-client requests.", error.message)
        end

        test "send_request raises error when session is not found" do
          error = assert_raises(RuntimeError) do
            @transport.send_request("sampling/createMessage", { "messages" => [] }, session_id: "nonexistent")
          end

          assert_equal("Session not found: nonexistent.", error.message)
        end

        test "send_request raises error when no active SSE streams" do
          # Create session but do NOT connect SSE.
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          error = assert_raises(RuntimeError) do
            @transport.send_request("sampling/createMessage", { "messages" => [] }, session_id: session_id)
          end

          assert_equal("No active stream for sampling/createMessage request.", error.message)
        end

        test "send_request sends via SSE and waits for response" do
          # Create session.
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Connect SSE.
          io = StringIO.new
          get_request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          response = @transport.handle_request(get_request)
          response[2].call(io) if response[2].is_a?(Proc)

          sleep(0.1) # Give the stream time to set up.

          # Send request in background.
          result_queue = Queue.new
          Thread.new do
            result = @transport.send_request(
              "sampling/createMessage",
              { messages: [{ role: "user", content: { type: "text", text: "Hello" } }], maxTokens: 100 },
              session_id: session_id,
            )
            result_queue.push(result)
          end

          sleep(0.1) # Wait for the request to be sent.

          # Verify request was sent to stream.
          io.rewind
          output = io.read
          assert_includes output, "sampling/createMessage"

          # Parse the sent request to get its ID.
          data_lines = output.lines.select { |line| line.start_with?("data: ") }
          request_data = JSON.parse(data_lines.first.sub("data: ", ""))
          request_id = request_data["id"]

          # Simulate client response.
          client_response = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            {
              jsonrpc: "2.0",
              id: request_id,
              result: { role: "assistant", content: { type: "text", text: "Hi there" } },
            }.to_json,
          )
          @transport.handle_request(client_response)

          # Get result.
          result = result_queue.pop
          assert_equal "assistant", result[:role]
          assert_equal "Hi there", result[:content][:text]
        end

        test "send_request with related_request_id rides the originating POST stream, not the GET stream" do
          # Per SEP-2260, server-to-client requests associated with a client request are delivered on
          # that request's POST SSE response stream rather than the standalone GET stream.
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Connect GET SSE.
          get_io = StringIO.new
          get_request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          response = @transport.handle_request(get_request)
          response[2].call(get_io) if response[2].is_a?(Proc)
          sleep(0.1)

          # Register an in-flight POST request stream for "req-1".
          post_io = StringIO.new
          @transport.instance_variable_get(:@sessions)[session_id][:post_request_streams] = { "req-1" => post_io }

          result_queue = Queue.new
          Thread.new do
            result = @transport.send_request(
              "roots/list",
              nil,
              session_id: session_id,
              related_request_id: "req-1",
            )
            result_queue.push(result)
          end

          sleep(0.1)

          post_io.rewind
          post_output = post_io.read
          assert_includes post_output, "roots/list"

          get_io.rewind
          refute_includes get_io.read, "roots/list"

          # Respond so the background send_request completes.
          data_lines = post_output.lines.select { |line| line.start_with?("data: ") }
          request_id = JSON.parse(data_lines.first.sub("data: ", ""))["id"]
          client_response = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "HTTP_MCP_SESSION_ID" => session_id },
            { jsonrpc: "2.0", id: request_id, result: { roots: [] } }.to_json,
          )
          @transport.handle_request(client_response)

          assert_equal({ roots: [] }, result_queue.pop)
        end

        test "send_request ignores response from wrong session" do
          # Create two sessions.
          init_a = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init-a", params: initialize_params }.to_json,
          )
          resp_a = @transport.handle_request(init_a)
          session_a = resp_a[1]["Mcp-Session-Id"]

          init_b = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init-b", params: initialize_params }.to_json,
          )
          resp_b = @transport.handle_request(init_b)
          session_b = resp_b[1]["Mcp-Session-Id"]

          # Connect SSE for session A.
          io_a = StringIO.new
          get_a = create_rack_request("GET", "/", { "HTTP_MCP_SESSION_ID" => session_a })
          response_a = @transport.handle_request(get_a)
          response_a[2].call(io_a) if response_a[2].is_a?(Proc)

          sleep(0.1) # Give the stream time to set up.

          # Send sampling request targeting session A.
          result_queue = Queue.new
          Thread.new do
            result = @transport.send_request(
              "sampling/createMessage",
              { messages: [{ role: "user", content: { type: "text", text: "Hello" } }], maxTokens: 100 },
              session_id: session_a,
            )
            result_queue.push(result)
          end

          sleep(0.1) # Wait for the request to be sent.

          # Get the request ID from session A's stream.
          io_a.rewind
          data_lines = io_a.read.lines.select { |line| line.start_with?("data: ") }
          request_data = JSON.parse(data_lines.first.sub("data: ", ""))
          request_id = request_data["id"]

          # Session B tries to respond (cross-session injection attempt).
          cross_session_response = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "HTTP_MCP_SESSION_ID" => session_b },
            { jsonrpc: "2.0", id: request_id, result: { role: "assistant", content: { type: "text", text: "injected" } } }.to_json,
          )
          @transport.handle_request(cross_session_response)

          # The request should still be pending (not resolved by wrong session).
          assert_empty(result_queue, "Response from wrong session should be ignored")

          # Now send the correct response from session A.
          correct_response = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "HTTP_MCP_SESSION_ID" => session_a },
            { jsonrpc: "2.0", id: request_id, result: { role: "assistant", content: { type: "text", text: "correct" } } }.to_json,
          )
          @transport.handle_request(correct_response)

          result = result_queue.pop
          assert_equal "correct", result[:content][:text]
        end

        test "send_request with parent_cancellation unblocks with MCP::CancelledError when cancelled" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          io = StringIO.new
          get_request = create_rack_request("GET", "/", { "HTTP_MCP_SESSION_ID" => session_id })
          response = @transport.handle_request(get_request)
          response[2].call(io) if response[2].is_a?(Proc)

          sleep(0.1)

          cancellation = MCP::Cancellation.new(request_id: "parent-1")
          server_session = @transport.instance_variable_get(:@sessions)[session_id][:server_session]

          result_queue = Queue.new
          Thread.new do
            @transport.send_request(
              "sampling/createMessage",
              { messages: [] },
              session_id: session_id,
              parent_cancellation: cancellation,
              server_session: server_session,
            )
          rescue => e
            result_queue.push(e)
          end

          sleep(0.1)
          cancellation.cancel(reason: "parent cancelled")

          error = result_queue.pop
          assert_kind_of MCP::CancelledError, error
        end

        test "send_request deregisters on_cancel hook after completion so late parent cancel is a no-op" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          io = StringIO.new
          get_request = create_rack_request("GET", "/", { "HTTP_MCP_SESSION_ID" => session_id })
          response = @transport.handle_request(get_request)
          response[2].call(io) if response[2].is_a?(Proc)

          sleep(0.1)

          cancellation = MCP::Cancellation.new(request_id: "parent-x")
          server_session = @transport.instance_variable_get(:@sessions)[session_id][:server_session]

          result_queue = Queue.new
          Thread.new do
            result = @transport.send_request(
              "sampling/createMessage",
              { messages: [] },
              session_id: session_id,
              parent_cancellation: cancellation,
              server_session: server_session,
            )
            result_queue.push(result)
          end

          sleep(0.1)

          io.rewind
          data_lines = io.read.lines.select { |line| line.start_with?("data: ") }
          request_data = JSON.parse(data_lines.first.sub("data: ", ""))
          nested_request_id = request_data["id"]

          # Client responds successfully; send_request completes normally.
          client_response = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "HTTP_MCP_SESSION_ID" => session_id },
            { jsonrpc: "2.0", id: nested_request_id, result: { role: "assistant", content: { type: "text", text: "ok" } } }.to_json,
          )
          @transport.handle_request(client_response)

          result = result_queue.pop
          assert_equal "ok", result[:content][:text]

          # Snapshot what was written to the SSE stream before late cancel.
          io.rewind
          before_cancel = io.read

          # Parent is cancelled after the nested request already completed. The hook must
          # have been deregistered, so no `notifications/cancelled` should go to the peer
          # for the already-completed nested request.
          cancellation.cancel(reason: "late")

          sleep(0.05) # Give any stray callback time to fire (none should).

          io.rewind
          after_cancel = io.read

          refute_includes after_cancel.sub(before_cancel, ""), "notifications/cancelled"
        end

        test "cancel_pending_request is no-op when a real response is already queued (race)" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          io = StringIO.new
          get_request = create_rack_request("GET", "/", { "HTTP_MCP_SESSION_ID" => session_id })
          response = @transport.handle_request(get_request)
          response[2].call(io) if response[2].is_a?(Proc)

          sleep(0.1)

          result_queue = Queue.new
          Thread.new do
            result = @transport.send_request(
              "sampling/createMessage",
              { messages: [] },
              session_id: session_id,
            )
            result_queue.push(result)
          end

          sleep(0.1)

          io.rewind
          data_lines = io.read.lines.select { |line| line.start_with?("data: ") }
          request_data = JSON.parse(data_lines.first.sub("data: ", ""))
          request_id = request_data["id"]

          # Client responded first.
          client_response = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "HTTP_MCP_SESSION_ID" => session_id },
            { jsonrpc: "2.0", id: request_id, result: { role: "assistant", content: { type: "text", text: "ok" } } }.to_json,
          )
          @transport.handle_request(client_response)

          # Cancel arrives after the response was already enqueued. Must not clobber the result.
          @transport.cancel_pending_request(request_id, reason: "late cancel")

          result = result_queue.pop
          assert_equal "ok", result[:content][:text]
        end

        test "JSON response mode returns accepted when cancellation suppresses response" do
          server = Server.new(name: "test", tools: [], prompts: [], resources: [])
          transport = StreamableHTTPTransport.new(server, enable_json_response: true)
          server.transport = transport

          server.define_tool(name: "slow_tool") do |server_context:|
            50.times do
              break if server_context.cancelled?

              sleep(0.01)
            end

            Tool::Response.new([{ type: "text", text: "done" }])
          end

          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            {
              jsonrpc: "2.0",
              method: "initialize",
              id: "init",
              params: initialize_params,
            }.to_json,
          )
          init_response = transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]
          server_session = transport.instance_variable_get(:@sessions)[session_id][:server_session]

          tool_request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            {
              jsonrpc: "2.0",
              id: "call-1",
              method: "tools/call",
              params: { name: "slow_tool", arguments: {} },
            }.to_json,
          )

          response_queue = Queue.new
          request_thread = Thread.new { response_queue.push(transport.handle_request(tool_request)) }
          sleep(0.01) until server_session.lookup_in_flight("call-1")

          cancel_request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            {
              jsonrpc: "2.0",
              method: MCP::Methods::NOTIFICATIONS_CANCELLED,
              params: { requestId: "call-1", reason: "user cancelled" },
            }.to_json,
          )

          cancel_response = transport.handle_request(cancel_request)
          assert_equal(202, cancel_response[0])

          response = response_queue.pop
          assert_equal(202, response[0])
          assert_empty(response[1])
          assert_empty(response[2])
        ensure
          request_thread.kill if request_thread.alive?
          transport.close
        end

        test "send_request raises on error response from client" do
          # Create session.
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Connect SSE.
          io = StringIO.new
          get_request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          response = @transport.handle_request(get_request)
          response[2].call(io) if response[2].is_a?(Proc)

          sleep(0.1) # Give the stream time to set up.

          error_queue = Queue.new
          Thread.new do
            @transport.send_request("sampling/createMessage", { messages: [] }, session_id: session_id)
          rescue => e
            error_queue.push(e)
          end

          sleep(0.1) # Wait for the request to be sent.

          # Get request ID from stream.
          io.rewind
          data_lines = io.read.lines.select { |line| line.start_with?("data: ") }
          request_data = JSON.parse(data_lines.first.sub("data: ", ""))
          request_id = request_data["id"]

          # Send error response.
          error_response = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            {
              jsonrpc: "2.0",
              id: request_id,
              error: { code: -1, message: "User rejected" },
            }.to_json,
          )
          @transport.handle_request(error_response)

          error = error_queue.pop
          assert_kind_of StandardError, error
          assert_equal("Client returned an error for sampling/createMessage request (code: -1): User rejected", error.message)
        end

        test "send_request unblocks when session is cleaned up" do
          # Create session.
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Connect SSE.
          io = StringIO.new
          get_request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          response = @transport.handle_request(get_request)
          response[2].call(io) if response[2].is_a?(Proc)

          sleep(0.1) # Give the stream time to set up.

          error_queue = Queue.new
          Thread.new do
            @transport.send_request("sampling/createMessage", { messages: [] }, session_id: session_id)
          rescue => e
            error_queue.push(e)
          end

          sleep(0.1) # Wait for the request to be sent.

          # Delete the session to trigger cleanup (simulates client disconnect).
          delete_request = create_rack_request(
            "DELETE",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          @transport.handle_request(delete_request)

          error = error_queue.pop
          assert_kind_of RuntimeError, error
          assert_equal("SSE session closed while waiting for sampling/createMessage response.", error.message)
        end

        test "send_request sends via POST response stream even with GET SSE connected" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Connect GET SSE.
          get_io = StringIO.new
          get_request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          get_response = @transport.handle_request(get_request)
          get_response[2].call(get_io) if get_response[2].is_a?(Proc)
          sleep(0.1)

          # Set up sampling capability for the session.
          @transport.instance_variable_get(:@sessions)[session_id][:server_session]
            .store_client_info(client: { name: "test" }, capabilities: { sampling: {} })

          # Define a tool that calls create_sampling_message.
          sampling_tool = MCP::Tool.define(
            name: "sampling_tool",
            input_schema: { properties: { prompt: { type: "string" } }, required: ["prompt"] },
          ) do |prompt:, server_context:|
            result = server_context.create_sampling_message(
              messages: [{ role: "user", content: { type: "text", text: prompt } }],
              max_tokens: 100,
            )
            MCP::Tool::Response.new([{ type: "text", text: result[:content][:text] }])
          end
          @server.tools[sampling_tool.name_value] = sampling_tool

          # Send tools/call via POST (GET SSE is connected).
          tool_request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            {
              jsonrpc: "2.0",
              id: "tool-1",
              method: "tools/call",
              params: { name: "sampling_tool", arguments: { prompt: "Hello" } },
            }.to_json,
          )

          post_stream = TestStream.new
          result_queue = Queue.new
          Thread.new do
            response = @transport.handle_request(tool_request)
            response[2].call(post_stream)
            result_queue.push(:done)
          end

          sleep(0.2)

          # Sampling request should be in POST response stream, not GET SSE.
          output = post_stream.string
          data_lines = output.lines.select { |line| line.start_with?("data: ") }
          sampling_request = JSON.parse(data_lines.first.sub("data: ", ""))
          assert_equal "sampling/createMessage", sampling_request["method"]

          # GET SSE should NOT have the sampling request.
          get_io.rewind
          refute_includes get_io.read, "sampling/createMessage"

          # Simulate client sending sampling result via POST.
          client_response = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            {
              jsonrpc: "2.0",
              id: sampling_request["id"],
              result: { role: "assistant", content: { type: "text", text: "Hi from LLM" } },
            }.to_json,
          )
          @transport.handle_request(client_response)

          result_queue.pop

          tool_response_lines = post_stream.string.lines.select { |line| line.start_with?("data: ") }
          tool_response = JSON.parse(tool_response_lines.last.sub("data: ", ""))
          assert_equal "tool-1", tool_response["id"]
          assert_includes tool_response["result"]["content"].first["text"], "Hi from LLM"
        end

        test "send_request sends via POST response stream when no GET SSE stream" do
          # Create session without connecting GET SSE.
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Set up sampling capability for the session.
          @transport.instance_variable_get(:@sessions)[session_id][:server_session]
            .store_client_info(client: { name: "test" }, capabilities: { sampling: {} })

          # Define a tool that calls create_sampling_message.
          sampling_tool = MCP::Tool.define(
            name: "sampling_tool",
            input_schema: { properties: { prompt: { type: "string" } }, required: ["prompt"] },
          ) do |prompt:, server_context:|
            result = server_context.create_sampling_message(
              messages: [{ role: "user", content: { type: "text", text: prompt } }],
              max_tokens: 100,
            )
            MCP::Tool::Response.new([{ type: "text", text: result[:content][:text] }])
          end
          @server.tools[sampling_tool.name_value] = sampling_tool

          # Send tools/call via POST (no GET SSE stream).
          tool_request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            {
              jsonrpc: "2.0",
              id: "tool-1",
              method: "tools/call",
              params: { name: "sampling_tool", arguments: { prompt: "Hello" } },
            }.to_json,
          )

          # Process in background since handle_request blocks until tool completes.
          post_stream = TestStream.new
          result_queue = Queue.new
          Thread.new do
            response = @transport.handle_request(tool_request)
            response[2].call(post_stream)
            result_queue.push(:done)
          end

          sleep(0.2) # Wait for the tool to start and send sampling request.

          # Read the sampling request from the POST response stream.
          output = post_stream.string
          data_lines = output.lines.select { |line| line.start_with?("data: ") }
          sampling_request = JSON.parse(data_lines.first.sub("data: ", ""))
          assert_equal "sampling/createMessage", sampling_request["method"]

          # Simulate client sending sampling result via POST.
          client_response = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            {
              jsonrpc: "2.0",
              id: sampling_request["id"],
              result: { role: "assistant", content: { type: "text", text: "Hi from LLM" } },
            }.to_json,
          )
          @transport.handle_request(client_response)

          result_queue.pop # Wait for tool to complete.

          # Verify the tool result was written to the POST response stream.
          tool_response_lines = post_stream.string.lines.select { |line| line.start_with?("data: ") }
          tool_response = JSON.parse(tool_response_lines.last.sub("data: ", ""))
          assert_equal "tool-1", tool_response["id"]
          assert_includes tool_response["result"]["content"].first["text"], "Hi from LLM"
        end

        test "send_notification uses POST response stream when no GET SSE stream" do
          # Create session without connecting GET SSE.
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Define a tool that sends a notification during execution.
          notification_sent = Queue.new
          slow_tool = MCP::Tool.define(
            name: "slow_tool",
          ) do |server_context:|
            server_context.notify_log_message(data: "test log", level: "info")
            notification_sent.push(true)
            MCP::Tool::Response.new([{ type: "text", text: "done" }])
          end
          @server.tools[slow_tool.name_value] = slow_tool

          # Configure logging so notifications are sent.
          @transport.instance_variable_get(:@sessions)[session_id][:server_session]
            .configure_logging(MCP::LoggingMessageNotification.new(level: "debug"))

          # Send tools/call via POST (no GET SSE stream).
          post_stream = TestStream.new
          result_queue = Queue.new
          Thread.new do
            request = create_rack_request(
              "POST",
              "/",
              {
                "CONTENT_TYPE" => "application/json",
                "HTTP_MCP_SESSION_ID" => session_id,
              },
              {
                jsonrpc: "2.0",
                id: "tool-1",
                method: "tools/call",
                params: { name: "slow_tool", arguments: {} },
              }.to_json,
            )
            response = @transport.handle_request(request)
            response[2].call(post_stream)
            result_queue.push(:done)
          end

          notification_sent.pop # Wait for tool to send notification.
          result_queue.pop

          # Verify notification was written to the POST response stream.
          assert_includes post_stream.string, "notifications/message"
          assert_includes post_stream.string, "test log"
        end

        test "progress notification uses POST response stream when no GET SSE stream" do
          # Create session without connecting GET SSE.
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Define a tool that reports progress during execution.
          progress_reported = Queue.new
          progress_tool = MCP::Tool.define(
            name: "progress_tool",
          ) do |server_context:|
            server_context.report_progress(50, total: 100, message: "halfway")
            progress_reported.push(true)
            MCP::Tool::Response.new([{ type: "text", text: "done" }])
          end
          @server.tools[progress_tool.name_value] = progress_tool

          # Send tools/call via POST (no GET SSE stream) with a progress token.
          post_stream = TestStream.new
          result_queue = Queue.new
          Thread.new do
            request = create_rack_request(
              "POST",
              "/",
              {
                "CONTENT_TYPE" => "application/json",
                "HTTP_MCP_SESSION_ID" => session_id,
              },
              {
                jsonrpc: "2.0",
                id: "tool-1",
                method: "tools/call",
                params: { name: "progress_tool", arguments: {}, _meta: { progressToken: "token-1" } },
              }.to_json,
            )
            response = @transport.handle_request(request)
            response[2].call(post_stream)
            result_queue.push(:done)
          end

          progress_reported.pop
          result_queue.pop

          # Verify progress notification was written to the POST response stream.
          assert_includes post_stream.string, "notifications/progress"
          assert_includes post_stream.string, "token-1"
        end

        test "POST notifications/initialized returns 202 with no body" do
          # Create a session first (optional for notification, but keep consistent with flow)
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          notif_request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            { jsonrpc: "2.0", method: MCP::Methods::NOTIFICATIONS_INITIALIZED }.to_json,
          )

          response = @transport.handle_request(notif_request)
          assert_equal 202, response[0]
          assert_equal({}, response[1])
          assert_equal([], response[2])
        end

        test "expired session returns 404 on GET request" do
          transport = StreamableHTTPTransport.new(@server, session_idle_timeout: 0.01)

          # Create a session
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123", params: initialize_params }.to_json,
          )
          init_response = transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]
          assert(session_id)

          # Session should now be expired (timeout is 0)
          sleep(0.01)

          get_request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          response = transport.handle_request(get_request)
          assert_equal(404, response[0])

          body = JSON.parse(response[2][0])
          assert_equal("Session not found", body["error"]["message"])
        ensure
          transport.close
        end

        test "expired session returns 404 on POST request" do
          transport = StreamableHTTPTransport.new(@server, session_idle_timeout: 0.01)

          # Create a session
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Session should now be expired (timeout is 0)
          sleep(0.01)

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            { jsonrpc: "2.0", method: "ping", id: "456" }.to_json,
          )

          response = transport.handle_request(request)
          assert_equal(404, response[0])

          body = JSON.parse(response[2][0])
          assert_equal("Session not found", body["error"]["message"])
        ensure
          transport.close
        end

        test "session_idle_timeout: nil disables session expiry" do
          transport = StreamableHTTPTransport.new(@server, session_idle_timeout: nil)

          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Make a request - session should still be valid
          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            { jsonrpc: "2.0", method: "ping", id: "456" }.to_json,
          )

          response = transport.handle_request(request)
          assert_equal(200, response[0])
        ensure
          transport.close
        end

        test "session within timeout period remains valid" do
          transport = StreamableHTTPTransport.new(@server, session_idle_timeout: 3600)

          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            { jsonrpc: "2.0", method: "ping", id: "456" }.to_json,
          )

          response = transport.handle_request(request)
          assert_equal(200, response[0])
        ensure
          transport.close
        end

        test "session activity resets the idle timeout" do
          transport = StreamableHTTPTransport.new(@server, session_idle_timeout: 0.5)

          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Send requests every 0.2s to keep the session alive.
          # Total elapsed time (~0.6s) exceeds timeout (0.5s), but each request
          # resets the idle timer so the session remains valid.
          3.times do
            sleep(0.2)
            request = create_rack_request(
              "POST",
              "/",
              {
                "CONTENT_TYPE" => "application/json",
                "HTTP_MCP_SESSION_ID" => session_id,
              },
              { jsonrpc: "2.0", method: "ping", id: "456" }.to_json,
            )
            response = transport.handle_request(request)
            assert_equal(200, response[0])
          end
        ensure
          transport.close
        end

        test "reaper thread cleans up expired sessions" do
          transport = StreamableHTTPTransport.new(@server, session_idle_timeout: 0.01)

          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]
          assert(session_id)

          # Wait for session to expire
          sleep(0.02)

          # Manually trigger reaper since the background thread runs on 60s interval
          transport.send(:reap_expired_sessions)

          # Session should have been reaped
          get_request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          response = transport.handle_request(get_request)
          assert_equal(404, response[0])
        ensure
          transport.close
        end

        test "reaper thread cleans up expired sessions and POST returns 404" do
          transport = StreamableHTTPTransport.new(@server, session_idle_timeout: 0.01)

          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Wait for the session to exceed the idle timeout (0.01s)
          sleep(0.02)
          transport.send(:reap_expired_sessions)

          # POST to a reaped session should also return 404
          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            { jsonrpc: "2.0", method: "ping", id: "456" }.to_json,
          )
          response = transport.handle_request(request)
          assert_equal(404, response[0])

          body = JSON.parse(response[2][0])
          assert_equal("Session not found", body["error"]["message"])
        ensure
          transport.close
        end

        test "reap_expired_sessions closes stream outside mutex" do
          transport = StreamableHTTPTransport.new(@server, session_idle_timeout: 0.01)

          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Replace the stream with one that verifies mutex is NOT held during close.
          mutex = transport.instance_variable_get(:@mutex)
          closed_outside_mutex = false
          mock_stream = Object.new
          mock_stream.define_singleton_method(:close) do
            # If stream.close runs outside the mutex, try_lock succeeds.
            if mutex.try_lock
              closed_outside_mutex = true
              mutex.unlock
            end
          end
          transport.instance_variable_get(:@sessions)[session_id][:get_sse_stream] = mock_stream

          sleep(0.02) # Wait for session to expire.

          transport.send(:reap_expired_sessions)

          assert(closed_outside_mutex, "Stream should be closed outside the mutex")
          assert_empty(transport.instance_variable_get(:@sessions))
        ensure
          transport.close
        end

        test "close stops the reaper thread" do
          transport = StreamableHTTPTransport.new(@server, session_idle_timeout: 3600)
          reaper_thread = transport.instance_variable_get(:@reaper_thread)
          assert reaper_thread
          assert reaper_thread.alive?

          transport.close

          sleep(0.01)
          refute reaper_thread.alive?
          assert_nil transport.instance_variable_get(:@reaper_thread)
        end

        test "reaper thread is not started when session_idle_timeout is nil" do
          transport = StreamableHTTPTransport.new(@server, session_idle_timeout: nil)
          assert_nil(transport.instance_variable_get(:@reaper_thread))
        ensure
          transport.close
        end

        test "applies a finite session_idle_timeout by default and starts the reaper" do
          # Secure default: stateful mode expires idle sessions out of the box.
          transport = StreamableHTTPTransport.new(@server)
          assert_equal(
            StreamableHTTPTransport::DEFAULT_SESSION_IDLE_TIMEOUT,
            transport.instance_variable_get(:@session_idle_timeout),
          )
          assert(transport.instance_variable_get(:@reaper_thread).alive?)

          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          # A freshly created session is well within the timeout, so normal use is unaffected.
          session_id = transport.handle_request(init_request)[1]["Mcp-Session-Id"]
          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "HTTP_MCP_SESSION_ID" => session_id },
            { jsonrpc: "2.0", method: "ping", id: "456" }.to_json,
          )

          assert_equal(200, transport.handle_request(request)[0])
        ensure
          transport.close
        end

        test "session_idle_timeout: nil opts out of expiry" do
          transport = StreamableHTTPTransport.new(@server, session_idle_timeout: nil)
          assert_nil(transport.instance_variable_get(:@session_idle_timeout))
          assert_nil(transport.instance_variable_get(:@reaper_thread))
        ensure
          transport.close
        end

        test "stateless mode keeps no idle timeout despite the secure default" do
          transport = StreamableHTTPTransport.new(@server, stateless: true)
          assert_nil(transport.instance_variable_get(:@session_idle_timeout))
          assert_nil(transport.instance_variable_get(:@reaper_thread))
        ensure
          transport.close
        end

        test "rejects new initialize with 503 once max_sessions is reached" do
          transport = StreamableHTTPTransport.new(@server, max_sessions: 2)

          2.times do
            request = create_rack_request(
              "POST",
              "/",
              { "CONTENT_TYPE" => "application/json" },
              { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
            )
            assert_equal(200, transport.handle_request(request)[0])
          end

          overflow = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          response = transport.handle_request(overflow)

          assert_equal(503, response[0])
          assert_equal(2, transport.instance_variable_get(:@sessions).size)
        ensure
          transport.close
        end

        test "at the cap, reclaims an already-expired session before rejecting" do
          # A very short idle timeout so the first session is expired by the time the cap would otherwise reject
          # a new initialize; the expired slot is reclaimed.
          transport = StreamableHTTPTransport.new(@server, max_sessions: 1, session_idle_timeout: 0.01)
          init = lambda do
            transport.handle_request(create_rack_request(
              "POST",
              "/",
              { "CONTENT_TYPE" => "application/json" },
              { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
            ))
          end

          assert_equal(200, init.call[0])
          sleep(0.05) # let the first session's idle timer expire
          second = init.call

          # The expired session was reclaimed in-line, so the second initialize succeeds (200) rather than
          # being rejected with 503, and the store stays at the cap.
          assert_equal(200, second[0])
          assert_equal(1, transport.instance_variable_get(:@sessions).size)
        ensure
          transport.close
        end

        test "max_sessions: nil opts out of the session cap" do
          transport = StreamableHTTPTransport.new(@server, max_sessions: nil)
          assert_nil(transport.instance_variable_get(:@max_sessions))
        ensure
          transport.close
        end

        test "raises ArgumentError for an invalid max_sessions" do
          [0, -1, 1.5, "10"].each do |invalid|
            assert_raises(ArgumentError) { StreamableHTTPTransport.new(@server, max_sessions: invalid) }
          end
        end

        test "raises ArgumentError when session_idle_timeout is zero" do
          error = assert_raises(ArgumentError) do
            StreamableHTTPTransport.new(@server, session_idle_timeout: 0)
          end
          assert_equal("session_idle_timeout must be a positive number.", error.message)
        end

        test "raises ArgumentError when session_idle_timeout is negative" do
          error = assert_raises(ArgumentError) do
            StreamableHTTPTransport.new(@server, session_idle_timeout: -1)
          end
          assert_equal("session_idle_timeout must be a positive number.", error.message)
        end

        test "raises ArgumentError when session_idle_timeout is used with stateless mode" do
          error = assert_raises(ArgumentError) do
            StreamableHTTPTransport.new(@server, stateless: true, session_idle_timeout: 3600)
          end
          assert_equal("session_idle_timeout is not supported in stateless mode.", error.message)
        end

        test "expired session does not receive targeted notification" do
          transport = StreamableHTTPTransport.new(@server, session_idle_timeout: 0.01)

          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Wait for the session to exceed the idle timeout (0.01s)
          sleep(0.02)

          result = transport.send_notification("test/notify", { message: "hello" }, session_id: session_id)
          refute(result)
        ensure
          transport.close
        end

        test "expired session is skipped during broadcast notification" do
          transport = StreamableHTTPTransport.new(@server, session_idle_timeout: 0.01)

          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Attach a mock stream to the session
          stream = StringIO.new
          transport.instance_variable_get(:@sessions)[session_id][:get_sse_stream] = stream

          # Wait for the session to exceed the idle timeout (0.01s)
          sleep(0.02)

          sent_count = transport.send_notification("test/notify", { message: "hello" }, **{})
          assert_equal(0, sent_count)
        ensure
          transport.close
        end

        test "handles POST request with body including JSON-RPC response object and returns with no body" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            { jsonrpc: "2.0", result: "success", id: "123" }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 202, response[0]
          assert_equal({}, response[1])
          assert_equal([], response[2])
        end

        test "POST response without session ID returns 400" do
          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", result: "success", id: "123" }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 400, response[0]
          body = JSON.parse(response[2][0])
          assert_equal "Missing session ID", body["error"]["message"]
        end

        test "POST response with invalid session ID returns 404" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          @transport.handle_request(init_request)

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => "invalid-session-id",
            },
            { jsonrpc: "2.0", result: "success", id: "123" }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 404, response[0]
          body = JSON.parse(response[2][0])
          assert_equal "Session not found", body["error"]["message"]
        end

        test "handle_regular_request returns 404 for unknown session_id" do
          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => "nonexistent-session",
            },
            { jsonrpc: "2.0", method: "ping", id: "456" }.to_json,
          )
          response = @transport.handle_request(request)
          assert_equal(404, response[0])
          body = JSON.parse(response[2][0])
          assert_equal("Session not found", body["error"]["message"])
        end

        test "session-scoped log notification is sent only to the originating session" do
          server = Server.new(name: "test", tools: [], prompts: [], resources: [])
          server.logging_message_notification = MCP::LoggingMessageNotification.new(level: "debug")
          transport = StreamableHTTPTransport.new(server)

          server.define_tool(name: "log_tool") do |server_context:|
            server_context.notify_log_message(data: "secret", level: "info")
            Tool::Response.new([{ type: "text", text: "ok" }])
          end
          server.server_context = server

          # Create two sessions.
          init1 = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            {
              jsonrpc: "2.0",
              method: "initialize",
              id: "1",
              params: initialize_params(clientInfo: { name: "a", version: "1.0" }),
            }.to_json,
          )
          session1 = transport.handle_request(init1)[1]["Mcp-Session-Id"]

          init2 = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            {
              jsonrpc: "2.0",
              method: "initialize",
              id: "2",
              params: initialize_params(clientInfo: { name: "b", version: "1.0" }),
            }.to_json,
          )
          session2 = transport.handle_request(init2)[1]["Mcp-Session-Id"]

          # Connect SSE for both sessions.
          io1 = StringIO.new
          get1 = create_rack_request("GET", "/", { "HTTP_MCP_SESSION_ID" => session1 })
          response1 = transport.handle_request(get1)
          response1[2].call(io1) if response1[2].is_a?(Proc)

          io2 = StringIO.new
          get2 = create_rack_request("GET", "/", { "HTTP_MCP_SESSION_ID" => session2 })
          response2 = transport.handle_request(get2)
          response2[2].call(io2) if response2[2].is_a?(Proc)

          sleep(0.1)

          # Call tool from session 1.
          tool_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "HTTP_MCP_SESSION_ID" => session1 },
            {
              jsonrpc: "2.0",
              method: "tools/call",
              id: "call-1",
              params: { name: "log_tool", arguments: {} },
            }.to_json,
          )
          tool_response = transport.handle_request(tool_request)
          post_io = StringIO.new
          tool_response[2].call(post_io)

          # Session 1's POST response stream should contain the log notification.
          assert_includes post_io.string, "secret"

          # GET SSE streams should NOT receive the log notification.
          io1.rewind
          refute_includes io1.read, "secret"
          io2.rewind
          refute_includes io2.read, "secret"
        end

        test "session-scoped progress notification is sent only to the originating session" do
          server = Server.new(name: "test", tools: [], prompts: [], resources: [])
          transport = StreamableHTTPTransport.new(server)

          server.define_tool(name: "progress_tool") do |server_context:|
            server_context.report_progress(50, total: 100, message: "halfway")
            Tool::Response.new([{ type: "text", text: "ok" }])
          end
          server.server_context = server

          # Create two sessions.
          init1 = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            {
              jsonrpc: "2.0",
              method: "initialize",
              id: "1",
              params: initialize_params(clientInfo: { name: "a", version: "1.0" }),
            }.to_json,
          )
          session1 = transport.handle_request(init1)[1]["Mcp-Session-Id"]

          init2 = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            {
              jsonrpc: "2.0",
              method: "initialize",
              id: "2",
              params: initialize_params(clientInfo: { name: "b", version: "1.0" }),
            }.to_json,
          )
          session2 = transport.handle_request(init2)[1]["Mcp-Session-Id"]

          # Connect SSE for both sessions.
          io1 = StringIO.new
          get1 = create_rack_request("GET", "/", { "HTTP_MCP_SESSION_ID" => session1 })
          response1 = transport.handle_request(get1)
          response1[2].call(io1) if response1[2].is_a?(Proc)

          io2 = StringIO.new
          get2 = create_rack_request("GET", "/", { "HTTP_MCP_SESSION_ID" => session2 })
          response2 = transport.handle_request(get2)
          response2[2].call(io2) if response2[2].is_a?(Proc)

          sleep(0.1)

          # Call tool from session 1 with a progress token.
          tool_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "HTTP_MCP_SESSION_ID" => session1 },
            {
              jsonrpc: "2.0",
              method: "tools/call",
              id: "call-1",
              params: {
                name: "progress_tool",
                arguments: {},
                _meta: { progressToken: "token-1" },
              },
            }.to_json,
          )
          tool_response = transport.handle_request(tool_request)
          post_io = StringIO.new
          tool_response[2].call(post_io)

          # Session 1's POST response stream should contain the progress notification.
          assert_includes post_io.string, "halfway"

          # GET SSE streams should NOT receive the progress notification.
          io1.rewind
          refute_includes io1.read, "halfway"
          io2.rewind
          refute_includes io2.read, "halfway"
        end

        test "each session stores its own client info independently" do
          server = Server.new(name: "test", tools: [], prompts: [], resources: [])
          transport = StreamableHTTPTransport.new(server)

          # Initialize session 1 with client "alpha".
          init1 = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            {
              jsonrpc: "2.0",
              method: "initialize",
              id: "1",
              params: initialize_params(clientInfo: { name: "alpha", version: "1.0" }),
            }.to_json,
          )
          session1 = transport.handle_request(init1)[1]["Mcp-Session-Id"]

          # Initialize session 2 with client "beta".
          init2 = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            {
              jsonrpc: "2.0",
              method: "initialize",
              id: "2",
              params: initialize_params(clientInfo: { name: "beta", version: "2.0" }),
            }.to_json,
          )
          session2 = transport.handle_request(init2)[1]["Mcp-Session-Id"]

          # Each session should have its own client info.
          sessions = transport.instance_variable_get(:@sessions)
          assert_equal({ name: "alpha", version: "1.0" }, sessions[session1][:server_session].client)
          assert_equal({ name: "beta", version: "2.0" }, sessions[session2][:server_session].client)
        end

        test "each session stores its own logging level independently" do
          server = Server.new(name: "test", tools: [], prompts: [], resources: [])
          transport = StreamableHTTPTransport.new(server)

          # Initialize two sessions.
          init1 = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            {
              jsonrpc: "2.0",
              method: "initialize",
              id: "1",
              params: initialize_params(clientInfo: { name: "a", version: "1.0" }),
            }.to_json,
          )
          session1 = transport.handle_request(init1)[1]["Mcp-Session-Id"]

          init2 = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            {
              jsonrpc: "2.0",
              method: "initialize",
              id: "2",
              params: initialize_params(clientInfo: { name: "b", version: "1.0" }),
            }.to_json,
          )
          session2 = transport.handle_request(init2)[1]["Mcp-Session-Id"]

          # Session 1 sets log level to "error".
          set_level1 = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "HTTP_MCP_SESSION_ID" => session1 },
            {
              jsonrpc: "2.0",
              method: "logging/setLevel",
              id: "3",
              params: { level: "error" },
            }.to_json,
          )
          response1 = transport.handle_request(set_level1)
          response1[2].call(StringIO.new)

          # Session 2 sets log level to "debug".
          set_level2 = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "HTTP_MCP_SESSION_ID" => session2 },
            {
              jsonrpc: "2.0",
              method: "logging/setLevel",
              id: "4",
              params: { level: "debug" },
            }.to_json,
          )
          response2 = transport.handle_request(set_level2)
          response2[2].call(StringIO.new)

          # Session 1 (error level) should not notify for "info", but should for "error".
          session1_logging = transport.instance_variable_get(:@sessions)[session1][:server_session].logging_message_notification
          refute session1_logging.should_notify?("info")
          assert session1_logging.should_notify?("error")

          # Session 2 (debug level) should notify for both "info" and "debug".
          session2_logging = transport.instance_variable_get(:@sessions)[session2][:server_session].logging_message_notification
          assert session2_logging.should_notify?("info")
          assert session2_logging.should_notify?("debug")
        end

        test "call(env) works as a Rack app for POST requests" do
          env = {
            "REQUEST_METHOD" => "POST",
            "PATH_INFO" => "/",
            "rack.input" => StringIO.new({ jsonrpc: "2.0", method: "initialize", id: "init-1", params: initialize_params }.to_json),
            "CONTENT_TYPE" => "application/json",
            "HTTP_ACCEPT" => "application/json, text/event-stream",
          }

          response = @transport.call(env)
          assert_equal 200, response[0]
          assert_equal "application/json", response[1]["Content-Type"]

          body = JSON.parse(response[2][0])
          assert_equal "2.0", body["jsonrpc"]
          assert_equal "init-1", body["id"]
        end

        test "call(env) returns 405 for unsupported HTTP methods" do
          env = {
            "REQUEST_METHOD" => "PUT",
            "PATH_INFO" => "/",
            "rack.input" => StringIO.new(""),
          }

          response = @transport.call(env)
          assert_equal 405, response[0]
        end

        test "call(env) handles GET SSE stream request" do
          init_env = {
            "REQUEST_METHOD" => "POST",
            "PATH_INFO" => "/",
            "rack.input" => StringIO.new({ jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json),
            "CONTENT_TYPE" => "application/json",
            "HTTP_ACCEPT" => "application/json, text/event-stream",
          }
          init_response = @transport.call(init_env)
          session_id = init_response[1]["Mcp-Session-Id"]

          get_env = {
            "REQUEST_METHOD" => "GET",
            "PATH_INFO" => "/",
            "rack.input" => StringIO.new(""),
            "HTTP_ACCEPT" => "text/event-stream",
            "HTTP_MCP_SESSION_ID" => session_id,
          }

          response = @transport.call(get_env)
          assert_equal 200, response[0]
          assert_equal "text/event-stream", response[1]["Content-Type"]
          assert response[2].is_a?(Proc)
        end

        test "call(env) handles DELETE session request" do
          init_env = {
            "REQUEST_METHOD" => "POST",
            "PATH_INFO" => "/",
            "rack.input" => StringIO.new({ jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json),
            "CONTENT_TYPE" => "application/json",
            "HTTP_ACCEPT" => "application/json, text/event-stream",
          }
          init_response = @transport.call(init_env)
          session_id = init_response[1]["Mcp-Session-Id"]

          delete_env = {
            "REQUEST_METHOD" => "DELETE",
            "PATH_INFO" => "/",
            "rack.input" => StringIO.new(""),
            "HTTP_MCP_SESSION_ID" => session_id,
          }

          response = @transport.call(delete_env)
          assert_equal 200, response[0]

          body = JSON.parse(response[2][0])
          assert body["success"]
        end

        test "SSE response headers are not frozen so Rack middleware can modify them" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init-frozen", params: initialize_params }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "HTTP_MCP_SESSION_ID" => session_id },
            { jsonrpc: "2.0", method: "tools/list", id: "sse-headers-1" }.to_json,
          )

          status, headers, = @transport.handle_request(request)
          assert_equal 200, status
          assert_equal "text/event-stream", headers["Content-Type"]
          refute headers.frozen?, "SSE response headers should not be frozen"
        end

        test "rejects a request body over max_request_bytes with 413 without reading it all" do
          transport = StreamableHTTPTransport.new(@server, max_request_bytes: 1024)
          oversized = { jsonrpc: "2.0", method: "initialize", id: "1", params: { x: "A" * 4096 } }.to_json

          # Content-Length present: rejected before reading.
          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "CONTENT_LENGTH" => oversized.bytesize.to_s },
            oversized,
          )
          response = transport.handle_request(request)

          assert_equal 413, response[0]
          assert_equal JsonRpcHandler::ErrorCode::INVALID_REQUEST, JSON.parse(response[2][0]).dig("error", "code")
        end

        test "rejects an oversized body even when Content-Length is absent" do
          transport = StreamableHTTPTransport.new(@server, max_request_bytes: 1024)
          oversized = { jsonrpc: "2.0", method: "initialize", id: "1", params: { x: "A" * 4096 } }.to_json

          # No CONTENT_LENGTH: the bounded read must still catch it.
          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            oversized,
          )
          response = transport.handle_request(request)

          assert_equal 413, response[0]
        end

        test "accepts a request body at the max_request_bytes boundary" do
          transport = StreamableHTTPTransport.new(@server, max_request_bytes: 4096)
          body = { jsonrpc: "2.0", method: "initialize", id: "1", params: initialize_params }.to_json
          assert_operator body.bytesize, :<=, 4096

          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            body,
          )
          response = transport.handle_request(request)

          assert_equal 200, response[0]
        end

        test "rejects deeply nested JSON beyond the nesting cap as a parse error" do
          depth = StreamableHTTPTransport::MAX_JSON_NESTING + 5
          nested = ("[" * depth) + ("]" * depth)
          body = %({"jsonrpc":"2.0","method":"initialize","id":"1","params":{"deep":#{nested}}})

          request = create_rack_request("POST", "/", { "CONTENT_TYPE" => "application/json" }, body)
          response = @transport.handle_request(request)

          assert_equal 400, response[0]
          assert_equal JsonRpcHandler::ErrorCode::PARSE_ERROR, JSON.parse(response[2][0]).dig("error", "code")
        end

        test "raises ArgumentError for an invalid max_request_bytes" do
          [nil, 0, -1, 1.5, "1024"].each do |invalid|
            assert_raises(ArgumentError) { StreamableHTTPTransport.new(@server, max_request_bytes: invalid) }
          end
        end

        test "handle_request returns 403 for POST when Origin is not in allowed_origins" do
          transport = StreamableHTTPTransport.new(@server, allowed_origins: ["https://app.example.com"])

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_ORIGIN" => "https://evil.example.com",
            },
            { jsonrpc: "2.0", method: "ping", id: "1" }.to_json,
          )

          status, headers, body = transport.handle_request(request)
          assert_equal(403, status)
          assert_equal("application/json", headers["Content-Type"])
          parsed = JSON.parse(body.first)
          assert_equal(JsonRpcHandler::ErrorCode::INVALID_REQUEST, parsed["error"]["code"])
          assert_equal("Forbidden: Invalid Origin header", parsed["error"]["message"])
        ensure
          transport&.close
        end

        test "handle_request returns 403 for GET when Origin is not in allowed_origins" do
          transport = StreamableHTTPTransport.new(@server, allowed_origins: ["https://app.example.com"])

          request = create_rack_request(
            "GET",
            "/",
            { "HTTP_ORIGIN" => "https://evil.example.com" },
          )

          status, = transport.handle_request(request)
          assert_equal(403, status)
        ensure
          transport&.close
        end

        test "handle_request returns 403 for DELETE when Origin is not in allowed_origins" do
          transport = StreamableHTTPTransport.new(@server, allowed_origins: ["https://app.example.com"])

          request = create_rack_request(
            "DELETE",
            "/",
            {
              "HTTP_ORIGIN" => "https://evil.example.com",
              "HTTP_MCP_SESSION_ID" => "any",
            },
          )

          status, = transport.handle_request(request)
          assert_equal(403, status)
        ensure
          transport&.close
        end

        test "handle_request allows POST when Origin is in allowed_origins" do
          transport = StreamableHTTPTransport.new(@server, allowed_origins: ["https://app.example.com"])

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_ORIGIN" => "https://app.example.com",
            },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )

          status, = transport.handle_request(request)
          assert_equal(200, status)
        ensure
          transport&.close
        end

        test "handle_request allows POST when Origin header is absent (e.g. non-browser client)" do
          transport = StreamableHTTPTransport.new(@server, allowed_origins: ["https://app.example.com"])

          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )

          status, = transport.handle_request(request)
          assert_equal(200, status)
        ensure
          transport&.close
        end

        test "handle_request rejects a cross-origin request by default (secure-by-default)" do
          # No allowed_origins configured: a browser cross-origin Origin is still rejected.
          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_ORIGIN" => "https://anywhere.example.com",
            },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )

          status, = @transport.handle_request(request)
          assert_equal 403, status
        end

        test "handle_request allows a same-origin browser request" do
          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_HOST" => "localhost:3000",
              "HTTP_ORIGIN" => "http://localhost:3000",
            },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )

          status, = @transport.handle_request(request)
          assert_equal 200, status
        end

        test "handle_request rejects a rebound Host by default" do
          # DNS rebinding: a foreign Host re-pointed at the loopback server is rejected.
          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_HOST" => "evil.example.com",
            },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )

          status, headers, body = @transport.handle_request(request)
          assert_equal(403, status)
          assert_equal("application/json", headers["Content-Type"])
          parsed = JSON.parse(body.first)
          assert_equal(JsonRpcHandler::ErrorCode::INVALID_REQUEST, parsed["error"]["code"])
          assert_equal("Forbidden: Invalid Host header", parsed["error"]["message"])
        end

        test "handle_request allows loopback Host values by default" do
          ["127.0.0.1:8080", "localhost:3000", "[::1]:8080"].each do |host|
            transport = StreamableHTTPTransport.new(@server)
            request = create_rack_request(
              "POST",
              "/",
              {
                "CONTENT_TYPE" => "application/json",
                "HTTP_HOST" => host,
              },
              { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
            )

            status, = transport.handle_request(request)
            assert_equal(200, status, "expected #{host} to be allowed")
          ensure
            transport.close
          end
        end

        test "handle_request matches Host case-insensitively" do
          # Host names are case-insensitive, so an upper-cased loopback Host is allowed.
          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_HOST" => "LOCALHOST:3000",
            },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )

          status, = @transport.handle_request(request)
          assert_equal(200, status)
        end

        test "handle_request allows a non-loopback Host listed in allowed_hosts" do
          transport = StreamableHTTPTransport.new(@server, allowed_hosts: ["app.example.com"])

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_HOST" => "app.example.com",
            },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )

          status, = transport.handle_request(request)
          assert_equal(200, status)
        ensure
          transport.close
        end

        test "handle_request matches a host:port entry in allowed_hosts exactly" do
          transport = StreamableHTTPTransport.new(@server, allowed_hosts: ["app.example.com:8443"])

          allowed = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "HTTP_HOST" => "app.example.com:8443" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          rejected = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "HTTP_HOST" => "app.example.com:9000" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )

          assert_equal(200, transport.handle_request(allowed).first)
          assert_equal(403, transport.handle_request(rejected).first)
        ensure
          transport.close
        end

        test "handle_request treats a default port as same-origin" do
          # `Origin: http://localhost` (no port) is same-origin with `Host: localhost:80`.
          [
            ["http://localhost", "localhost:80"],
            ["https://localhost", "localhost:443"],
          ].each do |origin, host|
            transport = StreamableHTTPTransport.new(@server)
            request = create_rack_request(
              "POST",
              "/",
              { "CONTENT_TYPE" => "application/json", "HTTP_HOST" => host, "HTTP_ORIGIN" => origin },
              { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
            )

            assert_equal(200, transport.handle_request(request).first, "expected #{origin} / #{host} to match")
          ensure
            transport.close
          end
        end

        test "handle_request rejects opaque and malformed Origins" do
          ["null", "file:///etc/passwd", "http://localhost:3000/path"].each do |origin|
            transport = StreamableHTTPTransport.new(@server)
            request = create_rack_request(
              "POST",
              "/",
              { "CONTENT_TYPE" => "application/json", "HTTP_HOST" => "localhost:3000", "HTTP_ORIGIN" => origin },
              { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
            )

            assert_equal(403, transport.handle_request(request).first, "expected #{origin} to be rejected")
          ensure
            transport.close
          end
        end

        test "handle_request enforces Host validation on GET requests" do
          request = create_rack_request(
            "GET",
            "/",
            { "HTTP_HOST" => "evil.example.com" },
          )

          status, = @transport.handle_request(request)
          assert_equal(403, status)
        end

        test "handle_request allows a request with no Host header" do
          # Non-browser clients may omit Host; the rebinding vector always carries one.
          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )

          status, = @transport.handle_request(request)
          assert_equal(200, status)
        end

        test "handle_request skips DNS rebinding checks when protection is disabled" do
          transport = StreamableHTTPTransport.new(@server, dns_rebinding_protection: false)

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_HOST" => "evil.example.com",
              "HTTP_ORIGIN" => "https://evil.example.com",
            },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )

          status, = transport.handle_request(request)
          assert_equal(200, status)
        ensure
          transport.close
        end

        test "rejects a POST to a session whose Origin differs from initialize with 403" do
          # Both origins are allow-listed so they pass DNS rebinding protection; the rejection
          # below comes from the per-session Origin-consistency gate, not from the rebinding check.
          transport = StreamableHTTPTransport.new(
            @server,
            enable_json_response: true,
            allowed_origins: ["https://app.example.com", "https://evil.example.com"],
          )
          init = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "HTTP_ORIGIN" => "https://app.example.com" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          session_id = transport.handle_request(init)[1]["Mcp-Session-Id"]

          attacker = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
              "HTTP_ORIGIN" => "https://evil.example.com",
            },
            { jsonrpc: "2.0", method: "ping", id: "1" }.to_json,
          )
          response = transport.handle_request(attacker)

          assert_equal(403, response[0])
        ensure
          transport.close
        end

        test "allows a POST with a matching Origin and one with no Origin" do
          transport = StreamableHTTPTransport.new(
            @server,
            enable_json_response: true,
            allowed_origins: ["https://app.example.com"],
          )
          init = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "HTTP_ORIGIN" => "https://app.example.com" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          session_id = transport.handle_request(init)[1]["Mcp-Session-Id"]

          same_origin = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
              "HTTP_ORIGIN" => "https://app.example.com",
            },
            { jsonrpc: "2.0", method: "ping", id: "1" }.to_json,
          )

          # A non-browser client that sends no Origin is not rejected by the built-in check.
          no_origin = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "HTTP_MCP_SESSION_ID" => session_id },
            { jsonrpc: "2.0", method: "ping", id: "2" }.to_json,
          )

          assert_equal(200, transport.handle_request(same_origin)[0])
          assert_equal(200, transport.handle_request(no_origin)[0])
        ensure
          transport.close
        end

        test "a custom session_request_validator rejects and allows requests" do
          allowed = { value: true }
          validator = ->(_request, _session_id) { allowed[:value] }
          transport = StreamableHTTPTransport.new(@server, enable_json_response: true, session_request_validator: validator)
          init = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          session_id = transport.handle_request(init)[1]["Mcp-Session-Id"]

          ping = lambda do
            create_rack_request(
              "POST",
              "/",
              { "CONTENT_TYPE" => "application/json", "HTTP_MCP_SESSION_ID" => session_id },
              { jsonrpc: "2.0", method: "ping", id: "1" }.to_json,
            )
          end

          assert_equal(200, transport.handle_request(ping.call)[0])
          allowed[:value] = false
          assert_equal(403, transport.handle_request(ping.call)[0])
        ensure
          transport.close
        end

        test "the validator also gates notification and response POSTs, not just regular requests" do
          # A stolen session ID must not be able to POST `notifications/cancelled` (which would cancel a victim's in-flight request)
          # or a client response by bypassing the ownership gate. `initialize` establishes the session and is exempt,
          # so a single transport whose validator always rejects still initializes.
          transport = StreamableHTTPTransport.new(
            @server,
            enable_json_response: true,
            session_request_validator: ->(_request, _session_id) { false },
          )
          init = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          session_id = transport.handle_request(init)[1]["Mcp-Session-Id"]
          refute_nil(session_id)

          headers = { "CONTENT_TYPE" => "application/json", "HTTP_MCP_SESSION_ID" => session_id }
          cancelled = create_rack_request(
            "POST",
            "/",
            headers,
            { jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: "1" } }.to_json,
          )
          client_response = create_rack_request(
            "POST",
            "/",
            headers,
            { jsonrpc: "2.0", id: "1", result: {} }.to_json,
          )

          assert_equal(403, transport.handle_request(cancelled)[0])
          assert_equal(403, transport.handle_request(client_response)[0])
        ensure
          transport.close
        end

        test "session_request_validator receives the request and session id" do
          seen = {}
          validator = ->(request, session_id) {
            seen[:origin] = request.env["HTTP_ORIGIN"]
            seen[:session_id] = session_id
            true
          }
          transport = StreamableHTTPTransport.new(
            @server,
            enable_json_response: true,
            allowed_origins: ["https://app.example.com"],
            session_request_validator: validator,
          )
          init = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          session_id = transport.handle_request(init)[1]["Mcp-Session-Id"]

          transport.handle_request(create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "HTTP_MCP_SESSION_ID" => session_id, "HTTP_ORIGIN" => "https://app.example.com" },
            { jsonrpc: "2.0", method: "ping", id: "1" }.to_json,
          ))

          assert_equal(session_id, seen[:session_id])
          assert_equal("https://app.example.com", seen[:origin])
        ensure
          transport.close
        end

        test "session validation does not apply in stateless mode" do
          rejecting = ->(_request, _session_id) { false }
          transport = StreamableHTTPTransport.new(@server, stateless: true, enable_json_response: true, session_request_validator: rejecting)

          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "ping", id: "1" }.to_json,
          )
          response = transport.handle_request(request)

          # Stateless mode keeps no sessions, so the validator is never consulted.
          assert_equal(200, response[0])
        ensure
          transport.close
        end

        private

        def initialize_test_session(id: "init")
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: id, params: initialize_params }.to_json,
          )
          @transport.handle_request(init_request)[1]["Mcp-Session-Id"]
        end

        # Installs a stream that records, on every write, whether `@mutex` was held at that moment.
        # `mutex.try_lock` fails while the transport still holds the lock, so a nonzero `writes[:under_mutex]`
        # means a blocking write is being performed under the lock.
        def install_mutex_probe_stream(session_id, related_request_id: nil)
          mutex = @transport.instance_variable_get(:@mutex)
          writes = { total: 0, under_mutex: 0 }
          stream = Object.new
          stream.define_singleton_method(:write) do |_data|
            writes[:total] += 1
            if mutex.try_lock
              mutex.unlock
            else
              writes[:under_mutex] += 1
            end
          end
          stream.define_singleton_method(:flush) {}
          stream.define_singleton_method(:close) {}

          session = @transport.instance_variable_get(:@sessions)[session_id]
          if related_request_id
            (session[:post_request_streams] ||= {})[related_request_id] = stream
          else
            session[:get_sse_stream] = stream
          end

          writes
        end

        def create_rack_request(method, path, headers, body = nil)
          default_accept = case method
          when "POST"
            { "HTTP_ACCEPT" => "application/json, text/event-stream" }
          when "GET"
            { "HTTP_ACCEPT" => "text/event-stream" }
          else
            {}
          end

          env = {
            "REQUEST_METHOD" => method,
            "PATH_INFO" => path,
            "rack.input" => StringIO.new(body.to_s),
          }.merge(default_accept).merge(headers)

          Rack::Request.new(env)
        end

        def create_rack_request_without_accept(method, path, headers, body = nil)
          env = {
            "REQUEST_METHOD" => method,
            "PATH_INFO" => path,
            "rack.input" => StringIO.new(body.to_s),
          }.merge(headers)

          Rack::Request.new(env)
        end
      end
    end
  end
end
