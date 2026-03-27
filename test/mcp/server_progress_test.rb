# frozen_string_literal: true

require "test_helper"

module MCP
  class ServerProgressTest < ActiveSupport::TestCase
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

    # Tool without progress parameter.
    class SimpleToolWithoutProgress < Tool
      tool_name "simple_without_progress"
      description "A tool that doesn't use progress"
      input_schema(properties: { message: { type: "string" } }, required: ["message"])

      class << self
        def call(message:)
          Tool::Response.new([{ type: "text", text: "SimpleToolWithoutProgress: #{message}" }])
        end
      end
    end

    # Tool with progress via server_context.
    class ToolWithProgress < Tool
      tool_name "tool_with_progress"
      description "A tool that uses progress"
      input_schema(properties: { message: { type: "string" } }, required: ["message"])

      class << self
        def call(message:, server_context:)
          server_context.report_progress(50, total: 100, message: "halfway")
          server_context.report_progress(100, total: 100, message: "done")
          Tool::Response.new([{ type: "text", text: "ToolWithProgress: #{message}" }])
        end
      end
    end

    # Tool with server_context accessing both context data and progress.
    class ToolWithContextAndProgress < Tool
      tool_name "tool_with_context_and_progress"
      description "A tool that uses both server_context and progress"
      input_schema(properties: { message: { type: "string" } }, required: ["message"])

      class << self
        def call(message:, server_context:)
          server_context.report_progress(100)
          context_info = server_context[:user] || "none"
          Tool::Response.new([{ type: "text", text: "ToolWithContextAndProgress: #{message} context=#{context_info}" }])
        end
      end
    end

    # Tool with **kwargs.
    class ToolWithKwargs < Tool
      tool_name "tool_with_kwargs"
      description "A tool that uses **kwargs"

      class << self
        def call(**kwargs)
          context = kwargs[:server_context]
          context.report_progress(75)
          Tool::Response.new([{ type: "text", text: "ToolWithKwargs: progress=#{context ? "present" : "absent"}" }])
        end
      end
    end

    setup do
      @server = Server.new(
        name: "test_server",
        version: "1.0.0",
        tools: [SimpleToolWithoutProgress, ToolWithProgress, ToolWithContextAndProgress, ToolWithKwargs],
        server_context: { user: "test_user" },
      )

      @mock_transport = MockTransport.new(@server)
      @server.transport = @mock_transport
      @session = ServerSession.new(server: @server, transport: @mock_transport)
    end

    test "tool with progress parameter receives Progress instance and sends notifications via _meta.progressToken" do
      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "tool_with_progress",
          arguments: { message: "Hello" },
          _meta: { progressToken: "token-abc" },
        },
      }

      response = @session.handle(request)

      assert response[:result]
      assert_equal "ToolWithProgress: Hello", response[:result][:content][0][:text]

      assert_equal 2, @mock_transport.notifications.size

      first = @mock_transport.notifications[0]
      assert_equal Methods::NOTIFICATIONS_PROGRESS, first[:method]
      assert_equal "token-abc", first[:params]["progressToken"]
      assert_equal 50, first[:params]["progress"]
      assert_equal 100, first[:params]["total"]
      assert_equal "halfway", first[:params]["message"]

      second = @mock_transport.notifications[1]
      assert_equal Methods::NOTIFICATIONS_PROGRESS, second[:method]
      assert_equal "token-abc", second[:params]["progressToken"]
      assert_equal 100, second[:params]["progress"]
      assert_equal 100, second[:params]["total"]
      assert_equal "done", second[:params]["message"]
    end

    test "tool without progress parameter works normally" do
      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "simple_without_progress",
          arguments: { message: "Hello" },
        },
      }

      response = @session.handle(request)

      assert response[:result]
      assert_equal "SimpleToolWithoutProgress: Hello", response[:result][:content][0][:text]
      assert_equal 0, @mock_transport.notifications.size
    end

    test "server_context.report_progress is a no-op when no progressToken in request" do
      received_context = :unset

      tool_class = Class.new(Tool) do
        tool_name "progress_nil_tool"

        define_singleton_method(:call) do |server_context:|
          received_context = server_context
          Tool::Response.new([{ type: "text", text: "done" }])
        end
      end

      server = Server.new(
        name: "test_server",
        tools: [tool_class],
        server_context: { user: "test" },
      )
      server.transport = @mock_transport
      session = ServerSession.new(server: server, transport: @mock_transport)

      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "progress_nil_tool",
          arguments: {},
        },
      }

      session.handle(request)

      assert_instance_of ServerContext, received_context
      assert_nothing_raised { received_context.report_progress(50) }
      assert_equal 0, @mock_transport.notifications.size
    end

    test "tool with both server_context and progress receives both" do
      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "tool_with_context_and_progress",
          arguments: { message: "Hello" },
          _meta: { progressToken: "token-xyz" },
        },
      }

      response = @session.handle(request)

      assert response[:result]
      assert_equal "ToolWithContextAndProgress: Hello context=test_user", response[:result][:content][0][:text]

      assert_equal 1, @mock_transport.notifications.size
      notification = @mock_transport.notifications.first
      assert_equal Methods::NOTIFICATIONS_PROGRESS, notification[:method]
      assert_equal "token-xyz", notification[:params]["progressToken"]
      assert_equal 100, notification[:params]["progress"]
    end

    test "tool with **kwargs receives Progress instance" do
      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "tool_with_kwargs",
          arguments: {},
          _meta: { progressToken: "token-kwargs" },
        },
      }

      response = @session.handle(request)

      assert response[:result]
      assert_equal "ToolWithKwargs: progress=present", response[:result][:content][0][:text]

      assert_equal 1, @mock_transport.notifications.size
      notification = @mock_transport.notifications.first
      assert_equal Methods::NOTIFICATIONS_PROGRESS, notification[:method]
      assert_equal "token-kwargs", notification[:params]["progressToken"]
      assert_equal 75, notification[:params]["progress"]
    end

    test "block-defined tool with progress via server_context works" do
      server = Server.new(name: "test_server")
      server.transport = @mock_transport

      server.define_tool(name: "block_tool") do |server_context:|
        server_context.report_progress(42, total: 100)
        Tool::Response.new([{ type: "text", text: "block_tool done" }])
      end

      session = ServerSession.new(server: server, transport: @mock_transport)

      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "block_tool",
          arguments: {},
          _meta: { progressToken: "block-token" },
        },
      }

      response = session.handle(request)

      assert response[:result]
      assert_equal "block_tool done", response[:result][:content][0][:text]

      assert_equal 1, @mock_transport.notifications.size
      notification = @mock_transport.notifications.first
      assert_equal Methods::NOTIFICATIONS_PROGRESS, notification[:method]
      assert_equal "block-token", notification[:params]["progressToken"]
      assert_equal 42, notification[:params]["progress"]
      assert_equal 100, notification[:params]["total"]
    end

    test "multiple progress notifications during tool execution" do
      server = Server.new(name: "test_server")
      server.transport = @mock_transport

      server.define_tool(name: "multi_progress_tool") do |server_context:|
        (1..5).each do |i|
          server_context.report_progress(i * 20, total: 100)
        end
        Tool::Response.new([{ type: "text", text: "done" }])
      end

      session = ServerSession.new(server: server, transport: @mock_transport)

      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "multi_progress_tool",
          arguments: {},
          _meta: { progressToken: "multi-token" },
        },
      }

      session.handle(request)

      assert_equal 5, @mock_transport.notifications.size
      @mock_transport.notifications.each_with_index do |n, i|
        assert_equal Methods::NOTIFICATIONS_PROGRESS, n[:method]
        assert_equal "multi-token", n[:params]["progressToken"]
        assert_equal (i + 1) * 20, n[:params]["progress"]
        assert_equal 100, n[:params]["total"]
      end
    end

    test "incoming notifications/progress is handled as no-op" do
      request = {
        jsonrpc: "2.0",
        method: "notifications/progress",
        params: {
          progressToken: "token-1",
          progress: 50,
        },
      }

      # Should not raise and should return nil (notification, no id).
      result = @session.handle(request)
      assert_nil result
    end
  end
end
