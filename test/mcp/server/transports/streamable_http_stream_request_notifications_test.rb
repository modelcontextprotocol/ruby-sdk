# frozen_string_literal: true

require "test_helper"
require "rack"

module MCP
  class Server
    module Transports
      # `stream_request_notifications:`: a 2026-07-28 request that asks for progress is answered on an SSE stream
      # that carries each notification as its handler emits it.
      class StreamableHTTPStreamRequestNotificationsTest < ActiveSupport::TestCase
        # Hands each frame to a queue as it is written, so a test can wait for one while the handler is still running.
        class FrameStream
          attr_reader :frames

          def initialize(fail_writes_after: nil, block_writes_after: nil)
            @frames = Queue.new
            @written = []
            @closed = false
            @fail_writes_after = fail_writes_after
            @block_writes_after = block_writes_after
          end

          def write(data)
            raise IOError, "closed stream" if @closed
            raise Errno::EPIPE if @fail_writes_after && @written.size >= @fail_writes_after

            sleep if @block_writes_after && @written.size >= @block_writes_after

            @written << data
            @frames << data
          end

          def flush
          end

          def close
            @closed = true
          end

          def closed?
            @closed
          end

          def written
            @written.dup
          end
        end

        setup do
          @server = Server.new(name: "test_server", tools: [], prompts: [], resources: [])
          @transport = StreamableHTTPTransport.new(@server, stream_request_notifications: true, listen_keepalive_interval: nil)
        end

        teardown do
          @transport.close
        end

        test "a notification reaches the stream while the handler is still running, and the response is the last frame" do
          proceed = Queue.new
          @server.define_tool(name: "slow") do |server_context:|
            server_context.report_progress(1, total: 2)
            proceed.pop
            Tool::Response.new([{ type: "text", text: "done" }])
          end

          status, headers, body = post_tools_call("slow")

          assert_equal 200, status
          assert_equal "text/event-stream", headers["content-type"]
          refute_respond_to body, :each

          stream = FrameStream.new
          handler = Thread.new { body.call(stream) }
          progress = data_of(stream.frames.pop)

          assert_equal "notifications/progress", progress["method"]
          assert_equal "token-1", progress.dig("params", "progressToken")
          assert_predicate handler, :alive?

          proceed << true
          handler.join

          response = data_of(stream.frames.pop)
          assert_equal 7, response["id"]
          assert_equal "done", response.dig("result", "content", 0, "text")
          assert_equal 2, stream.written.size
          assert_predicate stream, :closed?
        end

        test "the handler runs on the thread that calls the body" do
          # A mutex is owned by one thread only, so the handler sees it owned exactly when it runs on the caller's thread.
          caller_lock = Mutex.new
          on_caller_thread = nil
          @server.define_tool(name: "where") do
            on_caller_thread = caller_lock.owned?
            Tool::Response.new([{ type: "text", text: "ok" }])
          end

          _status, _headers, body = post_tools_call("where")

          assert_nil on_caller_thread
          caller_lock.synchronize { body.call(FrameStream.new) }
          assert on_caller_thread
        end

        test "the setting is off by default and the notifications then arrive with the response" do
          define_progress_tool("counted", notifications: 2)
          transport = StreamableHTTPTransport.new(@server, listen_keepalive_interval: nil)

          status, headers, body = post_tools_call("counted", transport: transport)

          assert_equal 200, status
          assert_equal "text/event-stream", headers["content-type"]
          assert_equal 3, body[0].scan("event: message").size
        ensure
          transport.close
        end

        test "a request without a progress token keeps the single JSON exchange" do
          define_progress_tool("counted", notifications: 0)

          status, headers, body = post_tools_call("counted", progress_token: nil)

          assert_equal 200, status
          assert_equal "application/json", headers["content-type"]
          assert_equal "ok", JSON.parse(body[0]).dig("result", "content", 0, "text")
        end

        test "a progress token that is neither a string nor an integer does not open a stream" do
          define_progress_tool("counted", notifications: 0)

          [1.5, true, { a: 1 }, [1]].each do |token|
            _status, headers, _body = post_tools_call("counted", progress_token: token)

            assert_equal "application/json", headers["content-type"], token.inspect
          end
        end

        test "a method outside tools/call, prompts/get and resources/read is not streamed" do
          status, headers, body = post_modern("tools/list", { _meta: envelope.merge(progressToken: "token-1") })

          assert_equal 200, status
          assert_equal "application/json", headers["content-type"]
          assert_equal [], JSON.parse(body[0]).dig("result", "tools")
        end

        test "prompts/get and resources/read are streamed" do
          @server.define_prompt(name: "greeting") do |_args, server_context:|
            server_context.report_progress(1)
            Prompt::Result.new(messages: [])
          end
          @server.resources = [Resource.new(uri: "test://a", name: "a")]
          @server.resources_read_handler do |params, server_context:|
            server_context.report_progress(1)
            [{ uri: params[:uri], text: "a" }]
          end

          {
            "prompts/get" => [{ name: "greeting" }, { "HTTP_MCP_NAME" => "greeting" }],
            "resources/read" => [{ uri: "test://a" }, { "HTTP_MCP_NAME" => "test://a" }],
          }.each do |method, (params, headers)|
            status, response_headers, body = post_modern(method, params.merge(_meta: envelope.merge(progressToken: 1)), headers: headers)

            assert_equal 200, status, method
            assert_equal "text/event-stream", response_headers["content-type"], method

            stream = FrameStream.new
            body.call(stream)
            frames = stream.written.map { |frame| data_of(frame) }

            assert_equal "notifications/progress", frames[0]["method"], method
            assert frames[1].key?("result"), "#{method}: #{frames[1]}"
          end
        end

        test "a header mismatch is refused with HTTP 400 before any stream is opened" do
          ran = false
          @server.define_tool(
            name: "regional",
            input_schema: { properties: { region: { type: "string", "x-mcp-header": "Region" } } },
          ) do |**_args|
            ran = true
            Tool::Response.new([{ type: "text", text: "ok" }])
          end

          status, headers, body = post_tools_call("regional", arguments: { region: "us-west1" }, headers: { "HTTP_MCP_PARAM_REGION" => "us-east1" })

          assert_equal 400, status
          assert_equal "application/json", headers["content-type"]
          assert_equal ErrorCodes::HEADER_MISMATCH, JSON.parse(body[0]).dig("error", "code")
          refute ran

          status, headers, body = post_tools_call("regional", arguments: { region: "us-west1" }, headers: { "HTTP_MCP_PARAM_REGION" => "us-west1" })

          assert_equal 200, status
          assert_equal "text/event-stream", headers["content-type"]
          body.call(FrameStream.new)
          assert ran
        end

        test "an unknown tool is answered as it is without the setting" do
          plain = StreamableHTTPTransport.new(@server, listen_keepalive_interval: nil)

          assert_equal post_tools_call("missing", transport: plain), post_tools_call("missing")
        ensure
          plain.close
        end

        test "with a tools_list_handler a tools/call is not streamed and the handler is asked once" do
          tool = Tool.define(name: "listed") do |server_context:|
            server_context.report_progress(1)
            Tool::Response.new([{ type: "text", text: "ok" }])
          end
          asked = 0
          @server.tools_list_handler do |_params|
            asked += 1
            [tool]
          end
          plain = StreamableHTTPTransport.new(@server, listen_keepalive_interval: nil)

          hidden = post_tools_call("hidden")
          listed = post_tools_call("listed")

          assert_equal post_tools_call("hidden", transport: plain), hidden
          assert_equal 200, listed[0]
          assert_kind_of Array, listed[2]
          assert_equal 2, listed[2][0].scan("event: message").size
          assert_equal 3, asked
        ensure
          plain.close
        end

        test "a method the server does not implement keeps its 404" do
          server = Server.new(name: "no_prompts", capabilities: { tools: {} })
          transport = StreamableHTTPTransport.new(server, stream_request_notifications: true, listen_keepalive_interval: nil)

          status, headers, body = post_modern("prompts/get", { name: "x", _meta: envelope.merge(progressToken: 1) }, headers: { "HTTP_MCP_NAME" => "x" }, transport: transport)

          assert_equal 404, status
          assert_equal "application/json", headers["content-type"]
          assert_equal JsonRpcHandler::ErrorCode::METHOD_NOT_FOUND, JSON.parse(body[0]).dig("error", "code")
        ensure
          transport.close
        end

        test "a request that is not valid JSON-RPC keeps its 400" do
          define_progress_tool("counted", notifications: 1)
          plain = StreamableHTTPTransport.new(@server, listen_keepalive_interval: nil)
          params = { name: "counted", _meta: envelope.merge(progressToken: 1) }
          headers = { "HTTP_MCP_NAME" => "counted" }

          [{ jsonrpc: "1.0" }, { jsonrpc: nil }, { id: true }, { id: 1.5 }, { id: { a: 1 } }].each do |framing|
            status, response_headers, body = post_modern("tools/call", params, headers: headers, framing: framing)

            assert_equal 400, status, framing.inspect
            assert_equal "application/json", response_headers["content-type"], framing.inspect
            assert_equal JsonRpcHandler::ErrorCode::INVALID_REQUEST, JSON.parse(body[0]).dig("error", "code"), framing.inspect
            assert_equal post_modern("tools/call", params, headers: headers, framing: framing, transport: plain), [status, response_headers, body]
          end
        ensure
          plain.close
        end

        test "an envelope missing a required member keeps its 400" do
          define_progress_tool("counted", notifications: 1)
          meta = envelope.merge(progressToken: 1)
          meta.delete(:"io.modelcontextprotocol/clientCapabilities")

          status, headers, body = post_modern("tools/call", { name: "counted", _meta: meta }, headers: { "HTTP_MCP_NAME" => "counted" })

          assert_equal 400, status
          assert_equal "application/json", headers["content-type"]
          assert_equal JsonRpcHandler::ErrorCode::INVALID_PARAMS, JSON.parse(body[0]).dig("error", "code")
        end

        test "an error the dispatch finds after the stream is opened is its last frame" do
          define_progress_tool("counted", notifications: 0)

          status, headers, body = post_tools_call("counted", arguments: "not an object")

          assert_equal 200, status
          assert_equal "text/event-stream", headers["content-type"]

          stream = FrameStream.new
          body.call(stream)

          assert_equal 1, stream.written.size
          assert_equal JsonRpcHandler::ErrorCode::INVALID_PARAMS, data_of(stream.written[0]).dig("error", "code")
        end

        test "a client capability the handler finds missing is answered on the stream" do
          @server.define_tool(name: "asks") do |server_context:|
            server_context.require_client_capability!(:elicitation, :form)
            Tool::Response.new([{ type: "text", text: "ok" }])
          end

          status, _headers, body = post_tools_call("asks")
          stream = FrameStream.new
          body.call(stream)

          assert_equal 200, status
          assert_equal 1, stream.written.size
          assert_equal ErrorCodes::MISSING_REQUIRED_CLIENT_CAPABILITY, data_of(stream.written[0]).dig("error", "code")
        end

        test "an exception inside the body is reported, answered as an internal error, and leaves nothing behind" do
          define_progress_tool("counted", notifications: 0)
          _status, _headers, body = post_tools_call("counted")
          @server.stubs(:handle).raises(RuntimeError, "boom")
          reported = []
          MCP.configuration.stubs(:exception_reporter).returns(->(error, context) { reported << [error.message, context[:request].class] })

          stream = FrameStream.new
          body.call(stream)

          assert_equal [["boom", String]], reported
          assert_equal 1, stream.written.size
          error = data_of(stream.written[0])
          assert_equal 7, error["id"]
          assert_equal JsonRpcHandler::ErrorCode::INTERNAL_ERROR, error.dig("error", "code")
          refute_includes stream.written[0], "boom"
          assert_predicate stream, :closed?
          assert_empty @transport.instance_variable_get(:@modern_request_sinks)
        end

        test "a keepalive thread that cannot be started does not leave the sink or the stream behind" do
          transport = StreamableHTTPTransport.new(@server, stream_request_notifications: true, listen_keepalive_interval: 0.02)
          define_progress_tool("counted", notifications: 0)
          _status, _headers, body = post_tools_call("counted", transport: transport)
          transport.stubs(:start_request_stream_keepalive_thread).raises(ThreadError, "can't create Thread")
          MCP.configuration.stubs(:exception_reporter).returns(->(_error, _context) {})

          stream = FrameStream.new
          body.call(stream)

          assert_equal JsonRpcHandler::ErrorCode::INTERNAL_ERROR, data_of(stream.written[0]).dig("error", "code")
          assert_predicate stream, :closed?
          assert_empty transport.instance_variable_get(:@modern_request_sinks)
        ensure
          transport.close
        end

        test "a frame waiting behind a write that fails is not written after it" do
          transport = StreamableHTTPTransport.new(@server, stream_request_notifications: true, listen_keepalive_interval: nil)
          sink = { stream: nil, session: ServerSession.new(server: @server, transport: transport, session_id: "s", era: :modern), write_mutex: Mutex.new }
          entered = Queue.new
          release = Queue.new
          second_ran = false

          first = Thread.new do
            transport.send(:guarded_request_stream_write, sink) do
              entered << true
              release.pop
              raise Errno::EPIPE
            end
          end
          entered.pop
          second = Thread.new { transport.send(:guarded_request_stream_write, sink) { second_ran = true } }

          # The first write holds the mutex, so the second can only be waiting on it once it sleeps.
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
          sleep(0.01) until second.status != "run" || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          assert_equal "sleep", second.status
          release << true

          refute first.value
          refute second.value
          refute second_ran
          assert sink[:closed]
        ensure
          release << true
          [first, second].compact.each { |thread| thread.join(2) || thread.kill }
          transport.close
        end

        test "notifications past the buffered limit are all delivered" do
          count = StreamableHTTPTransport::MAX_MODERN_REQUEST_NOTIFICATIONS + 5
          define_progress_tool("counted", notifications: count)

          _status, _headers, body = post_tools_call("counted")
          stream = FrameStream.new
          body.call(stream)

          assert_equal count + 1, stream.written.size
          assert_equal count, data_of(stream.written[-2]).dig("params", "progress")
        end

        test "a failed write cancels the request, and nothing more is written" do
          cancelled = nil
          delivered = []
          @server.define_tool(name: "watched") do |server_context:|
            delivered << server_context.report_progress(1)
            delivered << server_context.report_progress(2)
            cancelled = server_context.cancelled?
            delivered << server_context.report_progress(3)
            Tool::Response.new([{ type: "text", text: "ok" }])
          end

          _status, _headers, body = post_tools_call("watched")
          stream = FrameStream.new(fail_writes_after: 1)
          body.call(stream)

          assert cancelled
          assert_equal 1, stream.written.size
          assert_equal "notifications/progress", data_of(stream.written[0])["method"]
          assert_predicate stream, :closed?
        end

        test "a write that stalls past stream_write_timeout cancels the request" do
          transport = StreamableHTTPTransport.new(@server, stream_request_notifications: true, listen_keepalive_interval: nil, stream_write_timeout: 0.05)
          cancelled = nil
          @server.define_tool(name: "stalled") do |server_context:|
            server_context.report_progress(1)
            cancelled = server_context.cancelled?
            Tool::Response.new([{ type: "text", text: "ok" }])
          end

          _status, _headers, body = post_tools_call("stalled", transport: transport)
          stream = FrameStream.new(block_writes_after: 0)
          body.call(stream)

          assert cancelled
          assert_empty stream.written
          assert_predicate stream, :closed?
        ensure
          transport.close
        end

        test "keepalive comment frames are written while the handler is quiet and stop with the request" do
          # Without a write deadline, so the only thread the request may start is its keepalive.
          transport = StreamableHTTPTransport.new(@server, stream_request_notifications: true, listen_keepalive_interval: 0.02, stream_write_timeout: nil)
          proceed = Queue.new
          @server.define_tool(name: "quiet") do
            proceed.pop
            Tool::Response.new([{ type: "text", text: "ok" }])
          end

          _status, _headers, body = post_tools_call("quiet", transport: transport)
          stream = FrameStream.new
          threads_before = Thread.list
          handler = Thread.new { body.call(stream) }

          assert_match(/\A: ping /, stream.frames.pop)

          proceed << true
          handler.join

          assert data_of(stream.written.last).key?("result")
          assert(stream.written[0..-2].all? { |frame| frame.start_with?(": ping ") })
          assert_empty wait_for_threads_to_end(Thread.list - threads_before - [handler])
        ensure
          transport.close
        end

        test "a keepalive that cannot be written cancels the request" do
          transport = StreamableHTTPTransport.new(@server, stream_request_notifications: true, listen_keepalive_interval: 0.02)
          cancelled = Queue.new
          @server.define_tool(name: "abandoned") do |server_context:|
            sleep(0.01) until server_context.cancelled?
            cancelled << true
            Tool::Response.new([{ type: "text", text: "ok" }])
          end

          _status, _headers, body = post_tools_call("abandoned", transport: transport)
          stream = FrameStream.new(fail_writes_after: 0)
          handler = Thread.new { body.call(stream) }

          assert cancelled.pop
          handler.join
          assert_empty stream.written
        ensure
          transport.close
        end

        test "concurrent requests each receive only their own notifications" do
          gates = { "a" => Queue.new, "b" => Queue.new }
          @server.define_tool(name: "tagged", input_schema: { properties: { tag: { type: "string" } } }) do |tag:, server_context:|
            gates[tag].pop
            server_context.report_progress(1, message: tag)
            server_context.notify_log_message(data: tag, level: "info")
            Tool::Response.new([{ type: "text", text: tag }])
          end

          runs = ["a", "b"].map do |tag|
            _status, _headers, body = post_tools_call("tagged", arguments: { tag: tag }, progress_token: "token-#{tag}", log_level: "info")
            stream = FrameStream.new
            [tag, stream, Thread.new { body.call(stream) }]
          end
          @server.notify_tools_list_changed
          gates.each_value { |gate| gate << true }
          runs.each { |_tag, _stream, thread| thread.join }

          runs.each do |tag, stream, _thread|
            frames = stream.written.map { |frame| data_of(frame) }

            assert_equal ["notifications/progress", "notifications/message", nil], frames.map { |frame| frame["method"] }
            assert_equal tag, frames[0].dig("params", "message")
            assert_equal "token-#{tag}", frames[0].dig("params", "progressToken")
            assert_equal tag, frames[1].dig("params", "data")
            assert_equal tag, frames[2].dig("result", "content", 0, "text")
          end
        end

        test "a notification sent after the response is not written" do
          late = nil
          @server.define_tool(name: "leaky") do |server_context:|
            late = server_context
            Tool::Response.new([{ type: "text", text: "ok" }])
          end

          _status, _headers, body = post_tools_call("leaky")
          stream = FrameStream.new
          body.call(stream)
          late.report_progress(9)

          assert_equal 1, stream.written.size
          assert_empty @transport.instance_variable_get(:@modern_request_sinks)
        end

        test "the body explains itself to a host that tries to buffer it" do
          define_progress_tool("counted", notifications: 0)

          _status, _headers, body = post_tools_call("counted")
          error = assert_raises(RuntimeError) { body.first }

          assert_includes error.message, "stream_request_notifications"
        end

        test "the setting cannot be combined with serve_subscriptions_listen: false" do
          error = assert_raises(ArgumentError) do
            StreamableHTTPTransport.new(@server, stream_request_notifications: true, serve_subscriptions_listen: false)
          end

          assert_includes error.message, "serve_subscriptions_listen: false"
        end

        private

        def define_progress_tool(name, notifications:)
          @server.define_tool(name: name) do |server_context:|
            notifications.times { |index| server_context.report_progress(index + 1) }
            Tool::Response.new([{ type: "text", text: "ok" }])
          end
        end

        def post_tools_call(name, arguments: nil, progress_token: "token-1", log_level: nil, headers: {}, transport: @transport)
          meta = envelope
          meta[:progressToken] = progress_token unless progress_token.nil?
          meta[:"io.modelcontextprotocol/logLevel"] = log_level if log_level
          params = { name: name, _meta: meta }
          params[:arguments] = arguments unless arguments.nil?

          post_modern("tools/call", params, headers: { "HTTP_MCP_NAME" => name }.merge(headers), transport: transport)
        end

        # `framing` replaces members of the JSON-RPC request itself; a member given as nil is left out.
        def post_modern(method, params, headers: {}, transport: @transport, framing: {})
          request = { jsonrpc: "2.0", id: 7, method: method, params: params }.merge(framing).compact
          env = {
            "REQUEST_METHOD" => "POST",
            "PATH_INFO" => "/",
            "HTTP_ACCEPT" => "application/json, text/event-stream",
            "CONTENT_TYPE" => "application/json",
            "HTTP_MCP_PROTOCOL_VERSION" => "2026-07-28",
            "HTTP_MCP_METHOD" => method,
            "rack.input" => StringIO.new(request.to_json),
          }.merge(headers)

          transport.handle_request(Rack::Request.new(env))
        end

        def envelope
          {
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientInfo": { name: "modern_client", version: "2.0" },
            "io.modelcontextprotocol/clientCapabilities": {},
          }
        end

        def data_of(frame)
          JSON.parse(frame[/^data: (.*)$/, 1])
        end

        def wait_for_threads_to_end(threads)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
          sleep(0.01) while threads.any?(&:alive?) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

          threads.select(&:alive?)
        end
      end
    end
  end
end
