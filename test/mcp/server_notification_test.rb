# typed: true
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

    test "notification methods work without transport" do
      server_without_transport = Server.new(name: "test_server")

      # Should not raise any errors
      assert_nothing_raised do
        server_without_transport.notify_tools_list_changed
        server_without_transport.notify_prompts_list_changed
        server_without_transport.notify_resources_list_changed
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

      # Mock the exception reporter
      expected_contexts = [
        { notification: "tools_list_changed" },
        { notification: "prompts_list_changed" },
        { notification: "resources_list_changed" },
      ]

      call_count = 0
      @server.configuration.exception_reporter.expects(:call).times(3).with do |exception, context|
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
      end

      assert_equal 3, call_count
    end

    test "multiple notification methods can be called in sequence" do
      @server.notify_tools_list_changed
      @server.notify_prompts_list_changed
      @server.notify_resources_list_changed

      assert_equal 3, @mock_transport.notifications.size

      notifications = @mock_transport.notifications
      assert_equal Methods::NOTIFICATIONS_TOOLS_LIST_CHANGED, notifications[0][:method]
      assert_equal Methods::NOTIFICATIONS_PROMPTS_LIST_CHANGED, notifications[1][:method]
      assert_equal Methods::NOTIFICATIONS_RESOURCES_LIST_CHANGED, notifications[2][:method]
    end
  end
end
