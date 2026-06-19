# frozen_string_literal: true

require "test_helper"

module MCP
  class ServerElicitationTest < ActiveSupport::TestCase
    include InstrumentationTestHelper

    class MockTransport < Transport
      attr_reader :requests, :notifications

      def initialize(server)
        super
        @requests = []
        @notifications = []
      end

      def send_request(method, params = nil, **_kwargs)
        @requests << { method: method, params: params }
        { action: "accept" }
      end

      def send_response(response); end

      def send_notification(method, params = nil, **_kwargs)
        @notifications << { method: method, params: params }
      end

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

      @session = ServerSession.new(server: @server, transport: @mock_transport)
      @session.instance_variable_set(:@client_capabilities, { elicitation: {} })
    end

    test "#create_form_elicitation sends request through transport" do
      result = @session.create_form_elicitation(
        message: "Please provide your name",
        requested_schema: {
          type: "object",
          properties: {
            name: { type: "string" },
          },
          required: ["name"],
        },
      )

      assert_equal 1, @mock_transport.requests.size

      request = @mock_transport.requests.first

      assert_equal Methods::ELICITATION_CREATE, request[:method]
      assert_equal "form", request[:params][:mode]
      assert_equal "Please provide your name", request[:params][:message]
      assert_equal "object", request[:params][:requestedSchema][:type]
      assert_equal({ action: "accept" }, result)
    end

    test "#create_form_elicitation raises error when client does not support elicitation" do
      @session.instance_variable_set(:@client_capabilities, {})

      error = assert_raises(RuntimeError) do
        @session.create_form_elicitation(
          message: "Please provide your name",
          requested_schema: { type: "object", properties: { name: { type: "string" } } },
        )
      end

      assert_equal(
        "Client does not support elicitation. The client must declare the `elicitation` capability during initialization.",
        error.message,
      )
    end

    test "#create_form_elicitation raises error when client capabilities are nil" do
      @session.instance_variable_set(:@client_capabilities, nil)
      @server.instance_variable_set(:@client_capabilities, nil)

      error = assert_raises(RuntimeError) do
        @session.create_form_elicitation(
          message: "Please provide your name",
          requested_schema: { type: "object", properties: { name: { type: "string" } } },
        )
      end

      assert_equal(
        "Client does not support elicitation. The client must declare the `elicitation` capability during initialization.",
        error.message,
      )
    end

    test "#create_url_elicitation sends url mode request through transport" do
      @session.instance_variable_set(:@client_capabilities, { elicitation: { url: {} } })

      result = @session.create_url_elicitation(
        message: "Please authorize access",
        url: "https://example.com/oauth",
        elicitation_id: "abc-123",
      )

      assert_equal 1, @mock_transport.requests.size

      request = @mock_transport.requests.first

      assert_equal Methods::ELICITATION_CREATE, request[:method]
      assert_equal "url", request[:params][:mode]
      assert_equal "Please authorize access", request[:params][:message]
      assert_equal "https://example.com/oauth", request[:params][:url]
      assert_equal "abc-123", request[:params][:elicitationId]
      assert_equal({ action: "accept" }, result)
    end

    test "#create_url_elicitation raises error when client does not support url mode" do
      error = assert_raises(RuntimeError) do
        @session.create_url_elicitation(
          message: "Please authorize access",
          url: "https://example.com/oauth",
          elicitation_id: "abc-123",
        )
      end

      assert_equal(
        "Client does not support URL mode elicitation. The client must declare the `elicitation.url` capability during initialization.",
        error.message,
      )
    end

    test "#create_url_elicitation raises error when client capabilities are nil" do
      @session.instance_variable_set(:@client_capabilities, nil)
      @server.instance_variable_set(:@client_capabilities, nil)

      error = assert_raises(RuntimeError) do
        @session.create_url_elicitation(
          message: "Please authorize access",
          url: "https://example.com/oauth",
          elicitation_id: "abc-123",
        )
      end

      assert_equal(
        "Client does not support URL mode elicitation. The client must declare the `elicitation.url` capability during initialization.",
        error.message,
      )
    end

    test "#notify_elicitation_complete sends notification through transport" do
      @session.notify_elicitation_complete(elicitation_id: "abc-123")

      assert_equal 1, @mock_transport.notifications.size

      notification = @mock_transport.notifications.first

      assert_equal Methods::NOTIFICATIONS_ELICITATION_COMPLETE, notification[:method]
      assert_equal "abc-123", notification[:params][:elicitationId]
    end

    test "URLElicitationRequiredError can be raised from a tool handler" do
      @server.define_tool(name: "needs_auth", description: "Needs OAuth") do
        raise Server::URLElicitationRequiredError, [
          { mode: "url", elicitationId: "abc-123", url: "https://example.com/oauth", message: "Auth required" },
        ]
      end

      response = JSON.parse(@server.handle_json(JSON.generate({
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: { name: "needs_auth", arguments: {} },
      })))

      assert_equal(-32042, response["error"]["code"])
      assert_equal "URL elicitation required", response["error"]["message"]

      elicitations = response["error"]["data"]["elicitations"]

      assert_equal 1, elicitations.size
      assert_equal "abc-123", elicitations.first["elicitationId"]

      assert_instrumentation_data(
        method: "tools/call", tool_name: "needs_auth", tool_arguments: {}, error: :url_elicitation_required,
      )
    end
  end
end
