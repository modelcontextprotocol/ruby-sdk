# frozen_string_literal: true

require "test_helper"
require "rack"

module MCP
  class Server
    module Transports
      class StreamableHTTPTransportTest < ActiveSupport::TestCase
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
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
          assert_equal "Invalid JSON", body["error"]
        end

        test "handles POST request with initialize method" do
          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
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

        test "handles GET request with valid session ID" do
          # First create a session with initialize
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
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
          assert_equal "Missing session ID", body["error"]
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
          assert_equal "Missing session ID", body["error"]
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
          assert_equal "Missing session ID", body["error"]
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
          assert_equal "Missing session ID", body["error"]
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

        test "rejects duplicate SSE connection with 409" do
          # Create a session
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Simulate an active SSE stream by storing a stream object in the session
          mock_stream = StringIO.new
          @transport.instance_variable_get(:@sessions)[session_id][:stream] = mock_stream

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
          assert_equal "Conflict: Only one SSE stream is allowed per session", body["error"]
        end

        test "store_stream_for_session does not overwrite existing stream (TOCTOU guard)" do
          # Create a session
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Establish stream A
          stream_a = StringIO.new
          @transport.send(:store_stream_for_session, session_id, stream_a)
          assert_equal stream_a, @transport.instance_variable_get(:@sessions)[session_id][:stream]

          # Attempt to store stream B (simulating a racing request)
          stream_b = StringIO.new
          @transport.send(:store_stream_for_session, session_id, stream_b)

          # Stream A should still be the active stream
          assert_equal stream_a, @transport.instance_variable_get(:@sessions)[session_id][:stream]

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
          assert_equal "Session not found", body["error"]
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
          assert_equal "Session not found", body["error"]
        end

        test "handles DELETE request with valid session ID" do
          # First create a session with initialize
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
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
          assert_equal "Session not found", body["error"]
        end

        test "POST returns 404 after session is deleted" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
          assert_equal "Session not found", body["error"]
        end

        test "DELETE returns 404 after session is already deleted" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
          assert_equal "Session not found", body["error"]
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
          assert_equal "Missing session ID", body["error"]
        end

        test "closes transport and cleans up session" do
          # First create a session with initialize
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
          )
          init_response1 = @transport.handle_request(init_request1)
          session_id1 = init_response1[1]["Mcp-Session-Id"]

          # Create second session
          init_request2 = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "456" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
          )
          init_response1 = @transport.handle_request(init_request1)
          session_id1 = init_response1[1]["Mcp-Session-Id"]

          init_request2 = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "456" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
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

          @transport.instance_variable_get(:@sessions)[session_id][:stream] = mock_stream

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
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
          assert @transport.instance_variable_get(:@sessions)[session_id][:stream]
        end

        test "active_stream does not fall back to GET SSE when related_request_id is given but request_stream is missing" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "1" }.to_json,
          )
          init_response1 = @transport.handle_request(init_request1)
          session_id1 = init_response1[1]["Mcp-Session-Id"]

          init_request2 = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "2" }.to_json,
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

        test "send_keepalive_ping handles Errno::ECONNRESET gracefully" do
          # Create and initialize a session.
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
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
          assert_equal "Method not allowed", body["error"]
        end

        test "POST request without Accept header returns 406" do
          request = create_rack_request_without_accept(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 406, response[0]
          assert_equal({ "Content-Type" => "application/json" }, response[1])

          body = JSON.parse(response[2][0])
          assert_equal "Not Acceptable: Accept header must include application/json and text/event-stream",
            body["error"]
        end

        test "POST request with Accept header missing text/event-stream returns 406" do
          request = create_rack_request_without_accept(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_ACCEPT" => "application/json",
            },
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 406, response[0]

          body = JSON.parse(response[2][0])
          assert_equal "Not Acceptable: Accept header must include application/json and text/event-stream",
            body["error"]
        end

        test "POST request with Accept header missing application/json returns 406" do
          request = create_rack_request_without_accept(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_ACCEPT" => "text/event-stream",
            },
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 406, response[0]

          body = JSON.parse(response[2][0])
          assert_equal "Not Acceptable: Accept header must include application/json and text/event-stream",
            body["error"]
        end

        test "POST request with valid Accept header succeeds" do
          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_ACCEPT" => "application/json, text/event-stream",
            },
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
          )

          response = @transport.handle_request(request)
          assert_equal 200, response[0]
        end

        test "GET request without Accept header returns 406" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
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
          assert_equal "Not Acceptable: Accept header must include text/event-stream", body["error"]
        end

        test "GET request with Accept header missing text/event-stream returns 406" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
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
          assert_equal "Not Acceptable: Accept header must include text/event-stream", body["error"]
        end

        test "GET request with valid Accept header succeeds" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
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

        test "stateless mode allows requests without session IDs, responding with no session ID" do
          stateless_transport = StreamableHTTPTransport.new(@server, stateless: true)

          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
          assert_equal "Method not allowed", body["error"]
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
          stateless_transport = StreamableHTTPTransport.new(@server, stateless: true)

          e = assert_raises(RuntimeError) do
            stateless_transport.send_notification(
              "test_notification",
              { message: "Hello" },
              session_id: "some_session_id",
            )
          end

          assert_equal("Stateless mode does not support notifications", e.message)
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
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
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

        test "handle post request with a standard error" do
          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "4567" }.to_json,
          )

          @transport.define_singleton_method(:extract_session_id) do |_request|
            raise StandardError, "Test error"
          end

          response = @transport.handle_request(request)
          assert_equal 500, response[0]
          assert_equal({ "Content-Type" => "application/json" }, response[1])

          body = JSON.parse(response[2][0])
          assert_equal "Internal server error", body["error"]
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
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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

        test "send_request ignores response from wrong session" do
          # Create two sessions.
          init_a = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init-a" }.to_json,
          )
          resp_a = @transport.handle_request(init_a)
          session_a = resp_a[1]["Mcp-Session-Id"]

          init_b = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init-b" }.to_json,
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

        test "send_request raises on error response from client" do
          # Create session.
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
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
          assert_equal("Session not found", body["error"])
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
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
          assert_equal("Session not found", body["error"])
        ensure
          transport.close
        end

        test "session_idle_timeout: nil disables session expiry" do
          transport = StreamableHTTPTransport.new(@server, session_idle_timeout: nil)

          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
          assert_equal("Session not found", body["error"])
        ensure
          transport.close
        end

        test "reap_expired_sessions closes stream outside mutex" do
          transport = StreamableHTTPTransport.new(@server, session_idle_timeout: 0.01)

          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
          transport.instance_variable_get(:@sessions)[session_id][:stream] = mock_stream

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

        test "default session_idle_timeout is nil and sessions do not expire" do
          transport = StreamableHTTPTransport.new(@server)
          assert_nil(transport.instance_variable_get(:@reaper_thread))

          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
          )
          init_response = transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Attach a mock stream to the session
          stream = StringIO.new
          transport.instance_variable_get(:@sessions)[session_id][:stream] = stream

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
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
          assert_equal "Missing session ID", body["error"]
        end

        test "POST response with invalid session ID returns 404" do
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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
          assert_equal "Session not found", body["error"]
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
          assert_equal("Session not found", body["error"])
        end

        test "session-scoped log notification is sent only to the originating session" do
          server = Server.new(name: "test", tools: [], prompts: [], resources: [])
          server.logging_message_notification = MCP::LoggingMessageNotification.new(level: "debug")
          transport = StreamableHTTPTransport.new(server)
          server.transport = transport

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
              params: { protocolVersion: "2025-11-25", clientInfo: { name: "a" } },
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
              params: { protocolVersion: "2025-11-25", clientInfo: { name: "b" } },
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
          server.transport = transport

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
              params: { protocolVersion: "2025-11-25", clientInfo: { name: "a" } },
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
              params: { protocolVersion: "2025-11-25", clientInfo: { name: "b" } },
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
          server.transport = transport

          # Initialize session 1 with client "alpha".
          init1 = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            {
              jsonrpc: "2.0",
              method: "initialize",
              id: "1",
              params: {
                protocolVersion: "2025-11-25",
                clientInfo: { name: "alpha", version: "1.0" },
              },
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
              params: {
                protocolVersion: "2025-11-25",
                clientInfo: { name: "beta", version: "2.0" },
              },
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
          server.transport = transport

          # Initialize two sessions.
          init1 = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            {
              jsonrpc: "2.0",
              method: "initialize",
              id: "1",
              params: { protocolVersion: "2025-11-25", clientInfo: { name: "a" } },
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
              params: { protocolVersion: "2025-11-25", clientInfo: { name: "b" } },
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
            "rack.input" => StringIO.new({ jsonrpc: "2.0", method: "initialize", id: "init-1" }.to_json),
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
            "rack.input" => StringIO.new({ jsonrpc: "2.0", method: "initialize", id: "init" }.to_json),
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
            "rack.input" => StringIO.new({ jsonrpc: "2.0", method: "initialize", id: "init" }.to_json),
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
            { jsonrpc: "2.0", method: "initialize", id: "init-frozen" }.to_json,
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

        private

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
