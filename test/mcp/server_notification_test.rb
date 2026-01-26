# frozen_string_literal: true

require "test_helper"

module MCP
  class ServerNotificationTest < ActiveSupport::TestCase
    include InstrumentationTestHelper

    class MockTransport < Transport
      attr_reader :notifications

      def initialize(server)
        super
        @notifications = []
      end

      def send_notification(method, params = nil)
        @notifications << { method: method, params: params }
        true
      end

      def send_response(response); end
      def open; end
      def close; end
      def handle_request(request); end
    end

    setup do
      configuration = MCP::Configuration.new
      configuration.instrumentation_callback = instrumentation_helper.callback

      @server = Server.new(
        name: "test_server",
        version: "1.0.0",
        configuration: configuration,
      )

      @mock_transport = MockTransport.new(@server)
      @server.transport = @mock_transport
    end

    test "#notify_tools_list_changed sends notification through transport" do
      @server.notify_tools_list_changed

      assert_equal 1, @mock_transport.notifications.size
      notification = @mock_transport.notifications.first
      assert_equal Methods::NOTIFICATIONS_TOOLS_LIST_CHANGED, notification[:method]
      assert_nil notification[:params]
    end

    test "#notify_prompts_list_changed sends notification through transport" do
      @server.notify_prompts_list_changed

      assert_equal 1, @mock_transport.notifications.size
      notification = @mock_transport.notifications.first
      assert_equal Methods::NOTIFICATIONS_PROMPTS_LIST_CHANGED, notification[:method]
      assert_nil notification[:params]
    end

    test "#notify_resources_list_changed sends notification through transport" do
      @server.notify_resources_list_changed

      assert_equal 1, @mock_transport.notifications.size
      notification = @mock_transport.notifications.first
      assert_equal Methods::NOTIFICATIONS_RESOURCES_LIST_CHANGED, notification[:method]
      assert_nil notification[:params]
    end

    test "#notify_log_message sends notification through transport" do
      @server.logging_message_notification = MCP::LoggingMessageNotification.new(level: "error")
      @server.notify_log_message(data: { error: "Connection Failed" }, level: "error")

      assert_equal 1, @mock_transport.notifications.size
      assert_equal Methods::NOTIFICATIONS_MESSAGE, @mock_transport.notifications.first[:method]
      assert_equal({ "data" => { error: "Connection Failed" }, "level" => "error" }, @mock_transport.notifications.first[:params])
    end

    test "#notify_log_message sends notification with logger through transport" do
      @server.logging_message_notification = MCP::LoggingMessageNotification.new(level: "error")
      @server.notify_log_message(data: { error: "Connection Failed" }, level: "error", logger: "DatabaseLogger")

      assert_equal 1, @mock_transport.notifications.size
      notification = @mock_transport.notifications.first
      assert_equal Methods::NOTIFICATIONS_MESSAGE, notification[:method]
      assert_equal({ "data" => { error: "Connection Failed" }, "level" => "error", "logger" => "DatabaseLogger" }, notification[:params])
    end

    test "#notify_log_message does not send notification with invalid log level" do
      @server.logging_message_notification = MCP::LoggingMessageNotification.new(level: "error")
      @server.notify_log_message(data: { message: "test" }, level: "invalid")

      assert_equal 0, @mock_transport.notifications.size
    end

    test "#notify_log_message does not send notification when level is below configured level" do
      @server.logging_message_notification = MCP::LoggingMessageNotification.new(level: "error")
      @server.notify_log_message(data: { message: "test" }, level: "info")

      assert_equal 0, @mock_transport.notifications.size
    end

    test "#notify_log_message sends notification when level is above configured level through transport" do
      @server.logging_message_notification = MCP::LoggingMessageNotification.new(level: "error")
      @server.notify_log_message(data: { message: "test" }, level: "critical")

      assert_equal 1, @mock_transport.notifications.size
      assert_equal Methods::NOTIFICATIONS_MESSAGE, @mock_transport.notifications[0][:method]
      assert_equal({ "data" => { message: "test" }, "level" => "critical" }, @mock_transport.notifications[0][:params])
    end

    test "notification methods work without transport" do
      server_without_transport = Server.new(name: "test_server")
      server_without_transport.logging_message_notification = MCP::LoggingMessageNotification.new(level: "error")

      # Should not raise any errors
      assert_nothing_raised do
        server_without_transport.notify_tools_list_changed
        server_without_transport.notify_prompts_list_changed
        server_without_transport.notify_resources_list_changed
        server_without_transport.notify_log_message(data: { error: "Connection Failed" }, level: "error")
      end
    end

    test "notification methods handle transport errors gracefully" do
      # Create a transport that raises errors
      error_transport = Class.new(MockTransport) do
        def send_notification(method, params = nil)
          raise StandardError, "Transport error"
        end
      end.new(@server)

      @server.transport = error_transport
      @server.logging_message_notification = MCP::LoggingMessageNotification.new(level: "error")

      # Mock the exception reporter
      expected_contexts = [
        { notification: "tools_list_changed" },
        { notification: "prompts_list_changed" },
        { notification: "resources_list_changed" },
        { notification: "log_message" },
      ]

      call_count = 0
      @server.configuration.exception_reporter.expects(:call).times(4).with do |exception, context|
        assert_kind_of StandardError, exception
        assert_equal "Transport error", exception.message
        assert_includes expected_contexts, context
        call_count += 1
        true
      end

      # Should not raise errors to the caller
      assert_nothing_raised do
        @server.notify_tools_list_changed
        @server.notify_prompts_list_changed
        @server.notify_resources_list_changed
        @server.notify_log_message(data: { error: "Connection Failed" }, level: "error")
      end

      assert_equal 4, call_count
    end

    test "multiple notification methods can be called in sequence" do
      @server.notify_tools_list_changed
      @server.notify_prompts_list_changed
      @server.notify_resources_list_changed
      @server.logging_message_notification = MCP::LoggingMessageNotification.new(level: "error")
      @server.notify_log_message(data: { error: "Connection Failed" }, level: "error")

      assert_equal 4, @mock_transport.notifications.size

      notifications = @mock_transport.notifications
      assert_equal Methods::NOTIFICATIONS_TOOLS_LIST_CHANGED, notifications[0][:method]
      assert_equal Methods::NOTIFICATIONS_PROMPTS_LIST_CHANGED, notifications[1][:method]
      assert_equal Methods::NOTIFICATIONS_RESOURCES_LIST_CHANGED, notifications[2][:method]
      assert_equal Methods::NOTIFICATIONS_MESSAGE, notifications[3][:method]
    end
  end
end
