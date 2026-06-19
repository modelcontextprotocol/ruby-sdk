# frozen_string_literal: true

require "test_helper"

module MCP
  class ServerCancellationTest < ActiveSupport::TestCase
    include InstrumentationTestHelper

    class MockTransport < Transport
      attr_reader :requests, :notifications, :cancelled_request_ids

      def initialize(server)
        super
        @requests = []
        @notifications = []
        @cancelled_request_ids = []
      end

      def send_request(method, params = nil, **_kwargs)
        @requests << { method: method, params: params }
        {}
      end

      def send_notification(method, params = nil, **_kwargs)
        @notifications << { method: method, params: params }
        true
      end

      def cancel_pending_request(request_id, reason: nil)
        @cancelled_request_ids << request_id
      end

      def send_response(response); end
      def open; end
      def close; end
      def handle_request(request); end
    end

    setup do
      configuration = MCP::Configuration.new
      configuration.instrumentation_callback = instrumentation_helper.callback

      @server = Server.new(name: "test_server", version: "1.0.0", configuration: configuration)
      @mock_transport = MockTransport.new(@server)
      @server.transport = @mock_transport
      @session = ServerSession.new(server: @server, transport: @mock_transport, session_id: "sess-1")
    end

    test "cooperative cancellation via server_context suppresses response" do
      observed_cancelled = false

      @server.define_tool(name: "slow") do |server_context:|
        20.times do
          break if server_context.cancelled?

          sleep(0.01)
        end
        observed_cancelled = server_context.cancelled?
        Tool::Response.new([{ type: "text", text: "ok" }])
      end

      request_id = 42

      call_thread = Thread.new do
        @session.handle(
          jsonrpc: "2.0",
          id: request_id,
          method: Methods::TOOLS_CALL,
          params: { name: "slow", arguments: {} },
        )
      end

      sleep(0.02) until @session.lookup_in_flight(request_id)

      @session.handle(
        jsonrpc: "2.0",
        method: Methods::NOTIFICATIONS_CANCELLED,
        params: { requestId: request_id, reason: "user aborted" },
      )

      response = call_thread.value

      assert observed_cancelled, "tool handler should observe cancellation"
      assert_nil response, "cancelled request must not emit a JSON-RPC response"
    end

    test "tool raising CancelledError via raise_if_cancelled! suppresses the JSON-RPC response" do
      @server.define_tool(name: "raising") do |server_context:|
        50.times do
          server_context.raise_if_cancelled!
          sleep(0.01)
        end
        Tool::Response.new([{ type: "text", text: "ok" }])
      end

      request_id = 99

      call_thread = Thread.new do
        @session.handle(
          jsonrpc: "2.0",
          id: request_id,
          method: Methods::TOOLS_CALL,
          params: { name: "raising", arguments: {} },
        )
      end

      sleep(0.02) until @session.lookup_in_flight(request_id)

      @session.handle(
        jsonrpc: "2.0",
        method: Methods::NOTIFICATIONS_CANCELLED,
        params: { requestId: request_id, reason: "raised" },
      )

      response = call_thread.value

      assert_nil response, "raise_if_cancelled! must result in no JSON-RPC response"
    end

    test "CancelledError raised from nested server-to-client call suppresses response" do
      @server.define_tool(name: "nesting") do |server_context:| # rubocop:disable Lint/UnusedBlockArgument
        # Simulate a transport-level CancelledError coming back from a nested
        # send_request (e.g. sampling/createMessage after parent was cancelled).
        raise MCP::CancelledError.new(request_id: "nested-xyz", reason: "parent aborted")
      end

      response = @session.handle(
        jsonrpc: "2.0",
        id: 123,
        method: Methods::TOOLS_CALL,
        params: { name: "nesting", arguments: {} },
      )

      assert_nil response, "CancelledError propagating from a nested call must suppress the JSON-RPC response"
    end

    test "cancellation with unknown request id is silently ignored" do
      response = @session.handle(
        jsonrpc: "2.0",
        method: Methods::NOTIFICATIONS_CANCELLED,
        params: { requestId: "does-not-exist" },
      )

      assert_nil response
    end

    test "duplicate cancellation for the same in-flight request is idempotent" do
      @server.define_tool(name: "slow_dup") do |server_context:|
        20.times do
          break if server_context.cancelled?

          sleep(0.01)
        end
        Tool::Response.new([{ type: "text", text: "ok" }])
      end

      request_id = 51

      call_thread = Thread.new do
        @session.handle(
          jsonrpc: "2.0",
          id: request_id,
          method: Methods::TOOLS_CALL,
          params: { name: "slow_dup", arguments: {} },
        )
      end

      sleep(0.02) until @session.lookup_in_flight(request_id)

      first = @session.handle(
        jsonrpc: "2.0",
        method: Methods::NOTIFICATIONS_CANCELLED,
        params: { requestId: request_id, reason: "first" },
      )

      second = @session.handle(
        jsonrpc: "2.0",
        method: Methods::NOTIFICATIONS_CANCELLED,
        params: { requestId: request_id, reason: "second" },
      )

      response = call_thread.value

      assert_nil first
      assert_nil second, "duplicate cancel must not emit a response"
      assert_nil response, "cancelled request must not emit a response"
    end

    test "cancellation arriving after the request already completed is silently ignored" do
      @server.define_tool(name: "quick") do
        Tool::Response.new([{ type: "text", text: "done" }])
      end

      request_id = 61

      response = @session.handle(
        jsonrpc: "2.0",
        id: request_id,
        method: Methods::TOOLS_CALL,
        params: { name: "quick", arguments: {} },
      )

      assert response, "the tool should have completed successfully before the cancel arrives"
      assert_nil @session.lookup_in_flight(request_id), "completed request must be unregistered"

      late = @session.handle(
        jsonrpc: "2.0",
        method: Methods::NOTIFICATIONS_CANCELLED,
        params: { requestId: request_id, reason: "late" },
      )

      assert_nil late, "late cancel for a completed request must be silently ignored"
    end

    test "initialize request cannot be cancelled" do
      init_params = {
        protocolVersion: Configuration::LATEST_STABLE_PROTOCOL_VERSION,
        clientInfo: { name: "test", version: "1.0" },
        capabilities: {},
      }

      response = @session.handle(
        jsonrpc: "2.0",
        id: "init-1",
        method: Methods::INITIALIZE,
        params: init_params,
      )

      assert response, "initialize returns a response"
      assert response[:result][:protocolVersion]
      # The initialize request is not registered in the in-flight map.
      assert_nil @session.lookup_in_flight("init-1")
    end

    test "ServerSession#cancel_request sends notification and cancels pending" do
      @session.cancel_request(request_id: "req-9", reason: "timeout")

      notification = @mock_transport.notifications.last
      assert_equal Methods::NOTIFICATIONS_CANCELLED, notification[:method]
      assert_equal "req-9", notification[:params][:requestId]
      assert_equal "timeout", notification[:params][:reason]

      assert_includes @mock_transport.cancelled_request_ids, "req-9"
    end

    test "parent cancellation propagates to nested server-to-client requests" do
      @session.instance_variable_set(:@client_capabilities, { elicitation: {} })

      parent_request_id = 101
      cancellation = @session.register_in_flight(parent_request_id)

      # Simulate a nested sampling/elicitation send via ServerSession. The transport
      # is expected to receive `parent_cancellation:` and `server_session:` kwargs so
      # it can install an `on_cancel` hook. Here we assert those kwargs are forwarded.
      recorded = {}
      (class << @mock_transport; self; end).define_method(:send_request) do |method, _params = nil, **kwargs|
        recorded[:method] = method
        recorded[:kwargs] = kwargs
        {}
      end

      @session.create_form_elicitation(
        message: "ignored",
        requested_schema: { type: "object", properties: {} },
        related_request_id: parent_request_id,
      )

      assert_equal Methods::ELICITATION_CREATE, recorded[:method]
      assert_equal parent_request_id, recorded[:kwargs][:related_request_id]
      assert_same cancellation, recorded[:kwargs][:parent_cancellation]
      assert_same @session, recorded[:kwargs][:server_session]
    end

    test "cancellation reason is recorded in instrumentation data" do
      recorded_data = nil
      @server.configuration.instrumentation_callback = ->(data) { recorded_data = data }

      @server.define_tool(name: "slow_with_reason") do |server_context:|
        50.times do
          break if server_context.cancelled?

          sleep(0.01)
        end
        Tool::Response.new([{ type: "text", text: "ok" }])
      end

      request_id = 77

      call_thread = Thread.new do
        @session.handle(
          jsonrpc: "2.0",
          id: request_id,
          method: Methods::TOOLS_CALL,
          params: { name: "slow_with_reason", arguments: {} },
        )
      end

      sleep(0.02) until @session.lookup_in_flight(request_id)

      @session.handle(
        jsonrpc: "2.0",
        method: Methods::NOTIFICATIONS_CANCELLED,
        params: { requestId: request_id, reason: "explicit reason string" },
      )

      call_thread.value

      assert recorded_data
      assert recorded_data[:cancelled]
      assert_equal "explicit reason string", recorded_data[:cancellation_reason]
    end

    # Helper for the non-tools cancellation regression tests below. Spawns a background
    # request, waits for the in-flight entry, sends `notifications/cancelled`, and
    # returns [response, thread_result_flag_yielded_by_block].
    def drive_cancellation(request_id:, method:, params:)
      result_flag = { observed: false }
      call_thread = Thread.new do
        @session.handle(jsonrpc: "2.0", id: request_id, method: method, params: params)
      end

      sleep(0.02) until @session.lookup_in_flight(request_id)

      yield(result_flag) if block_given?

      @session.handle(
        jsonrpc: "2.0",
        method: Methods::NOTIFICATIONS_CANCELLED,
        params: { requestId: request_id, reason: "caller aborted" },
      )

      [call_thread.value, result_flag]
    end

    test "resources/read handler that opts in to server_context observes cancellation" do
      observed = false
      @server.resources_read_handler do |_params, server_context:|
        50.times do
          break if server_context.cancelled?

          sleep(0.01)
        end
        observed = server_context.cancelled?
        [{ uri: "test://resource", text: "done" }]
      end

      response, = drive_cancellation(
        request_id: 201,
        method: Methods::RESOURCES_READ,
        params: { uri: "test://resource" },
      )

      assert observed, "resources/read handler should observe cancellation via server_context"
      assert_nil response, "cancelled resources/read must not emit a JSON-RPC response"
    end

    test "completion/complete handler that opts in to server_context observes cancellation" do
      observed = false
      @server.capabilities[:completions] = {}
      @server.completion_handler do |_params, server_context:|
        50.times do
          break if server_context.cancelled?

          sleep(0.01)
        end
        observed = server_context.cancelled?
        { completion: { values: ["v"], hasMore: false } }
      end

      # completion/complete requires a known ref; register a dummy prompt.
      @server.define_prompt(name: "dummy") { MCP::Prompt::Result.new(messages: []) }

      response, = drive_cancellation(
        request_id: 202,
        method: Methods::COMPLETION_COMPLETE,
        params: { ref: { type: "ref/prompt", name: "dummy" }, argument: { name: "arg", value: "" } },
      )

      assert observed, "completion/complete handler should observe cancellation via server_context"
      assert_nil response, "cancelled completion/complete must not emit a JSON-RPC response"
    end

    test "prompts/get template that opts in to server_context observes cancellation" do
      observed = false
      prompt_class = Class.new(MCP::Prompt) do
        prompt_name "slow_prompt"

        define_singleton_method(:template) do |_args, server_context:|
          50.times do
            break if server_context.cancelled?

            sleep(0.01)
          end
          observed = server_context.cancelled?
          MCP::Prompt::Result.new(messages: [])
        end
      end
      @server.prompts[prompt_class.name_value] = prompt_class
      # Share `observed` between the closure above and the test scope.
      @server.singleton_class.define_method(:_test_observed) { observed }

      response, = drive_cancellation(
        request_id: 203,
        method: Methods::PROMPTS_GET,
        params: { name: "slow_prompt" },
      )

      assert observed, "prompt template should observe cancellation via server_context"
      assert_nil response, "cancelled prompts/get must not emit a JSON-RPC response"
    end

    test "send_to_transport (notifications) works with a custom transport that only implements the abstract signature" do
      # Regression: `ServerSession#send_to_transport` must not assume the
      # transport's `send_notification` accepts the new kwargs
      # (`session_id:` / `related_request_id:`). Custom transports that
      # implement the abstract `Transport#send_notification(method, params = nil)`
      # contract must keep working - this is exercised via `cancel_request` /
      # `send_peer_cancellation` which the cancellation feature relies on.
      minimal_transport = Class.new(Transport) do
        attr_reader :recorded

        def initialize(server)
          super
          @recorded = []
        end

        def send_notification(method, params = nil)
          @recorded << [method, params]
          true
        end

        def send_request(method, params = nil)
          @recorded << [method, params]
          {}
        end

        def send_response(_); end
        def open; end
        def close; end
      end.new(@server)

      session = ServerSession.new(server: @server, transport: minimal_transport)

      assert_nothing_raised do
        session.cancel_request(request_id: "req-1", reason: "timeout")
      end

      recorded = minimal_transport.recorded.last
      assert_equal Methods::NOTIFICATIONS_CANCELLED, recorded[0]
      assert_equal "req-1", recorded[1][:requestId]
      assert_equal "timeout", recorded[1][:reason]
    end

    test "send_to_transport_request works with a custom transport that only implements the abstract signature" do
      # Regression: `ServerSession#send_to_transport_request` must not assume
      # the transport's `send_request` accepts the new kwargs
      # (`session_id:` / `related_request_id:` / `parent_cancellation:` /
      # `server_session:`). Custom transports that implement the abstract
      # `Transport#send_request(method, params = nil)` contract must keep working.
      minimal_transport = Class.new(Transport) do
        attr_reader :recorded

        def initialize(server)
          super
          @recorded = []
        end

        def send_request(method, params = nil)
          @recorded << [method, params]
          {} # fake response
        end

        def send_notification(method, params = nil)
          @recorded << [method, params]
          true
        end

        def send_response(_); end
        def open; end
        def close; end
      end.new(@server)

      session = ServerSession.new(server: @server, transport: minimal_transport)
      session.instance_variable_set(:@client_capabilities, { sampling: {} })

      assert_nothing_raised do
        session.create_sampling_message(
          messages: [{ role: "user", content: { type: "text", text: "hi" } }],
          max_tokens: 10,
        )
      end

      recorded = minimal_transport.recorded.last
      assert_equal Methods::SAMPLING_CREATE_MESSAGE, recorded[0]
      refute_nil recorded[1]
    end

    test "tool with positional `server_context` parameter is not auto-opted-in" do
      # Regression: `accepts_server_context?` (used by tool/prompt dispatch) must
      # require `server_context` as a *keyword* parameter. A tool whose `call`
      # signature is `def self.call(arg, server_context)` (positional name collision)
      # would previously have been opt-in, and `tool.call(**args, server_context: ctx)`
      # would have blown up or passed the wrapped Hash to the wrong slot.
      tool = Class.new(MCP::Tool) do
        tool_name "positional_collision"
        input_schema(properties: { a: { type: "string" } }, required: ["a"])

        class << self
          def call(a, server_context)
            [a, server_context]
          end
        end
      end
      @server.tools[tool.name_value] = tool

      # Should dispatch without `server_context:` kwarg - the positional arg collision
      # must NOT trigger opt-in. The tool receives only its declared positional (a).
      response = @session.handle(
        jsonrpc: "2.0",
        id: 303,
        method: Methods::TOOLS_CALL,
        params: { name: "positional_collision", arguments: { a: "hello" } },
      )

      # Because the tool signature isn't opt-in, `tool.call(**args)` is called
      # (without `server_context:`). The method has `server_context` as a required
      # positional, so missing it raises ArgumentError - caught as an internal error.
      # The key assertion is that we do NOT pass `server_context:` kwarg that would
      # flow into the positional slot as a Hash.
      assert response.dig(:error), "dispatch should not silently inject server_context kwarg"
    end

    test "handler with positional `server_context` parameter is not auto-opted-in" do
      # Regression: `handler_declares_server_context?` must require `server_context`
      # as a *keyword* parameter. A positional parameter that happens to be named
      # `server_context` (rare but possible) would previously have been treated as
      # opt-in, and the dispatch site would call `handler.call(params, server_context: ctx)`
      # - the second positional argument would become the Hash `{server_context: ctx}`,
      # which is never what the user intended.
      received_args = nil
      @server.define_custom_method(method_name: "custom/positional_name") do |params, server_context|
        received_args = [params, server_context]
        { ok: true }
      end

      response = @session.handle(
        jsonrpc: "2.0",
        id: 302,
        method: "custom/positional_name",
        params: { hello: "world" },
      )

      assert_equal [{ hello: "world" }, nil],
        received_args,
        "positional `server_context` must receive the single `params` argument, not an auto-wrapped context"
      assert_equal({ ok: true }, response[:result])
    end

    test "handler with **kwargs-only signature is not auto-opted-in to server_context" do
      # Regression: a block like `|**opts|` would have triggered opt-in under the
      # looser `accepts_server_context?` check used by tools, and the dispatch site
      # would then call `handler.call(params, server_context:)` - but a proc that
      # only declares `**opts` cannot accept the positional `params` (lambdas raise
      # ArgumentError, non-lambda procs silently drop it). The stricter
      # `handler_declares_server_context?` check requires `server_context` as a
      # named keyword to opt in, so a kwargs-only handler receives only `params`.
      received_positional = nil
      @server.define_custom_method(method_name: "custom/kwargs_only") do |params, **_opts|
        received_positional = params
        { ok: true }
      end

      response = @session.handle(
        jsonrpc: "2.0",
        id: 301,
        method: "custom/kwargs_only",
        params: { hello: "world" },
      )

      assert_equal({ hello: "world" }, received_positional)
      assert_equal({ ok: true }, response[:result])
    end

    test "custom method handler that opts in to server_context observes cancellation" do
      observed = false
      @server.define_custom_method(method_name: "custom/slow") do |_params, server_context:|
        50.times do
          break if server_context.cancelled?

          sleep(0.01)
        end
        observed = server_context.cancelled?
        { ok: true }
      end

      response, = drive_cancellation(
        request_id: 204,
        method: "custom/slow",
        params: {},
      )

      assert observed, "custom method handler should observe cancellation via server_context"
      assert_nil response, "cancelled custom method must not emit a JSON-RPC response"
    end

    test "send_peer_cancellation routes notification on parent stream via related_request_id" do
      recorded_notifications = []
      (class << @mock_transport; self; end).define_method(:send_notification) do |method, params = nil, **kwargs|
        recorded_notifications << { method: method, params: params, kwargs: kwargs }
        true
      end

      @session.send_peer_cancellation(
        nested_request_id: "nested-1",
        related_request_id: 42,
        reason: "parent aborted",
      )

      notif = recorded_notifications.last
      assert_equal Methods::NOTIFICATIONS_CANCELLED, notif[:method]
      assert_equal "nested-1", notif[:params][:requestId]
      assert_equal "parent aborted", notif[:params][:reason]
      # Crucially, the cancel notification targets the parent's stream, not the GET SSE stream.
      assert_equal 42, notif[:kwargs][:related_request_id]
    end
  end
end
