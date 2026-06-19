# frozen_string_literal: true

require "test_helper"

module MCP
  class ServerSamplingTest < ActiveSupport::TestCase
    include InstrumentationTestHelper

    class MockTransport < Transport
      attr_reader :requests

      def initialize(server)
        super
        @requests = []
      end

      def send_request(method, params = nil, **_kwargs)
        @requests << { method: method, params: params }
        {
          role: "assistant",
          content: { type: "text", text: "Response from LLM" },
          model: "test-model",
          stopReason: "endTurn",
        }
      end

      def send_response(response); end
      def send_notification(method, params = nil, **_kwargs); end
      def open; end
      def close; end
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

      @session = ServerSession.new(server: @server, transport: @mock_transport)
      @session.store_client_info(client: { name: "test-client" }, capabilities: { sampling: {} })
    end

    test "create_sampling_message sends request with required params" do
      result = @session.create_sampling_message(
        messages: [{ role: "user", content: { type: "text", text: "Hello" } }],
        max_tokens: 100,
      )

      assert_equal 1, @mock_transport.requests.size
      request = @mock_transport.requests.first
      assert_equal Methods::SAMPLING_CREATE_MESSAGE, request[:method]
      assert_equal 100, request[:params][:maxTokens]
      assert_equal [{ role: "user", content: { type: "text", text: "Hello" } }], request[:params][:messages]

      assert_equal "assistant", result[:role]
      assert_equal "Response from LLM", result[:content][:text]
    end

    test "create_sampling_message sends all optional params" do
      @session.create_sampling_message(
        messages: [{ role: "user", content: { type: "text", text: "Hello" } }],
        max_tokens: 100,
        system_prompt: "You are helpful",
        model_preferences: { intelligencePriority: 0.8 },
        include_context: "none",
        temperature: 0.7,
        stop_sequences: ["STOP"],
        metadata: { key: "value" },
      )

      request = @mock_transport.requests.first
      params = request[:params]

      assert_equal "You are helpful", params[:systemPrompt]
      assert_equal({ intelligencePriority: 0.8 }, params[:modelPreferences])
      assert_equal "none", params[:includeContext]
      assert_equal 0.7, params[:temperature]
      assert_equal ["STOP"], params[:stopSequences]
      assert_equal({ key: "value" }, params[:metadata])
    end

    test "create_sampling_message raises error when client does not support sampling" do
      @session.store_client_info(client: { name: "test-client" }, capabilities: {})

      error = assert_raises(RuntimeError) do
        @session.create_sampling_message(
          messages: [{ role: "user", content: { type: "text", text: "Hello" } }],
          max_tokens: 100,
        )
      end

      assert_equal("Client does not support sampling.", error.message)
    end

    test "create_sampling_message raises error when tools used but client lacks sampling.tools" do
      error = assert_raises(RuntimeError) do
        @session.create_sampling_message(
          messages: [{ role: "user", content: { type: "text", text: "Hello" } }],
          max_tokens: 100,
          tools: [{ name: "test_tool", inputSchema: { type: "object" } }],
        )
      end

      assert_equal("Client does not support sampling with tools.", error.message)
    end

    test "create_sampling_message raises error when tool_choice used alone but client lacks sampling.tools" do
      error = assert_raises(RuntimeError) do
        @session.create_sampling_message(
          messages: [{ role: "user", content: { type: "text", text: "Hello" } }],
          max_tokens: 100,
          tool_choice: { mode: "auto" },
        )
      end

      assert_equal("Client does not support sampling with tool_choice.", error.message)
    end

    test "create_sampling_message allows tools when client has sampling.tools capability" do
      @session.store_client_info(client: { name: "test-client" }, capabilities: { sampling: { tools: {} } })

      result = @session.create_sampling_message(
        messages: [{ role: "user", content: { type: "text", text: "Hello" } }],
        max_tokens: 100,
        tools: [{ name: "test_tool", inputSchema: { type: "object" } }],
        tool_choice: { mode: "auto" },
      )

      request = @mock_transport.requests.first
      params = request[:params]

      assert_equal [{ name: "test_tool", inputSchema: { type: "object" } }], params[:tools]
      assert_equal({ mode: "auto" }, params[:toolChoice])
      assert_equal "Response from LLM", result[:content][:text]
    end

    test "create_sampling_message uses per-session capabilities via ServerSession" do
      transport = MCP::Server::Transports::StreamableHTTPTransport.new(@server)

      # Session with sampling capability passes validation (fails at send_request due to no stream).
      session_with_sampling = ServerSession.new(server: @server, transport: transport, session_id: "s1")
      session_with_sampling.store_client_info(client: { name: "capable" }, capabilities: { sampling: {} })
      transport.instance_variable_get(:@sessions)["s1"] = { stream: nil, server_session: session_with_sampling }

      error_with_sampling = assert_raises(RuntimeError) do
        session_with_sampling.create_sampling_message(
          messages: [{ role: "user", content: { type: "text", text: "Hello" } }],
          max_tokens: 100,
        )
      end
      assert_equal("No active stream for sampling/createMessage request.", error_with_sampling.message)

      # Session without sampling capability should be rejected.
      session_without_sampling = ServerSession.new(server: @server, transport: transport, session_id: "s2")
      session_without_sampling.store_client_info(client: { name: "incapable" }, capabilities: {})

      error = assert_raises(RuntimeError) do
        session_without_sampling.create_sampling_message(
          messages: [{ role: "user", content: { type: "text", text: "Hello" } }],
          max_tokens: 100,
        )
      end
      assert_equal("Client does not support sampling.", error.message)
    end

    test "ServerSession#client_capabilities falls back to server global capabilities" do
      transport = MCP::Server::Transports::StreamableHTTPTransport.new(@server)

      # Initialize server with sampling capability.
      @server.handle({
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: {
          protocolVersion: "2025-11-25",
          capabilities: { sampling: {} },
          clientInfo: { name: "test-client", version: "1.0" },
        },
      })

      # Session without capabilities stored falls back to @server.client_capabilities.
      session = ServerSession.new(server: @server, transport: transport, session_id: "s3")
      transport.instance_variable_get(:@sessions)["s3"] = { stream: nil, server_session: session }

      # Server was initialized with sampling capability, so fallback should pass validation.
      error = assert_raises(RuntimeError) do
        session.create_sampling_message(
          messages: [{ role: "user", content: { type: "text", text: "Hello" } }],
          max_tokens: 100,
        )
      end
      assert_equal("No active stream for sampling/createMessage request.", error.message)
    end

    test "session init does not overwrite server global client_capabilities" do
      server = Server.new(name: "test", version: "1.0")
      # Assigns server.transport via Transport#initialize.
      MockTransport.new(server)

      # Non-session init sets global capabilities.
      server.handle({
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: {
          protocolVersion: "2025-11-25",
          capabilities: { sampling: {} },
          clientInfo: { name: "first-client", version: "1.0" },
        },
      })

      assert_equal({ sampling: {} }, server.client_capabilities)

      # Session-scoped init must NOT overwrite global capabilities.
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

      # Global must still have sampling.
      assert_equal({ sampling: {} }, server.client_capabilities)
      # Session must have its own (empty) capabilities.
      assert_equal({}, session.client_capabilities)
    end

    test "create_sampling_message omits nil optional params" do
      @session.create_sampling_message(
        messages: [{ role: "user", content: { type: "text", text: "Hello" } }],
        max_tokens: 100,
        system_prompt: nil,
        temperature: nil,
      )

      request = @mock_transport.requests.first
      params = request[:params]

      refute params.key?(:systemPrompt)
      refute params.key?(:temperature)
      assert params.key?(:messages)
      assert params.key?(:maxTokens)
    end
  end
end
