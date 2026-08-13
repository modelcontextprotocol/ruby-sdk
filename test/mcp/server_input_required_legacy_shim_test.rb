# frozen_string_literal: true

require "test_helper"

module MCP
  # The SEP-2322 dual-era authoring shim: a handler returning an `InputRequiredResult`
  # on the legacy wire is fulfilled through real server-to-client requests and re-run,
  # so handlers written in the 2026 style serve pre-2026 clients too.
  class ServerInputRequiredLegacyShimTest < ActiveSupport::TestCase
    # Answers every server-to-client request like a cooperative client and records what was sent.
    class AnsweringTransport
      attr_reader :sent

      def initialize(answers = {})
        @answers = answers
        @sent = []
      end

      def send_request(method, params = nil, related_request_id: nil)
        @sent << { method: method, params: params, related_request_id: related_request_id }
        @answers.fetch(method) do
          case method
          when Methods::ELICITATION_CREATE
            { action: "accept", content: { name: "Koichi" } }
          when Methods::ROOTS_LIST
            { roots: [{ uri: "file:///workspace", name: "workspace" }] }
          when Methods::SAMPLING_CREATE_MESSAGE
            { role: "assistant", content: { type: "text", text: "sampled" }, model: "test-model" }
          end
        end
      end

      def send_notification(method, params = nil, session_id: nil, related_request_id: nil)
        true
      end
    end

    # Raises like the bundled transports when the client answers a server-to-client request
    # with a JSON-RPC error.
    class RejectingTransport
      def send_request(method, params = nil, related_request_id: nil)
        raise StandardError, "Client returned an error for #{method} request (code: -1): User rejected"
      end

      def send_notification(method, params = nil, session_id: nil, related_request_id: nil)
        true
      end
    end

    setup do
      @greeting_tool = Tool.define(name: "greeter") do |server_context:|
        answer = server_context.input_response("who")
        if answer
          Tool::Response.new([{ type: "text", text: "Hello, #{answer.dig(:content, :name)}!" }])
        else
          Server::InputRequiredResult.new(
            input_requests: { "who" => { method: Methods::ELICITATION_CREATE, params: { message: "Who?" } } },
            request_state: "round-1",
          )
        end
      end
    end

    test "a legacy tools/call is fulfilled through a real elicitation and completes" do
      transport = AnsweringTransport.new
      session = legacy_session(tools: [@greeting_tool], transport: transport)

      response = session.handle(tool_call_request)

      assert_equal "Hello, Koichi!", response.dig(:result, :content, 0, :text)
      refute response[:result].key?(:resultType)

      sent = transport.sent.first
      assert_equal Methods::ELICITATION_CREATE, sent[:method]
      assert_equal({ message: "Who?" }, sent[:params])

      # SEP-2260: the fulfilment request stays associated with the originating request.
      assert_equal 1, sent[:related_request_id]
    end

    test "the handler re-runs with the collected responses and the raw requestState" do
      seen = []
      tool = Tool.define(name: "stateful") do |server_context:|
        seen << { responses: server_context.input_responses, state: server_context.request_state }
        if server_context.request_state == "opaque-state"
          Tool::Response.new([{ type: "text", text: "resumed" }])
        else
          Server::InputRequiredResult.new(
            input_requests: { "k" => { method: Methods::ELICITATION_CREATE, params: { message: "?" } } },
            request_state: "opaque-state",
          )
        end
      end
      session = legacy_session(tools: [tool], transport: AnsweringTransport.new)

      response = session.handle(tool_call_request(name: "stateful"))

      assert_equal "resumed", response.dig(:result, :content, 0, :text)
      assert_equal 2, seen.size
      assert_nil seen.first[:responses]
      assert_equal "opaque-state", seen.last[:state]
      assert_equal({ action: "accept", content: { name: "Koichi" } }, seen.last[:responses]["k"])
    end

    test "the shim bypasses requestState sealing" do
      seen_state = nil
      tool = Tool.define(name: "sealed") do |server_context:|
        if server_context.request_state
          seen_state = server_context.request_state
          Tool::Response.new([{ type: "text", text: "done" }])
        else
          Server::InputRequiredResult.new(
            input_requests: { "k" => { method: Methods::ELICITATION_CREATE, params: { message: "?" } } },
            request_state: "plain-state",
          )
        end
      end
      security = Server::RequestStateSecurity.new(key: "k" * 32)
      session = legacy_session(tools: [tool], transport: AnsweringTransport.new, request_state_security: security)

      response = session.handle(tool_call_request(name: "sealed"))

      assert_equal "done", response.dig(:result, :content, 0, :text)

      # In-process replay round-trips the handler's own value; sealing is wire hardening.
      assert_equal "plain-state", seen_state
    end

    test "prompts/get and resources/read are shimmed too" do
      prompt = Prompt.define(name: "greeting_prompt") do |_args, server_context:|
        if server_context.input_response("who")
          Prompt::Result.new(messages: [Prompt::Message.new(role: "user", content: Content::Text.new("hi"))])
        else
          Server::InputRequiredResult.new(
            input_requests: { "who" => { method: Methods::ELICITATION_CREATE, params: { message: "Who?" } } },
          )
        end
      end
      server = Server.new(name: "shim_test", prompts: [prompt], resources: [])
      server.resources_read_handler do |params|
        # `server_context` is unavailable in this handler shape, so park once via the params-visible retry fields instead.
        if params[:inputResponses]
          [{ uri: params[:uri], mimeType: "text/plain", text: "read" }]
        else
          Server::InputRequiredResult.new(
            input_requests: { "who" => { method: Methods::ELICITATION_CREATE, params: { message: "Who?" } } },
          )
        end
      end
      transport = AnsweringTransport.new
      session = ServerSession.new(server: server, transport: transport, session_id: "legacy")
      session.store_client_info(client: { name: "legacy" }, capabilities: { elicitation: { form: {} } })

      prompt_response = session.handle(
        { jsonrpc: "2.0", id: 10, method: Methods::PROMPTS_GET, params: { name: "greeting_prompt" } },
      )
      assert_equal "hi", prompt_response.dig(:result, :messages, 0, :content, :text)

      read_response = session.handle(
        { jsonrpc: "2.0", id: 11, method: Methods::RESOURCES_READ, params: { uri: "file:///a.txt" } },
      )
      assert_equal "read", read_response.dig(:result, :contents, 0, :text)
    end

    test "multiple rounds collect each round's answers" do
      rounds = []
      tool = Tool.define(name: "two_rounds") do |server_context:|
        rounds << server_context.input_responses&.keys
        if server_context.input_response("second")
          Tool::Response.new([{ type: "text", text: "done" }])
        elsif server_context.input_response("first")
          Server::InputRequiredResult.new(
            input_requests: { "second" => { method: Methods::ELICITATION_CREATE, params: { message: "2?" } } },
            request_state: "after-first",
          )
        else
          Server::InputRequiredResult.new(
            input_requests: { "first" => { method: Methods::ELICITATION_CREATE, params: { message: "1?" } } },
          )
        end
      end
      session = legacy_session(tools: [tool], transport: AnsweringTransport.new)

      response = session.handle(tool_call_request(name: "two_rounds"))

      assert_equal "done", response.dig(:result, :content, 0, :text)
      assert_equal [nil, ["first"], ["second"]], rounds
    end

    test "a url-mode elicitation leg gains the elicitationId the legacy wire requires" do
      # The 2026-07-28 in-band shape has no `elicitationId` (correlation rides `requestState`),
      # but the 2025-11-25 wire requires the field on URL-mode elicitation requests.
      transport = AnsweringTransport.new
      tool = Tool.define(name: "url_asker") do |server_context:|
        if server_context.input_response("auth")
          Tool::Response.new([{ type: "text", text: "authed" }])
        else
          Server::InputRequiredResult.new(
            input_requests: {
              "auth" => {
                method: Methods::ELICITATION_CREATE,
                params: { mode: "url", url: "https://example.com/auth", message: "Sign in" },
              },
            },
          )
        end
      end
      session = legacy_session(tools: [tool], transport: transport, capabilities: { elicitation: { url: {} } })

      response = session.handle(tool_call_request(name: "url_asker"))

      assert_equal "authed", response.dig(:result, :content, 0, :text)
      sent = transport.sent.first
      assert_equal "https://example.com/auth", sent[:params][:url]
      refute_nil sent[:params][:elicitationId]
    end

    test "a handler-supplied elicitationId rides the leg unchanged" do
      transport = AnsweringTransport.new
      tool = Tool.define(name: "url_asker") do |server_context:|
        if server_context.input_response("auth")
          Tool::Response.new([{ type: "text", text: "authed" }])
        else
          Server::InputRequiredResult.new(
            input_requests: {
              "auth" => {
                method: Methods::ELICITATION_CREATE,
                params: { mode: "url", url: "https://example.com/auth", elicitationId: "mine" },
              },
            },
          )
        end
      end
      session = legacy_session(tools: [tool], transport: transport, capabilities: { elicitation: { url: {} } })

      session.handle(tool_call_request(name: "url_asker"))

      assert_equal "mine", transport.sent.first[:params][:elicitationId]
    end

    test "a client answering a fulfilment leg with an error fails the original request" do
      session = legacy_session(tools: [@greeting_tool], transport: RejectingTransport.new)

      response = session.handle(tool_call_request)

      assert_equal(-32603, response.dig(:error, :code))
    end

    test "a handler that never completes fails after the round cap" do
      tool = Tool.define(name: "greedy") do |server_context:|
        round = (server_context.request_state || "0").to_i + 1
        Server::InputRequiredResult.new(
          input_requests: { "k#{round}" => { method: Methods::ELICITATION_CREATE, params: { message: "?" } } },
          request_state: round.to_s,
        )
      end
      session = legacy_session(tools: [tool], transport: AnsweringTransport.new)

      response = session.handle(tool_call_request(name: "greedy"))

      assert_equal(-32603, response.dig(:error, :code))
      assert_match(/#{Server::LEGACY_INPUT_REQUIRED_MAX_ROUNDS} legacy shim rounds/, response.dig(:error, :message))
    end

    test "embedded requests exceeding the declared capabilities fail without contacting the client" do
      transport = AnsweringTransport.new
      session = legacy_session(tools: [@greeting_tool], transport: transport, capabilities: {})

      response = session.handle(tool_call_request)

      assert_equal(-32603, response.dig(:error, :code))
      assert_match(/elicitation/, response.dig(:error, :message))
      assert_empty transport.sent
    end

    test "opting out restores the strict legacy rejection" do
      session = legacy_session(
        tools: [@greeting_tool],
        transport: AnsweringTransport.new,
        input_required_legacy_shim: false,
      )

      response = session.handle(tool_call_request)

      assert_equal(-32603, response.dig(:error, :code))
    end

    test "a session-less legacy request is still rejected" do
      server = Server.new(name: "shim_test", tools: [@greeting_tool])

      response = server.handle(tool_call_request)

      assert_equal(-32603, response.dig(:error, :code))
    end

    test "modern requests keep the input_required result untouched" do
      session = legacy_session(tools: [@greeting_tool], transport: transport = AnsweringTransport.new)

      response = session.handle({
        jsonrpc: "2.0",
        id: 1,
        method: Methods::TOOLS_CALL,
        params: {
          name: "greeter",
          arguments: {},
          _meta: {
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientInfo": { name: "modern", version: "1" },
            "io.modelcontextprotocol/clientCapabilities": { elicitation: { form: {} } },
          },
        },
      })

      assert_equal "input_required", response.dig(:result, :resultType)
      assert_empty transport.sent
    end

    private

    def legacy_session(tools:, transport:, capabilities: { elicitation: { form: {} } },
      input_required_legacy_shim: true, request_state_security: nil)
      server = Server.new(
        name: "shim_test",
        tools: tools,
        input_required_legacy_shim: input_required_legacy_shim,
        request_state_security: request_state_security,
      )
      session = ServerSession.new(server: server, transport: transport, session_id: "legacy")
      session.store_client_info(client: { name: "legacy" }, capabilities: capabilities)
      session
    end

    def tool_call_request(name: "greeter")
      { jsonrpc: "2.0", id: 1, method: Methods::TOOLS_CALL, params: { name: name, arguments: {} } }
    end
  end
end
