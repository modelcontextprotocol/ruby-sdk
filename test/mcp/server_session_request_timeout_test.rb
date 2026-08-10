# frozen_string_literal: true

require "test_helper"

module MCP
  # Every server-to-client request accepts a per-request deadline, which the spec asks SDKs to offer
  # ("SDKs and other middleware SHOULD allow these timeouts to be configured on a per-request basis").
  # `ServerSession` only carries the value; the transport is what waits on it.
  class ServerSessionRequestTimeoutTest < ActiveSupport::TestCase
    # Declares `timeout:`, as the bundled Streamable HTTP transport does.
    class TimeoutAwareTransport < Transport
      attr_reader :requests

      def initialize(server)
        super
        @requests = []
      end

      def send_request(method, params = nil, session_id: nil, related_request_id: nil, parent_cancellation: nil, server_session: nil, timeout: nil)
        @requests << { method: method, timeout: timeout }
        {}
      end

      def send_response(response); end
      def send_notification(method, params = nil, **_kwargs); end
      def open; end
      def close; end
      def handle_request(request); end
    end

    # Implements only the abstract `send_request(method, params = nil)` contract, as `StdioTransport` does.
    class TimeoutUnawareTransport < TimeoutAwareTransport
      def send_request(method, params = nil)
        @requests << { method: method, timeout: :not_passed }
        {}
      end
    end

    setup do
      @server = Server.new(name: "test_server", version: "1.0.0")
      @transport = TimeoutAwareTransport.new(@server)
      @session = ServerSession.new(server: @server, transport: @transport, session_id: "session-1")
      @session.instance_variable_set(
        :@client_capabilities,
        { roots: {}, sampling: {}, elicitation: { url: {} } },
      )
    end

    test "every server-to-client request carries its timeout down to the transport" do
      @session.ping(related_request_id: "req-1", timeout: 11)
      @session.list_roots(related_request_id: "req-1", timeout: 22)
      @session.create_sampling_message(
        related_request_id: "req-1",
        timeout: 33,
        messages: [{ role: "user", content: { type: "text", text: "Hello" } }],
        max_tokens: 100,
      )
      @session.create_form_elicitation(
        message: "Approve?",
        requested_schema: { type: "object", properties: {} },
        related_request_id: "req-1",
        timeout: 44,
      )
      @session.create_url_elicitation(
        message: "Approve?",
        url: "https://example.com/approve",
        elicitation_id: "elicit-1",
        related_request_id: "req-1",
        timeout: 55,
      )

      assert_equal(
        [
          { method: "ping", timeout: 11 },
          { method: "roots/list", timeout: 22 },
          { method: "sampling/createMessage", timeout: 33 },
          { method: "elicitation/create", timeout: 44 },
          { method: "elicitation/create", timeout: 55 },
        ],
        @transport.requests,
      )
    end

    test "an omitted timeout leaves the transport to apply its own default" do
      @session.ping(related_request_id: "req-1")

      assert_equal [{ method: "ping", timeout: nil }], @transport.requests
    end

    test "a transport that does not declare timeout keeps its existing signature" do
      transport = TimeoutUnawareTransport.new(@server)
      session = ServerSession.new(server: @server, transport: transport, session_id: "session-1")

      session.ping(related_request_id: "req-1", timeout: 11)

      assert_equal [{ method: "ping", timeout: :not_passed }], transport.requests
    end
  end
end
