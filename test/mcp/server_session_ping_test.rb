# frozen_string_literal: true

require "test_helper"

module MCP
  class ServerSessionPingTest < ActiveSupport::TestCase
    class MockTransport < Transport
      attr_reader :requests
      attr_accessor :response, :error_to_raise

      def initialize(server)
        super
        @requests = []
        @response = {}
        @error_to_raise = nil
      end

      # Matches real transports: returns the `result` body directly (not the full envelope).
      def send_request(method, params = nil, session_id: nil, related_request_id: nil)
        @requests << { method: method, params: params, session_id: session_id, related_request_id: related_request_id }
        raise @error_to_raise if @error_to_raise

        @response
      end

      def send_response(response); end
      def send_notification(method, params = nil); end
      def open; end
      def close; end
      def handle_request(request); end
    end

    setup do
      @server = Server.new(name: "test_server", version: "1.0.0")
      @mock_transport = MockTransport.new(@server)
      @server.transport = @mock_transport
    end

    test "#ping sends request through transport and returns the result hash" do
      session = ServerSession.new(server: @server, transport: @mock_transport)

      result = session.ping

      assert_equal({}, result)
      assert_equal(1, @mock_transport.requests.size)

      request = @mock_transport.requests.first
      assert_equal(Methods::PING, request[:method])
      assert_nil(request[:params])
    end

    test "#ping passes related_request_id through when session_id is set" do
      session = ServerSession.new(server: @server, transport: @mock_transport, session_id: "session-1")

      session.ping(related_request_id: "req-abc")

      request = @mock_transport.requests.first
      assert_equal("session-1", request[:session_id])
      assert_equal("req-abc", request[:related_request_id])
    end

    test "#ping raises ValidationError when result is nil" do
      @mock_transport.response = nil
      session = ServerSession.new(server: @server, transport: @mock_transport)

      error = assert_raises(Server::ValidationError) { session.ping }
      assert_equal("Response validation failed: invalid `result`", error.message)
    end

    test "#ping raises ValidationError when result is the wrong type" do
      @mock_transport.response = "ok"
      session = ServerSession.new(server: @server, transport: @mock_transport)

      error = assert_raises(Server::ValidationError) { session.ping }
      assert_equal("Response validation failed: invalid `result`", error.message)
    end

    test "#ping propagates transport-level errors" do
      @mock_transport.error_to_raise = StandardError.new("read timeout")
      session = ServerSession.new(server: @server, transport: @mock_transport)

      error = assert_raises(StandardError) { session.ping }
      assert_equal("read timeout", error.message)
    end

    test "#ping succeeds without a client capability declaration" do
      session = ServerSession.new(server: @server, transport: @mock_transport)
      assert_nil(session.client_capabilities)

      assert_equal({}, session.ping)
    end
  end
end
