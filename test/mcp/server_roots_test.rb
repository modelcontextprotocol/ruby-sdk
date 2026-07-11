# frozen_string_literal: true

require "test_helper"

module MCP
  class ServerRootsTest < ActiveSupport::TestCase
    class MockTransport < Transport
      attr_reader :requests

      def initialize(server)
        super
        @requests = []
      end

      def send_request(method, params = nil)
        @requests << { method: method, params: params }
        {
          roots: [
            { uri: "file:///home/user/projects/myproject", name: "My Project" },
          ],
        }
      end

      def send_response(response); end
      def send_notification(method, params = nil); end
      def open; end
      def close; end
    end

    setup do
      @server = Server.new(
        name: "test_server",
        version: "1.0.0",
      )

      @mock_transport = MockTransport.new(@server)

      @server.handle({
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: {
          protocolVersion: "2025-11-25",
          capabilities: { roots: { listChanged: true } },
          clientInfo: { name: "test-client", version: "1.0" },
        },
      })
    end

    test "roots_list_changed_handler registers callback invoked when notification received" do
      callback_called = false

      @server.roots_list_changed_handler do |_params|
        callback_called = true
      end

      @server.handle({
        jsonrpc: "2.0",
        method: "notifications/roots/list_changed",
      })

      assert callback_called
    end

    test "notifications/roots/list_changed is handled as no-op by default" do
      result = @server.handle({
        jsonrpc: "2.0",
        method: "notifications/roots/list_changed",
      })

      assert_nil result
    end

    test "init stores client capabilities" do
      server = Server.new(name: "test", version: "1.0")
      server.handle({
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: {
          protocolVersion: "2025-11-25",
          capabilities: { roots: { listChanged: true } },
          clientInfo: { name: "test-client", version: "1.0" },
        },
      })

      assert_equal({ roots: { listChanged: true } }, server.client_capabilities)
    end

    test "init rejects params without capabilities and stores nothing" do
      server = Server.new(name: "test", version: "1.0")
      response = server.handle({
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: {
          protocolVersion: "2025-11-25",
          clientInfo: { name: "test-client", version: "1.0" },
        },
      })

      assert_equal(-32602, response[:error][:code])
      assert_nil server.client_capabilities
    end

    test "list_roots uses per-session capabilities via ServerSession" do
      transport = MCP::Server::Transports::StreamableHTTPTransport.new(@server)

      session_with_roots = ServerSession.new(server: @server, transport: transport, session_id: "s1")
      session_with_roots.store_client_info(client: { name: "capable" }, capabilities: { roots: {} })
      transport.instance_variable_get(:@sessions)["s1"] = { stream: nil, server_session: session_with_roots }

      error_with_roots = assert_raises(RuntimeError) do
        capture_io { session_with_roots.list_roots }
      end
      assert_equal("No active stream for roots/list request.", error_with_roots.message)

      session_without_roots = ServerSession.new(server: @server, transport: transport, session_id: "s2")
      session_without_roots.store_client_info(client: { name: "incapable" }, capabilities: {})

      error = assert_raises(RuntimeError) do
        capture_io { session_without_roots.list_roots }
      end
      assert_equal("Client does not support roots.", error.message)
    end

    test "ServerSession#list_roots warns when called without related_request_id" do
      # Per SEP-2260, server-to-client requests must be associated with an originating client request.
      # `$VERBOSE = false` because the rake test task runs with `-W0`, under which `Kernel#warn` emits nothing.
      session = ServerSession.new(server: @server, transport: @mock_transport)
      session.store_client_info(client: { name: "capable" }, capabilities: { roots: {} })

      original_verbose = $VERBOSE
      $VERBOSE = false
      assert_output(nil, /SEP-2260/) { session.list_roots }
    ensure
      $VERBOSE = original_verbose
    end

    test "ServerSession#list_roots does not warn when related_request_id is given" do
      session = ServerSession.new(server: @server, transport: @mock_transport)
      session.store_client_info(client: { name: "capable" }, capabilities: { roots: {} })

      assert_silent { session.list_roots(related_request_id: "req-1") }
    end

    test "ServerSession#client_capabilities falls back to server global capabilities" do
      transport = MCP::Server::Transports::StreamableHTTPTransport.new(@server)

      session = ServerSession.new(server: @server, transport: transport, session_id: "s3")
      transport.instance_variable_get(:@sessions)["s3"] = { stream: nil, server_session: session }

      error = assert_raises(RuntimeError) do
        capture_io { session.list_roots }
      end
      assert_equal("No active stream for roots/list request.", error.message)
    end

    test "session init does not overwrite server global client_capabilities" do
      server = Server.new(name: "test", version: "1.0")
      MockTransport.new(server)

      server.handle({
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: {
          protocolVersion: "2025-11-25",
          capabilities: { roots: {} },
          clientInfo: { name: "first-client", version: "1.0" },
        },
      })

      assert_equal({ roots: {} }, server.client_capabilities)

      transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)
      session = ServerSession.new(server: server, transport: transport, session_id: "s1")

      server.handle(
        {
          jsonrpc: "2.0",
          method: "initialize",
          id: 2,
          params: {
            protocolVersion: "2025-11-25",
            capabilities: {},
            clientInfo: { name: "second-client", version: "1.0" },
          },
        },
        session: session,
      )

      assert_equal({ roots: {} }, server.client_capabilities)
      assert_equal({}, session.client_capabilities)
    end

    test "ServerSession#list_roots uses session-scoped capabilities from HTTP init" do
      server = Server.new(name: "test", version: "1.0")
      transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)

      session = ServerSession.new(server: server, transport: transport, session_id: "s1")
      server.handle(
        {
          jsonrpc: "2.0",
          method: "initialize",
          id: 1,
          params: {
            protocolVersion: "2025-11-25",
            capabilities: { roots: {} },
            clientInfo: { name: "http-client", version: "1.0" },
          },
        },
        session: session,
      )

      transport.instance_variable_get(:@sessions)["s1"] = { stream: nil, server_session: session }
      error = assert_raises(RuntimeError) do
        capture_io { session.list_roots }
      end
      assert_equal("No active stream for roots/list request.", error.message)
    end
  end
end
