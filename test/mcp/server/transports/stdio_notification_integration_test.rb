# frozen_string_literal: true

require "test_helper"

module MCP
  class Server
    module Transports
      class StdioNotificationIntegrationTest < ActiveSupport::TestCase
        include InitializeParamsTestHelper

        class MockIO
          attr_reader :output

          def initialize
            @output = []
            @closed = false
          end

          def puts(message)
            @output << message
          end

          def write(message)
            @output << message
            message.length
          end

          def gets
            nil # Simulate end of input
          end

          def set_encoding(encoding)
            # Mock implementation
          end

          def flush
            # Mock implementation
          end

          def close
            @closed = true
          end

          def closed?
            @closed
          end
        end

        setup do
          @original_stdout = $stdout
          @original_stdin = $stdin

          @mock_stdout = MockIO.new
          @mock_stdin = MockIO.new

          $stdout = @mock_stdout
          $stdin = @mock_stdin

          @server = Server.new(
            name: "test_server",
            tools: [],
            prompts: [],
            resources: [],
          )
          @transport = StdioTransport.new(@server)
        end

        teardown do
          $stdout = @original_stdout
          $stdin = @original_stdin
        end

        test "server notification methods send JSON-RPC notifications through StdioTransport" do
          # Test tools notification
          @server.notify_tools_list_changed

          # Test prompts notification
          @server.notify_prompts_list_changed

          # Test resources notification
          @server.notify_resources_list_changed

          # Test log notification
          @server.logging_message_notification = MCP::LoggingMessageNotification.new(level: "error")
          @server.notify_log_message(data: { error: "Connection Failed" }, level: "error")

          # Check the notifications were sent
          assert_equal 4, @mock_stdout.output.size

          # Parse and verify each notification
          notifications = @mock_stdout.output.map { |msg| JSON.parse(msg) }

          assert_equal "2.0", notifications[0]["jsonrpc"]
          assert_equal Methods::NOTIFICATIONS_TOOLS_LIST_CHANGED, notifications[0]["method"]
          assert_nil notifications[0]["params"]

          assert_equal "2.0", notifications[1]["jsonrpc"]
          assert_equal Methods::NOTIFICATIONS_PROMPTS_LIST_CHANGED, notifications[1]["method"]
          assert_nil notifications[1]["params"]

          assert_equal "2.0", notifications[2]["jsonrpc"]
          assert_equal Methods::NOTIFICATIONS_RESOURCES_LIST_CHANGED, notifications[2]["method"]
          assert_nil notifications[2]["params"]

          assert_equal "2.0", notifications[3]["jsonrpc"]
          assert_equal Methods::NOTIFICATIONS_MESSAGE, notifications[3]["method"]
          assert_equal({ "level" => "error", "data" => { "error" => "Connection Failed" } }, notifications[3]["params"])
        end

        test "notifications include params when provided" do
          # Test the transport's send_notification directly with params
          result = @transport.send_notification("test/notification", { data: "test_value" })

          assert result
          assert_equal 1, @mock_stdout.output.size

          notification = JSON.parse(@mock_stdout.output.first)
          assert_equal "2.0", notification["jsonrpc"]
          assert_equal "test/notification", notification["method"]
          assert_equal({ "data" => "test_value" }, notification["params"])
        end

        test "server continues to work when stdout is closed" do
          # Close stdout
          @mock_stdout.close

          # Server notifications should not raise errors
          assert_nothing_raised do
            @server.notify_tools_list_changed
            @server.notify_prompts_list_changed
            @server.notify_resources_list_changed
            @server.notify_log_message(data: { error: "Connection Failed" }, level: "error")
          end
        end

        test "notifications work with dynamic tool additions" do
          # Define a new tool
          @server.define_tool(
            name: "dynamic_tool",
            description: "A dynamically added tool",
          ) do |**_args|
            { result: "success" }
          end

          # Clear previous output
          @mock_stdout.output.clear

          # Manually trigger notification
          @server.notify_tools_list_changed

          # Check the notification was sent
          assert_equal 1, @mock_stdout.output.size

          notification = JSON.parse(@mock_stdout.output.first)
          assert_equal Methods::NOTIFICATIONS_TOOLS_LIST_CHANGED, notification["method"]

          # Verify the tool was added to the server
          assert @server.tools.key?("dynamic_tool")
        end

        test "notifications are properly formatted JSON-RPC 2.0 messages" do
          # Send a notification
          @server.notify_prompts_list_changed

          # Verify format
          assert_equal 1, @mock_stdout.output.size
          output = @mock_stdout.output.first

          # Should be valid JSON
          notification = JSON.parse(output)

          # Should have required JSON-RPC 2.0 fields
          assert_equal "2.0", notification["jsonrpc"]
          assert notification.key?("method")
          refute notification.key?("id") # Notifications should not have an id

          # Method should be the expected notification type
          assert_equal Methods::NOTIFICATIONS_PROMPTS_LIST_CHANGED, notification["method"]
        end

        test "multiple notifications are sent as separate JSON messages" do
          # Send multiple notifications rapidly
          5.times do
            @server.notify_tools_list_changed
          end

          # Each should be a separate JSON message
          assert_equal 5, @mock_stdout.output.size

          # All should be parseable as JSON
          @mock_stdout.output.each do |msg|
            notification = JSON.parse(msg)
            assert_equal "2.0", notification["jsonrpc"]
            assert_equal Methods::NOTIFICATIONS_TOOLS_LIST_CHANGED, notification["method"]
          end
        end

        test "transport handles errors gracefully" do
          # Create a stdout that raises errors
          error_stdout = Class.new(MockIO) do
            def puts(message)
              raise IOError, "Simulated IO error"
            end
          end.new

          $stdout = error_stdout

          # Notification should return false but not raise
          result = @transport.send_notification("test/notification")
          refute result
        end

        test "server notification flow works end-to-end with StdioTransport" do
          # This test verifies the complete integration from server to transport

          # Start with no output
          assert_equal([], @mock_stdout.output)

          # Add a prompt and notify
          @server.define_prompt(
            name: "test_prompt",
            description: "Test prompt",
          ) do
            MCP::PromptResponse.new(messages: [{ role: "user", content: "Test" }])
          end

          # Manually trigger notification
          @server.notify_prompts_list_changed

          # Verify notification was sent
          assert_equal 1, @mock_stdout.output.size
          notification = JSON.parse(@mock_stdout.output.first)
          assert_equal Methods::NOTIFICATIONS_PROMPTS_LIST_CHANGED, notification["method"]

          # Add a resource and notify
          @server.resources = [
            MCP::Resource.new(
              uri: "https://test_resource.invalid",
              name: "test-resource",
              title: "Test Resource",
              description: "A test resource",
              mime_type: "text/plain",
            ),
          ]

          # Manually trigger notification
          @server.notify_resources_list_changed

          # Verify both notifications were sent
          assert_equal 2, @mock_stdout.output.size
          second_notification = JSON.parse(@mock_stdout.output.last)
          assert_equal Methods::NOTIFICATIONS_RESOURCES_LIST_CHANGED, second_notification["method"]

          # Set log level and notify
          @server.logging_message_notification = MCP::LoggingMessageNotification.new(level: "error")

          # Manually trigger notification
          @server.notify_log_message(data: { error: "Connection Failed" }, level: "error")
          assert_equal 3, @mock_stdout.output.size
          third_notification = JSON.parse(@mock_stdout.output.last)
          assert_equal Methods::NOTIFICATIONS_MESSAGE, third_notification["method"]
          assert_equal({ "data" => { "error" => "Connection Failed" }, "level" => "error" }, third_notification["params"])
        end

        test "server log messages honor the stdio client's level instead of the application default" do
          default_logging = LoggingMessageNotification.new(level: "critical")
          @server.logging_message_notification = default_logging
          server = @server
          @server.define_tool(name: "log_messages") do
            server.notify_log_message(data: "debug log", level: "debug")
            server.notify_log_message(data: "broadcast log", level: "info")
            Tool::Response.new([{ type: "text", text: "ok" }])
          end
          requests = [
            { jsonrpc: "2.0", id: 1, method: "initialize", params: initialize_params(protocolVersion: "2025-11-25") },
            { jsonrpc: "2.0", method: "notifications/initialized" },
            { jsonrpc: "2.0", id: 2, method: "logging/setLevel", params: { level: "info" } },
            { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "log_messages", arguments: {} } },
          ]
          frames = requests.map { |request| "#{request.to_json}\n" }
          @mock_stdin.stubs(:gets).returns(*frames, nil)

          @transport.open

          messages = @mock_stdout.output.map { |message| JSON.parse(message) }
          assert_equal({}, messages.find { |message| message["id"] == 2 }["result"])
          assert_equal "ok", messages.find { |message| message["id"] == 3 }["result"]["content"].first["text"]
          logs = messages.select { |message| message["method"] == Methods::NOTIFICATIONS_MESSAGE }
          assert_equal 1, logs.size
          assert_equal "broadcast log", logs.first["params"]["data"]
          assert_same default_logging, @server.logging_message_notification
        end

        test "modern stdio logs stay request-scoped even with an application default" do
          @server.logging_message_notification = LoggingMessageNotification.new(level: "debug")
          server = @server
          @server.define_tool(name: "log_messages") do |server_context:|
            server.notify_log_message(data: "broadcast log", level: "info")
            server_context.notify_log_message(data: "request log", level: "error")
            Tool::Response.new([{ type: "text", text: "ok" }])
          end
          meta = {
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientInfo": { name: "modern_client", version: "1.0" },
            "io.modelcontextprotocol/clientCapabilities": {},
          }
          requests = [
            { jsonrpc: "2.0", id: 1, method: "server/discover" },
            { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "log_messages", arguments: {}, _meta: meta } },
            {
              jsonrpc: "2.0", id: 3, method: "tools/call", params: {
                name: "log_messages", arguments: {}, _meta: meta.merge("io.modelcontextprotocol/logLevel": "error"),
              },
            },
          ]
          frames = requests.map { |request| "#{request.to_json}\n" }
          @mock_stdin.stubs(:gets).returns(*frames, nil)

          @transport.open

          messages = @mock_stdout.output.map { |message| JSON.parse(message) }
          assert_equal "ok", messages.find { |message| message["id"] == 2 }["result"]["content"].first["text"]
          assert_equal "ok", messages.find { |message| message["id"] == 3 }["result"]["content"].first["text"]
          logs = messages.select { |message| message["method"] == Methods::NOTIFICATIONS_MESSAGE }
          assert_equal ["request log"], logs.map { |message| message["params"]["data"] }
        end
      end
    end
  end
end
