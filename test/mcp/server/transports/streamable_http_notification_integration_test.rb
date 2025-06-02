# frozen_string_literal: true

require "test_helper"
require "json"
require "rack"
require "mcp/server"
require "mcp/server/transports/streamable_http_transport"

module MCP
  class Server
    module Transports
      class StreamableHTTPNotificationIntegrationTest < ActiveSupport::TestCase
        setup do
          @server = Server.new(
            name: "test_server",
            tools: [],
            prompts: [],
            resources: [],
          )
          @transport = StreamableHTTPTransport.new(@server)
          @server.transport = @transport
        end

        test "server notification methods send SSE notifications through HTTP transport" do
          # Initialize a session
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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

          # Test tools notification
          @server.notify_tools_list_changed

          # Test prompts notification
          @server.notify_prompts_list_changed

          # Test resources notification
          @server.notify_resources_list_changed

          # Check the notifications were received
          io.rewind
          output = io.read

          assert_includes output, "data: #{Methods::NOTIFICATIONS_TOOLS_LIST_CHANGED}"
          assert_includes output, "data: #{Methods::NOTIFICATIONS_PROMPTS_LIST_CHANGED}"
          assert_includes output, "data: #{Methods::NOTIFICATIONS_RESOURCES_LIST_CHANGED}"
        end

        test "notifications are broadcast to all connected sessions" do
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

          # Send notification through server
          @server.notify_tools_list_changed

          # Check both sessions received the notification
          io1.rewind
          output1 = io1.read
          assert_includes output1, "data: #{Methods::NOTIFICATIONS_TOOLS_LIST_CHANGED}"

          io2.rewind
          output2 = io2.read
          assert_includes output2, "data: #{Methods::NOTIFICATIONS_TOOLS_LIST_CHANGED}"
        end

        test "server continues to work when SSE connection is closed" do
          # Initialize a session
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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

          # Server notifications should not raise errors
          assert_nothing_raised do
            @server.notify_tools_list_changed
            @server.notify_prompts_list_changed
            @server.notify_resources_list_changed
          end
        end

        test "notifications work with dynamic tool additions" do
          # Initialize a session
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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

          # Define a new tool (simulating dynamic tool addition)
          @server.define_tool(
            name: "dynamic_tool",
            description: "A dynamically added tool",
          ) do |**args|
            { result: "success" }
          end

          # Manually trigger notification (since we removed the automatic triggers)
          @server.notify_tools_list_changed

          # Check the notification was received
          io.rewind
          output = io.read
          assert_includes output, "data: #{Methods::NOTIFICATIONS_TOOLS_LIST_CHANGED}"

          # Verify the tool was added to the server
          assert @server.tools.key?("dynamic_tool")
        end

        test "SSE format is correct for notifications" do
          # Initialize a session
          init_request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init" }.to_json,
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

          # Send a notification
          @server.notify_tools_list_changed

          # Check SSE format
          io.rewind
          output = io.read

          # SSE format should be "data: <message>\n\n"
          assert_match(/data: #{Regexp.escape(Methods::NOTIFICATIONS_TOOLS_LIST_CHANGED)}\n/, output)
        end

        private

        def create_rack_request(method, path, headers, body = nil)
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
