# frozen_string_literal: true

require "test_helper"
require "rack"
require_relative "../../../../examples/in_memory_event_store"

module MCP
  class Server
    module Transports
      # SEP-1699 resumability of the Streamable HTTP transport: event ids, priming events, closing a stream from a handler,
      # and resuming a stream from `Last-Event-ID`.
      class StreamableHTTPResumabilityTest < ActiveSupport::TestCase
        include InitializeParamsTestHelper

        # A stream that buffers writes and remains readable after close.
        class TestStream
          attr_reader :string

          def initialize
            @string = +""
            @closed = false
          end

          def write(data)
            raise IOError, "closed stream" if @closed

            @string << data
          end

          def flush
          end

          def close
            @closed = true
          end

          def closed?
            @closed
          end
        end

        # An event store whose backend is unreachable.
        class FailingEventStore < EventStore
          def store_event(_stream_id, _message)
            raise IOError, "store unreachable"
          end

          def events_after(_last_event_id)
            nil
          end
        end

        # An event store whose ids would end an SSE frame early.
        class LineBreakingEventStore < EventStore
          def store_event(stream_id, _message)
            "#{stream_id}/1\ndata: injected"
          end

          def events_after(_last_event_id)
            nil
          end
        end

        # An event store that always holds one more event past the cursor, as a handler emitting without pause leaves it.
        class EndlessEventStore < EventStore
          def initialize
            super
            @sequence = 0
          end

          def store_event(stream_id, _message)
            "#{stream_id}/#{@sequence += 1}"
          end

          def events_after(last_event_id)
            stream_id = last_event_id.rpartition("/").first
            [stream_id, [["#{stream_id}/#{@sequence += 1}", { jsonrpc: "2.0", method: "notifications/progress" }.to_json]]]
          end
        end

        # A stream whose connection fails after `fail_after` writes.
        class BreakingStream < TestStream
          def initialize(fail_after:)
            super()
            @writes_left = fail_after
          end

          def write(data)
            @writes_left -= 1
            raise Errno::ECONNRESET, "peer went away" if @writes_left.negative?

            super
          end
        end

        setup do
          @server = Server.new(name: "test_server", tools: [], prompts: [], resources: [])
          @store = InMemoryEventStore.new
          @transport = build_transport(event_store: @store, retry_interval: 250)
        end

        teardown do
          @transport.close
        end

        test "event_store is refused in stateless mode" do
          error = assert_raises(ArgumentError) do
            StreamableHTTPTransport.new(@server, stateless: true, event_store: InMemoryEventStore.new)
          end

          assert_match(/stateless/, error.message)
        end

        test "retry_interval requires an event store and a positive Integer of milliseconds" do
          assert_raises(ArgumentError) { StreamableHTTPTransport.new(@server, retry_interval: 100) }
          assert_raises(ArgumentError) { StreamableHTTPTransport.new(@server, event_store: InMemoryEventStore.new, retry_interval: 0) }
          assert_raises(ArgumentError) { StreamableHTTPTransport.new(@server, event_store: InMemoryEventStore.new, retry_interval: 1.5) }
        end

        test "an event store must respond to store_event and events_after" do
          assert_raises(ArgumentError) { StreamableHTTPTransport.new(@server, event_store: Object.new) }
        end

        test "a POST response stream opens with a priming event and the response carries an event id" do
          session_id = initialize_session

          events = sse_events(run_stream(post(session_id, { jsonrpc: "2.0", method: "ping", id: "1" })))

          assert_equal 2, events.size
          priming, response = events
          assert_equal "", priming[:data]
          assert_equal 250, priming[:retry]
          refute_nil priming[:id]
          assert_equal "1", JSON.parse(response[:data])["id"]
          refute_nil response[:id]
          refute_equal priming[:id], response[:id]
          assert_nil response[:retry]

          # The priming event is a cursor into the stream: the response is what follows it.
          _stream_id, replay = @store.events_after(priming[:id])
          assert_equal [[response[:id], response[:data]]], replay
        end

        test "without an event store the stream carries no event ids" do
          transport = build_transport
          session_id = initialize_session(transport: transport)

          events = sse_events(run_stream(post(session_id, { jsonrpc: "2.0", method: "ping", id: "1" }, transport: transport)))

          assert_equal 1, events.size
          assert_nil events.first[:id]
          assert_equal "1", JSON.parse(events.first[:data])["id"]
        ensure
          transport&.close
        end

        test "a client that negotiated a version before 2025-11-25 gets event ids but no priming event" do
          closed = :unset
          @server.define_tool(name: "closer") do |server_context:|
            closed = server_context.close_sse_stream
            Tool::Response.new([{ type: "text", text: "done" }])
          end
          session_id = initialize_session(protocol_version: "2025-06-18")

          events = sse_events(run_stream(post(session_id, tool_call("closer", id: "1"))))

          assert_equal 1, events.size
          assert_equal "1", JSON.parse(events.first[:data])["id"]
          refute_nil events.first[:id]
          assert_nil events.first[:retry]
          refute closed
        end

        test "close_sse_stream closes the connection and the response is replayed on Last-Event-ID" do
          closed = nil
          @server.define_tool(name: "closer") do |server_context:|
            closed = server_context.close_sse_stream
            Tool::Response.new([{ type: "text", text: "done" }])
          end
          session_id = initialize_session

          stream = run_stream(post(session_id, tool_call("closer", id: "7")))
          events = sse_events(stream)

          assert closed
          assert stream.closed?
          assert_equal 1, events.size, "only the priming event reached the closed connection"
          assert_equal "", events.first[:data]

          resumed = run_stream(resume(session_id, events.first[:id]))
          replayed = sse_events(resumed)

          assert_equal 1, replayed.size
          response = JSON.parse(replayed.first[:data])
          assert_equal "7", response["id"]
          assert_equal "done", response.dig("result", "content", 0, "text")
          refute_nil replayed.first[:id]
          assert resumed.closed?, "a stream of an answered request is closed once replayed"
        end

        test "a request still running after close_sse_stream continues on the resumed connection" do
          gate = Queue.new
          @server.define_tool(name: "poller") do |server_context:|
            server_context.close_sse_stream
            gate.pop
            server_context.report_progress(1, message: "after reconnect")
            Tool::Response.new([{ type: "text", text: "done" }])
          end
          session_id = initialize_session

          response = post(session_id, tool_call("poller", id: "9", progress_token: "tok"))
          stream = TestStream.new
          request_thread = Thread.new { response[2].call(stream) }
          wait_until { stream.closed? }
          priming_id = sse_events(stream).first[:id]

          resumed = run_stream(resume(session_id, priming_id))

          refute resumed.closed?, "the stream of a request still in flight stays attached"
          attached = sse_events(resumed)
          assert_equal 1, attached.size
          assert_equal "", attached.first[:data], "the resumed connection opens with a priming event"
          assert_equal 250, attached.first[:retry]

          gate << :go
          request_thread.join

          events = sse_events(resumed)
          assert_equal 3, events.size
          progress = JSON.parse(events[1][:data])
          assert_equal "notifications/progress", progress["method"]
          assert_equal "after reconnect", progress.dig("params", "message")
          assert_equal "9", JSON.parse(events[2][:data])["id"]
          assert events.all? { |event| event[:id] }, "every event of the resumed connection carries an id"
          assert resumed.closed?, "the connection is closed after the response"
          assert_equal 1, sse_events(stream).size, "nothing more reached the closed connection"
        end

        test "replay starts after the event the client names" do
          @server.define_tool(name: "stepper") do |server_context:|
            server_context.report_progress(1, message: "first")
            server_context.close_sse_stream
            server_context.report_progress(2, message: "second")
            Tool::Response.new([{ type: "text", text: "done" }])
          end
          session_id = initialize_session

          events = sse_events(run_stream(post(session_id, tool_call("stepper", id: "3", progress_token: "tok"))))

          assert_equal 2, events.size
          assert_equal "first", JSON.parse(events[1][:data]).dig("params", "message")

          replayed = sse_events(run_stream(resume(session_id, events[1][:id])))

          assert_equal ["second", nil], replayed.map { |event| JSON.parse(event[:data]).dig("params", "message") }
          assert_equal "3", JSON.parse(replayed.last[:data])["id"]
        end

        test "an unknown Last-Event-ID is refused without echoing the value" do
          session_id = initialize_session

          response = resume(session_id, "no-such-stream/1")

          assert_equal 400, response[0]
          body = JSON.parse(response[2][0])
          assert_equal JsonRpcHandler::ErrorCode::INVALID_REQUEST, body["error"]["code"]
          assert_equal "Bad Request: Unknown Last-Event-ID", body["error"]["message"]
          refute_includes response[2][0], "no-such-stream"
        end

        test "an event id of another session is refused and nothing of that session is replayed" do
          @server.define_tool(name: "closer") do |server_context:|
            server_context.close_sse_stream
            Tool::Response.new([{ type: "text", text: "secret" }])
          end
          victim = initialize_session
          other = initialize_session
          priming_id = sse_events(run_stream(post(victim, tool_call("closer", id: "1")))).first[:id]

          response = resume(other, priming_id)

          assert_equal 400, response[0]
          assert_equal "Bad Request: Unknown Last-Event-ID", JSON.parse(response[2][0]).dig("error", "message")

          # The session the stream belongs to can still resume it.
          replayed = sse_events(run_stream(resume(victim, priming_id)))
          assert_equal "secret", JSON.parse(replayed.first[:data]).dig("result", "content", 0, "text")
        end

        test "a GET stream opens with a priming event and a notification sent while it is closed is replayed" do
          session_id = initialize_session
          first = run_stream(get(session_id))
          opening = sse_events(first)

          assert_equal 1, opening.size
          assert_equal "", opening.first[:data]
          assert_equal 250, opening.first[:retry]

          assert @transport.close_standalone_sse_stream(session_id)
          assert first.closed?

          @server.notify_tools_list_changed

          second = run_stream(resume(session_id, opening.first[:id]))
          events = sse_events(second)

          assert_equal 2, events.size
          assert_equal "notifications/tools/list_changed", JSON.parse(events[0][:data])["method"]
          assert_equal "", events[1][:data], "the resumed stream is primed again"
          refute second.closed?

          # The resumed connection is the session's GET stream from here on.
          @server.notify_prompts_list_changed
          live = sse_events(second).last
          assert_equal "notifications/prompts/list_changed", JSON.parse(live[:data])["method"]
          refute_nil live[:id]
        end

        test "a priming event is written only to the connection its request put in place" do
          session_id = initialize_session
          current = run_stream(get(session_id))
          assert_equal 1, sse_events(current).size

          # The state a resume finds when a later resume attached its own connection first: the session's GET stream
          # is no longer the one this request holds.
          superseded = TestStream.new
          @transport.send(:write_priming_event, session_id, nil, superseded)

          assert_empty superseded.string
          assert_equal 1, sse_events(current).size
        end

        test "close_standalone_sse_stream reports false when the session holds no GET stream" do
          session_id = initialize_session

          refute @transport.close_standalone_sse_stream(session_id)
          refute @transport.close_standalone_sse_stream("no-such-session")
        end

        test "a resume of the GET stream replaces a connection still attached" do
          session_id = initialize_session
          first = run_stream(get(session_id))
          priming_id = sse_events(first).first[:id]

          second = run_stream(resume(session_id, priming_id))

          assert first.closed?
          refute second.closed?
          @server.notify_tools_list_changed
          assert_equal 1, sse_events(first).size, "nothing more reaches the replaced connection"
          assert_includes second.string, "notifications/tools/list_changed"
        end

        test "events of a GET stream the client never opened are not stored" do
          session_id = initialize_session

          @server.notify_tools_list_changed

          assert_empty @store.instance_variable_get(:@streams)
          refute @transport.close_standalone_sse_stream(session_id)
        end

        test "a store that fails to store an event is reported and the event is still written without an id" do
          reported = []
          original_reporter = MCP.configuration.exception_reporter
          MCP.configuration.exception_reporter = ->(error, context) { reported << [error, context] }
          transport = build_transport(event_store: FailingEventStore.new)
          session_id = initialize_session(transport: transport)

          events = sse_events(run_stream(post(session_id, { jsonrpc: "2.0", method: "ping", id: "1" }, transport: transport)))

          assert_equal 1, events.size, "no priming event without an id to give it"
          assert_nil events.first[:id]
          assert_equal "1", JSON.parse(events.first[:data])["id"]
          assert_equal ["Event store failure"] * 2, reported.map { |_error, context| context[:error] }
          assert reported.all? { |error, _context| error.is_a?(IOError) }
        ensure
          MCP.configuration.exception_reporter = original_reporter
          transport&.close
        end

        test "a store that returns an id holding a line break is reported and the event is written without an id" do
          reported = []
          original_reporter = MCP.configuration.exception_reporter
          MCP.configuration.exception_reporter = ->(error, context) { reported << [error, context] }
          transport = build_transport(event_store: LineBreakingEventStore.new)
          session_id = initialize_session(transport: transport)

          stream = run_stream(post(session_id, { jsonrpc: "2.0", method: "ping", id: "1" }, transport: transport))
          events = sse_events(stream)

          assert_equal 1, events.size
          assert_nil events.first[:id]
          refute_includes stream.string, "injected"
          assert_equal ["Event store failure"] * 2, reported.map { |_error, context| context[:error] }
          assert reported.all? { |error, _context| error.is_a?(ArgumentError) }
          assert_equal ["event store returned an invalid event id"], reported.map { |error, _context| error.message }.uniq
        ensure
          MCP.configuration.exception_reporter = original_reporter
          transport&.close
        end

        test "a GET stream whose connection fails is detached and the session resumes it" do
          session_id = initialize_session
          response = get(session_id)
          assert_equal 200, response[0]
          broken = BreakingStream.new(fail_after: 1)
          response[2].call(broken)
          priming_id = sse_events(broken).first[:id]
          refute_nil priming_id

          @server.notify_tools_list_changed

          assert broken.closed?
          events = sse_events(run_stream(resume(session_id, priming_id)))
          assert_equal "notifications/tools/list_changed", JSON.parse(events[0][:data])["method"]
          assert_equal "", events[1][:data], "the resumed connection is the session's GET stream and is primed"
        end

        test "a GET stream whose reader stalls is detached at the write deadline and the session resumes it" do
          transport = build_transport(event_store: InMemoryEventStore.new, stream_write_timeout: 0.1)
          session_id = initialize_session(transport: transport)
          stalled = run_stream(get(session_id, transport: transport))
          priming_id = sse_events(stalled).first[:id]
          refute_nil priming_id
          # A peer that stopped reading: the write blocks until the transport's own deadline cuts it short.
          stalled.define_singleton_method(:write) { |_data| sleep(30) }

          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          transport.send_notification("notifications/tools/list_changed", nil, **{})
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

          assert_operator elapsed, :<, 5
          assert stalled.closed?
          events = sse_events(run_stream(resume(session_id, priming_id, transport: transport)))
          assert_equal "notifications/tools/list_changed", JSON.parse(events[0][:data])["method"]
        ensure
          transport&.close
        end

        test "close_sse_stream reports false when the priming event could not be stored and the response stays on the connection" do
          @server.define_tool(name: "closer") do |server_context:|
            Tool::Response.new([{ type: "text", text: server_context.close_sse_stream.inspect }])
          end
          original_reporter = MCP.configuration.exception_reporter
          MCP.configuration.exception_reporter = ->(_error, _context) {}
          transport = build_transport(event_store: FailingEventStore.new)
          session_id = initialize_session(transport: transport)

          stream = run_stream(post(session_id, tool_call("closer", id: "1"), transport: transport))

          assert_equal "false", messages(stream).first.dig("result", "content", 0, "text")
        ensure
          MCP.configuration.exception_reporter = original_reporter
          transport&.close
        end

        test "a resume whose replay passes keep finding events is closed after the batch of the last pass" do
          transport = build_transport(event_store: EndlessEventStore.new)
          session_id = initialize_session(transport: transport)
          first = run_stream(get(session_id, transport: transport))
          priming_id = sse_events(first).first[:id]

          second = run_stream(resume(session_id, priming_id, transport: transport))

          assert second.closed?
          assert_equal StreamableHTTPTransport::REPLAY_PASS_LIMIT, messages(second).size
          refute first.closed?, "the connection still attached stays the session's GET stream"
        ensure
          transport&.close
        end

        test "a resume presenting another principal's token is refused before anything is replayed" do
          alice = { OAuth::ENV_KEY => OAuth::AccessToken.new(token: "alice-token", subject: "alice", client_id: "client-a") }
          bob = { OAuth::ENV_KEY => OAuth::AccessToken.new(token: "bob-token", subject: "bob", client_id: "client-b") }
          session_id = initialize_session(env: alice)
          priming_id = sse_events(run_stream(get(session_id, env: alice))).first[:id]
          assert @transport.close_standalone_sse_stream(session_id)
          @server.notify_tools_list_changed

          response = resume(session_id, priming_id, env: bob)

          assert_equal 404, response[0]
          replayed = messages(run_stream(resume(session_id, priming_id, env: alice)))
          assert_equal "notifications/tools/list_changed", replayed.first["method"]
        end

        test "a server-to-client request sent on a closed connection reaches the resumed one and is answered" do
          @server.define_tool(name: "pinger") do |server_context:|
            server_context.close_sse_stream
            result = server_context.ping
            Tool::Response.new([{ type: "text", text: result.inspect }])
          end
          session_id = initialize_session

          response = post(session_id, tool_call("pinger", id: "5"))
          stream = TestStream.new
          request_thread = Thread.new { response[2].call(stream) }
          wait_until { stream.closed? }
          priming_id = sse_events(stream).first[:id]

          resumed = run_stream(resume(session_id, priming_id))
          wait_until { resumed.string.include?("\"method\":\"ping\"") }
          ping = messages(resumed).find { |message| message["method"] == "ping" }
          refute_nil ping["id"]

          accepted = post(session_id, { jsonrpc: "2.0", id: ping["id"], result: {} })
          assert_equal 202, accepted[0]
          request_thread.join

          final = messages(resumed).last
          assert_equal "5", final["id"]
          assert_equal "{}", final.dig("result", "content", 0, "text")
        end

        test "close_sse_stream reports false on a request answered as JSON" do
          closed = nil
          @server.define_tool(name: "closer") do |server_context:|
            closed = server_context.close_sse_stream
            Tool::Response.new([{ type: "text", text: "done" }])
          end
          transport = build_transport(event_store: InMemoryEventStore.new, enable_json_response: true)
          session_id = initialize_session(transport: transport)

          response = post(session_id, tool_call("closer", id: "1"), transport: transport)

          assert_equal 200, response[0]
          assert_equal "application/json", response[1]["content-type"]
          refute closed
        ensure
          transport&.close
        end

        test "ServerContext#close_sse_stream reports false on a session whose transport has no resumable streams" do
          session = ServerSession.new(server: @server, transport: Object.new, session_id: "s")
          context = ServerContext.new({}, progress: nil, notification_target: session, related_request_id: "1")

          refute context.close_sse_stream
          refute context.close_standalone_sse_stream
          refute ServerContext.new({}, progress: nil, notification_target: session).close_sse_stream
        end

        private

        def build_transport(**options)
          StreamableHTTPTransport.new(@server, listen_keepalive_interval: nil, **options)
        end

        def initialize_session(transport: @transport, protocol_version: MCP::Configuration::LATEST_HANDSHAKE_PROTOCOL_VERSION, env: {})
          response = transport.handle_request(rack_request(
            "POST",
            env,
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params(protocolVersion: protocol_version) }.to_json,
          ))

          assert_equal 200, response[0]
          response[1]["mcp-session-id"]
        end

        def tool_call(name, id:, progress_token: nil)
          params = { name: name, arguments: {} }
          params[:_meta] = { progressToken: progress_token } if progress_token
          { jsonrpc: "2.0", id: id, method: "tools/call", params: params }
        end

        def post(session_id, body, transport: @transport)
          transport.handle_request(rack_request("POST", { "HTTP_MCP_SESSION_ID" => session_id }, body.to_json))
        end

        def get(session_id, transport: @transport, env: {})
          transport.handle_request(rack_request("GET", { "HTTP_MCP_SESSION_ID" => session_id }.merge(env)))
        end

        def resume(session_id, last_event_id, transport: @transport, env: {})
          headers = { "HTTP_MCP_SESSION_ID" => session_id, "HTTP_LAST_EVENT_ID" => last_event_id }.merge(env)
          transport.handle_request(rack_request("GET", headers))
        end

        def rack_request(method, headers, body = nil)
          env = {
            "REQUEST_METHOD" => method,
            "PATH_INFO" => "/",
            "CONTENT_TYPE" => "application/json",
            "HTTP_ACCEPT" => method == "GET" ? "text/event-stream" : "application/json, text/event-stream",
            "rack.input" => StringIO.new(body.to_s),
          }.merge(headers)

          Rack::Request.new(env)
        end

        # Runs the streaming body of an SSE response into a TestStream and returns the stream.
        def run_stream(response)
          assert_equal 200, response[0]
          assert_equal "text/event-stream", response[1]["content-type"]

          stream = TestStream.new
          response[2].call(stream)
          stream
        end

        # The SSE events written to `stream` so far, as `{ id:, retry:, data: }` with `data` the joined data lines
        # (`""` for a priming event); comment frames are skipped.
        def sse_events(stream)
          stream.string.split("\n\n").filter_map do |frame|
            event = { id: nil, retry: nil }
            data_lines = []
            frame.each_line(chomp: true) do |line|
              next if line.start_with?(":")

              name, value = line.split(":", 2)
              value = value.to_s.sub(/\A /, "")
              case name
              when "id" then event[:id] = value
              when "retry" then event[:retry] = Integer(value)
              when "data" then data_lines << value
              end
            end
            next if data_lines.empty?

            event.merge(data: data_lines.join("\n"))
          end
        end

        # The JSON-RPC messages among the events written to `stream`, priming events left out.
        def messages(stream)
          sse_events(stream).reject { |event| event[:data].empty? }.map { |event| JSON.parse(event[:data]) }
        end

        def wait_until(timeout: 5)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          until yield
            flunk("Timed out waiting for condition") if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

            sleep(0.01)
          end
        end
      end
    end
  end
end
