# frozen_string_literal: true

require "test_helper"

module MCP
  class ProgressTest < ActiveSupport::TestCase
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
      @server = Server.new(name: "test_server")
      @transport = MockTransport.new(@server)
      @server.transport = @transport
    end

    test "#report is a no-op when progress_token is nil" do
      progress = Progress.new(server: @server, progress_token: nil)
      progress.report(50, total: 100, message: "halfway")

      assert_equal 0, @transport.notifications.size
    end

    test "#report sends notification when progress_token is present" do
      progress = Progress.new(server: @server, progress_token: "token-1")
      progress.report(50, total: 100, message: "halfway")

      assert_equal 1, @transport.notifications.size
      notification = @transport.notifications.first
      assert_equal Methods::NOTIFICATIONS_PROGRESS, notification[:method]
      assert_equal "token-1", notification[:params]["progressToken"]
      assert_equal 50, notification[:params]["progress"]
      assert_equal 100, notification[:params]["total"]
      assert_equal "halfway", notification[:params]["message"]
    end

    test "#report omits total and message when not provided" do
      progress = Progress.new(server: @server, progress_token: "token-1")
      progress.report(50)

      assert_equal 1, @transport.notifications.size
      notification = @transport.notifications.first
      assert_equal "token-1", notification[:params]["progressToken"]
      assert_equal 50, notification[:params]["progress"]
      refute notification[:params].key?("total")
      refute notification[:params].key?("message")
    end
  end
end
