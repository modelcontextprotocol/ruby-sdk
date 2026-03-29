# frozen_string_literal: true

require "test_helper"
require "rack"

module MCP
  class Server
    module Transports
      class StreamableHTTPTransportTest < ActiveSupport::TestCase
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
          assert_equal({ "Content-Type" => "application/json" }, response[1])

          body = JSON.parse(response[2][0])
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

        test "handles POST request when IOError raised" do
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

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            { jsonrpc: "2.0", method: "ping", id: "456" }.to_json,
          )

          # This should handle IOError and return the original response
          response = @transport.handle_request(request)
          assert_equal 200, response[0]
          assert_equal({ "Content-Type" => "application/json" }, response[1])

          # Verify session was cleaned up
          assert_not @transport.instance_variable_get(:@sessions).key?(session_id)
        end

        test "handles POST request when Errno::EPIPE raised" do
          # Create and initialize a session
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "123" }.to_json,
          )
          init_response = @transport.handle_request(init_request)
          session_id = init_response[1]["Mcp-Session-Id"]

          # Create a pipe to simulate EPIPE condition
          reader, writer = IO.pipe

          # Connect with SSE using the writer end of the pipe
          get_request = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id },
          )
          response = @transport.handle_request(get_request)
          response[2].call(writer) if response[2].is_a?(Proc)

          # Give the stream time to set up
          sleep(0.1)

          # Close the reader end to break the pipe - this will cause EPIPE on write
          reader.close

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            { jsonrpc: "2.0", method: "ping", id: "789" }.to_json,
          )

          # This should handle Errno::EPIPE and return the original response
          response = @transport.handle_request(request)
          assert_equal 200, response[0]
          assert_equal({ "Content-Type" => "application/json" }, response[1])

          # Verify session was cleaned up
          assert_not @transport.instance_variable_get(:@sessions).key?(session_id)

          begin
            writer.close
          rescue
            nil
          end
        end

        test "handles POST request when Errno::ECONNRESET raised" do
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

          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
            },
            { jsonrpc: "2.0", method: "ping", id: "789" }.to_json,
          )

          # This should handle Errno::ECONNRESET and return the original response.
          response = @transport.handle_request(request)
          assert_equal 200, response[0]
          assert_equal({ "Content-Type" => "application/json" }, response[1])

          # Verify session was cleaned up.
          assert_not @transport.instance_variable_get(:@sessions).key?(session_id)
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

          # Handle request from session 1
          @transport.handle_request(request_as_session1)

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

          # Handle request from session 2
          @transport.handle_request(request_as_session2)

          # Check that each session received one notification
          io1.rewind
          output1 = io1.read
          # Session 1 should have received two notifications (one from each request since we broadcast)
          assert_equal 2, output1.scan(/data: {"jsonrpc":"2.0","method":"test_notification","params":{"session":"current"}}/).count

          io2.rewind
          output2 = io2.read
          # Session 2 should have received two notifications (one from each request since we broadcast)
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

        test "send_response_to_stream returns 202 when message is sent to stream" do
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

          # Make a regular request that will be routed through send_response_to_stream
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
          assert_equal 202, response[0]
          assert_empty response[1]
          assert_empty response[2]
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
          transport.handle_request(tool_request)

          # Session 1 should receive the log notification.
          io1.rewind
          assert_includes io1.read, "secret"

          # Session 2 should NOT receive the log notification.
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
          transport.handle_request(tool_request)

          # Session 1 should receive the progress notification.
          io1.rewind
          assert_includes io1.read, "halfway"

          # Session 2 should NOT receive the progress notification.
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
          transport.handle_request(set_level1)

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
          transport.handle_request(set_level2)

          # Session 1 (error level) should not notify for "info", but should for "error".
          session1_logging = transport.instance_variable_get(:@sessions)[session1][:server_session].logging_message_notification
          refute session1_logging.should_notify?("info")
          assert session1_logging.should_notify?("error")

          # Session 2 (debug level) should notify for both "info" and "debug".
          session2_logging = transport.instance_variable_get(:@sessions)[session2][:server_session].logging_message_notification
          assert session2_logging.should_notify?("info")
          assert session2_logging.should_notify?("debug")
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
