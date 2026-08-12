# frozen_string_literal: true

require "test_helper"

module MCP
  class Server
    module Transports
      class StdioTransportTest < ActiveSupport::TestCase
        include InstrumentationTestHelper
        include InitializeParamsTestHelper

        setup do
          configuration = MCP::Configuration.new
          configuration.instrumentation_callback = instrumentation_helper.callback
          @server = Server.new(name: "test_server", configuration: configuration)
          @transport = StdioTransport.new(@server)
        end

        test "initializes with server and closed state" do
          server = @transport.instance_variable_get(:@server)
          assert_equal @server.object_id, server.object_id
          refute @transport.instance_variable_get(:@open)
        end

        test "processes JSON-RPC requests from stdin and sends responses to stdout" do
          request = {
            jsonrpc: "2.0",
            method: "ping",
            id: "123",
          }
          input = StringIO.new(JSON.generate(request) + "\n")
          output = StringIO.new

          original_stdin = $stdin
          original_stdout = $stdout

          begin
            $stdin = input
            $stdout = output

            thread = Thread.new { @transport.open }
            sleep(0.1)
            @transport.close
            thread.join

            response = JSON.parse(output.string, symbolize_names: true)
            assert_equal("2.0", response[:jsonrpc])
            assert_equal("123", response[:id])
            assert_equal({}, response[:result])
            refute(@transport.instance_variable_get(:@open))
          ensure
            $stdin = original_stdin
            $stdout = original_stdout
          end
        end

        test "sends string responses to stdout" do
          output = StringIO.new
          original_stdout = $stdout

          begin
            $stdout = output
            @transport.send_response("test response")
            assert_equal("test response\n", output.string)
          ensure
            $stdout = original_stdout
          end
        end

        test "sends JSON responses to stdout" do
          output = StringIO.new
          original_stdout = $stdout

          begin
            $stdout = output
            response = { key: "value" }
            @transport.send_response(response)
            assert_equal(JSON.generate(response) + "\n", output.string)
          ensure
            $stdout = original_stdout
          end
        end

        test "handles valid JSON-RPC requests" do
          request = {
            jsonrpc: "2.0",
            method: "ping",
            id: "123",
          }
          output = StringIO.new
          original_stdout = $stdout

          begin
            $stdout = output
            @transport.send(:handle_request, JSON.generate(request))
            response = JSON.parse(output.string, symbolize_names: true)
            assert_equal("2.0", response[:jsonrpc])
            assert_nil(response[:id])
            assert_nil(response[:result])
          ensure
            $stdout = original_stdout
          end
        end

        test "open creates a ServerSession and processes requests through it" do
          request = {
            jsonrpc: "2.0",
            method: "initialize",
            id: "1",
            params: {
              protocolVersion: "2025-11-25",
              capabilities: {},
              clientInfo: { name: "stdio-client", version: "1.0" },
            },
          }
          input = StringIO.new(JSON.generate(request) + "\n")
          output = StringIO.new
          original_stdin = $stdin
          original_stdout = $stdout

          begin
            $stdin = input
            $stdout = output
            @transport.open

            # Verify a session was created.
            session = @transport.instance_variable_get(:@session)
            assert_instance_of(ServerSession, session)

            # Verify client info was stored on the session, not on the server.
            assert_equal({ name: "stdio-client", version: "1.0" }, session.client)
          ensure
            $stdin = original_stdin
            $stdout = original_stdout
          end
        end

        test "open handles a malformed JSON-RPC batch element and emits an error response" do
          input = StringIO.new("[[]]\n")
          output = StringIO.new
          original_stdin = $stdin
          original_stdout = $stdout

          begin
            $stdin = input
            $stdout = output
            @transport.open

            response = JSON.parse(output.string, symbolize_names: true)
            assert_nil(response[:id])
            assert_equal(-32600, response[:error][:code])
            assert_equal("Invalid Request", response[:error][:message])
          ensure
            $stdin = original_stdin
            $stdout = original_stdout
          end
        end

        test "rejects duplicate initialize on the same stdio session with -32600" do
          first = {
            jsonrpc: "2.0",
            method: "initialize",
            id: "first",
            params: {
              protocolVersion: "2025-11-25",
              capabilities: {},
              clientInfo: { name: "original", version: "1.0" },
            },
          }
          second = {
            jsonrpc: "2.0",
            method: "initialize",
            id: "second",
            params: {
              protocolVersion: "2024-11-05",
              capabilities: {},
              clientInfo: { name: "intruder", version: "9.9" },
            },
          }
          input = StringIO.new("#{JSON.generate(first)}\n#{JSON.generate(second)}\n")
          output = StringIO.new
          original_stdin = $stdin
          original_stdout = $stdout

          begin
            $stdin = input
            $stdout = output
            @transport.open

            lines = output.string.lines
            assert_equal(2, lines.length)
            first_response = JSON.parse(lines[0], symbolize_names: true)
            second_response = JSON.parse(lines[1], symbolize_names: true)

            assert_equal("first", first_response[:id])
            refute_nil(first_response[:result])

            assert_equal("second", second_response[:id])
            assert_equal(-32600, second_response[:error][:code])
            assert_equal("Invalid Request", second_response[:error][:message])

            session = @transport.instance_variable_get(:@session)
            assert_equal({ name: "original", version: "1.0" }, session.client)
          ensure
            $stdin = original_stdin
            $stdout = original_stdout
          end
        end

        test "handles invalid JSON requests" do
          invalid_json = "invalid json"
          output = StringIO.new
          original_stdout = $stdout

          begin
            $stdout = output
            @transport.send(:handle_request, invalid_json)
            response = JSON.parse(output.string, symbolize_names: true)
            assert_equal("2.0", response[:jsonrpc])
            assert_nil(response[:id])
            assert_equal(-32600, response[:error][:code])
            assert_equal("Invalid Request", response[:error][:message])
            assert_equal("Request must be an array or a hash", response[:error][:data])
          ensure
            $stdout = original_stdout
          end
        end

        test "send_request sends request to stdout and waits for response" do
          reader, writer = IO.pipe
          output = StringIO.new
          original_stdin = $stdin
          original_stdout = $stdout

          begin
            $stdin = reader
            $stdout = output
            @transport.instance_variable_set(:@open, true)

            # Send response from client in a thread.
            Thread.new do
              sleep(0.05) # Wait for request to be written to `StringIO`.
              request = JSON.parse(output.string.lines.first, symbolize_names: true)
              response = {
                jsonrpc: "2.0",
                id: request[:id],
                result: { content: "test response" },
              }
              writer.puts(response.to_json)
              writer.flush
            end

            result = @transport.send_request("test/method", { param: "value" })

            assert_equal({ content: "test response" }, result)

            # Verify request was sent.
            request = JSON.parse(output.string.lines.first, symbolize_names: true)
            assert_equal("2.0", request[:jsonrpc])
            assert_equal("test/method", request[:method])
            assert_equal({ param: "value" }, request[:params])
            assert(request[:id])
          ensure
            $stdin = original_stdin
            $stdout = original_stdout
            begin
              writer.close
            rescue
              nil
            end
            begin
              reader.close
            rescue
              nil
            end
          end
        end

        test "send_request raises on error response from client" do
          reader, writer = IO.pipe
          output = StringIO.new
          original_stdin = $stdin
          original_stdout = $stdout

          begin
            $stdin = reader
            $stdout = output
            @transport.instance_variable_set(:@open, true)

            Thread.new do
              sleep(0.05) # Wait for request to be written to `StringIO`.
              request = JSON.parse(output.string.lines.first, symbolize_names: true)
              error_response = {
                jsonrpc: "2.0",
                id: request[:id],
                error: { code: -1, message: "User rejected sampling request" },
              }
              writer.puts(error_response.to_json)
              writer.flush
            end

            error = assert_raises(StandardError) do
              @transport.send_request("sampling/createMessage", { messages: [] })
            end

            assert_equal("Client returned an error for sampling/createMessage request (code: -1): User rejected sampling request", error.message)
          ensure
            $stdin = original_stdin
            $stdout = original_stdout
            begin
              writer.close
            rescue
              nil
            end
            begin
              reader.close
            rescue
              nil
            end
          end
        end

        test "send_request does not double-report intentional raises via exception_reporter" do
          reader, writer = IO.pipe
          output = StringIO.new
          original_stdin = $stdin
          original_stdout = $stdout
          reported_errors = []
          original_reporter = MCP.configuration.exception_reporter

          begin
            MCP.configuration.exception_reporter = ->(e, ctx) { reported_errors << [e, ctx] }
            $stdin = reader
            $stdout = output
            @transport.instance_variable_set(:@open, true)

            Thread.new do
              sleep(0.05) # Wait for request to be written to `StringIO`.
              request = JSON.parse(output.string.lines.first, symbolize_names: true)
              error_response = {
                jsonrpc: "2.0",
                id: request[:id],
                error: { code: -1, message: "rejected" },
              }
              writer.puts(error_response.to_json)
              writer.flush
            end

            assert_raises(StandardError) do
              @transport.send_request("sampling/createMessage", { messages: [] })
            end

            assert_empty(reported_errors)
          ensure
            MCP.configuration.exception_reporter = original_reporter
            $stdin = original_stdin
            $stdout = original_stdout
            begin
              writer.close
            rescue
              nil
            end
            begin
              reader.close
            rescue
              nil
            end
          end
        end

        test "send_request processes interleaved requests via session" do
          reader, writer = IO.pipe
          output = StringIO.new
          original_stdin = $stdin
          original_stdout = $stdout

          begin
            $stdin = reader
            $stdout = output
            @transport.instance_variable_set(:@open, true)

            # Initialize a session so @session is set.
            session = MCP::ServerSession.new(server: @server, transport: @transport)
            @transport.instance_variable_set(:@session, session)

            Thread.new do
              sleep(0.05) # Wait for request to be written to `StringIO`.
              request = JSON.parse(output.string.lines.first, symbolize_names: true)

              # Send an interleaved ping request before the response.
              ping = { jsonrpc: "2.0", method: "ping", id: "ping-1" }
              writer.puts(ping.to_json)
              writer.flush

              sleep(0.05) # Wait for the ping to be processed.

              # Then send the actual response.
              response = {
                jsonrpc: "2.0",
                id: request[:id],
                result: { content: "done" },
              }
              writer.puts(response.to_json)
              writer.flush
            end

            result = @transport.send_request("test/method", { param: "value" })

            assert_equal({ content: "done" }, result)

            # Verify the interleaved ping was handled (response sent to output).
            lines = output.string.lines
            ping_response = lines.find { |l| l.include?("ping-1") }
            assert(ping_response, "Interleaved ping request should have been handled")
          ensure
            $stdin = original_stdin
            $stdout = original_stdout
            begin
              writer.close
            rescue
              nil
            end
            begin
              reader.close
            rescue
              nil
            end
          end
        end

        test "send_request raises when transport is closed while waiting" do
          reader, writer = IO.pipe
          output = StringIO.new
          original_stdin = $stdin
          original_stdout = $stdout

          begin
            $stdin = reader
            $stdout = output
            @transport.instance_variable_set(:@open, true)

            # Close transport while waiting for response.
            Thread.new do
              sleep(0.05) # Wait for request to be written to `StringIO`.
              @transport.instance_variable_set(:@open, false)
              writer.close
            end

            error = assert_raises(RuntimeError) do
              @transport.send_request("sampling/createMessage", { messages: [] })
            end

            assert_equal("Transport closed while waiting for response to sampling/createMessage request.", error.message)
          ensure
            $stdin = original_stdin
            $stdout = original_stdout
            begin
              writer.close
            rescue IOError
              nil
            end
            begin
              reader.close
            rescue IOError
              nil
            end
          end
        end

        test "raises ArgumentError when max_line_bytes is not a positive Integer" do
          [nil, 0, -1, 1.5, "1024"].each do |invalid|
            error = assert_raises(ArgumentError) do
              StdioTransport.new(@server, max_line_bytes: invalid)
            end
            assert_equal("max_line_bytes must be a positive Integer", error.message)
          end
        end

        test "open stops and reports when a stdin frame exceeds max_line_bytes without a newline" do
          transport = StdioTransport.new(@server, max_line_bytes: 64)
          input = StringIO.new("A" * 200) # No newline: an unbounded frame.
          output = StringIO.new

          reported = []
          original_stdin = $stdin
          original_stdout = $stdout
          original_reporter = MCP.configuration.exception_reporter

          begin
            $stdin = input
            $stdout = output
            MCP.configuration.exception_reporter = ->(e, ctx) { reported << [e, ctx] }

            transport.open

            refute(transport.instance_variable_get(:@open))
            assert_equal(1, reported.size)
            error, _ctx = reported.first
            assert_instance_of(RequestHandlerError, error)
            assert_match(/exceeds 64 bytes without a newline/, error.message)
          ensure
            $stdin = original_stdin
            $stdout = original_stdout
            MCP.configuration.exception_reporter = original_reporter
          end
        end

        test "open processes a valid final frame that ends at EOF without a trailing newline" do
          request = { jsonrpc: "2.0", method: "ping", id: "eof" }
          input = StringIO.new(JSON.generate(request)) # No trailing newline.
          output = StringIO.new

          original_stdin = $stdin
          original_stdout = $stdout

          begin
            $stdin = input
            $stdout = output

            @transport.open

            response = JSON.parse(output.string, symbolize_names: true)
            assert_equal("eof", response[:id])
            assert_equal({}, response[:result])
          ensure
            $stdin = original_stdin
            $stdout = original_stdout
          end
        end

        test "send_request raises when a response frame exceeds max_line_bytes without a newline" do
          transport = StdioTransport.new(@server, max_line_bytes: 64)
          input = StringIO.new("A" * 200) # No newline: an unbounded frame.
          output = StringIO.new

          original_stdin = $stdin
          original_stdout = $stdout

          begin
            $stdin = input
            $stdout = output
            transport.instance_variable_set(:@open, true)

            error = assert_raises(RequestHandlerError) do
              transport.send_request("sampling/createMessage", { messages: [] })
            end

            assert_match(/exceeds 64 bytes without a newline/, error.message)
          ensure
            $stdin = original_stdin
            $stdout = original_stdout
          end
        end

        test "locks the legacy era on a successful initialize and rejects a later modern envelope" do
          responses = run_transport_session([
            initialize_request(id: 1),
            modern_tools_list_request(id: 2),
          ])

          refute responses[0].key?(:error)
          assert_equal :legacy, session_era
          assert_equal JsonRpcHandler::ErrorCode::INVALID_REQUEST, responses[1].dig(:error, :code)
        end

        test "initialize negotiating 2026-07-28 still locks the legacy era" do
          # 2026-07-28 serves both lifecycles of the dual-era model: negotiating it through
          # the legacy handshake locks `:legacy`, so a later modern envelope is still rejected.
          responses = run_transport_session([
            initialize_request(id: 1, protocol_version: "2026-07-28"),
            modern_tools_list_request(id: 2),
          ])

          assert_equal "2026-07-28", responses[0].dig(:result, :protocolVersion)
          assert_equal :legacy, session_era
          assert_equal JsonRpcHandler::ErrorCode::INVALID_REQUEST, responses[1].dig(:error, :code)
        end

        test "locks the modern era on a successful server/discover and rejects a later initialize with -32601" do
          responses = run_transport_session([
            { jsonrpc: "2.0", method: "server/discover", id: 1 },
            initialize_request(id: 2),
            modern_tools_list_request(id: 3),
          ])

          assert_equal Configuration::SUPPORTED_MODERN_PROTOCOL_VERSIONS, responses[0].dig(:result, :supportedVersions)
          assert_equal :modern, session_era
          # SEP-2575 removes `initialize` from the modern lifecycle, so a modern-locked connection
          # answers it with Method not found.
          assert_equal JsonRpcHandler::ErrorCode::METHOD_NOT_FOUND, responses[1].dig(:error, :code)
          refute responses[2].key?(:error)
        end

        test "locks the modern era on a successful request carrying the modern envelope" do
          responses = run_transport_session([modern_tools_list_request(id: 1)])

          refute responses[0].key?(:error)
          assert_equal :modern, session_era
        end

        test "rejects a removed lifecycle method carrying the envelope as the connection's first frame" do
          # The era locks only after a response succeeds, so this frame reaches the server unlocked.
          # SEP-2575 removed `resources/subscribe`, and the envelope is what identifies the request as modern.
          responses = run_transport_session([
            {
              jsonrpc: "2.0",
              method: "resources/subscribe",
              id: 1,
              params: {
                uri: "https://example.invalid/resource",
                _meta: {
                  "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                  "io.modelcontextprotocol/clientInfo": { name: "modern_client", version: "2.0" },
                  "io.modelcontextprotocol/clientCapabilities": {},
                },
              },
            },
          ])

          assert_equal JsonRpcHandler::ErrorCode::METHOD_NOT_FOUND, responses[0].dig(:error, :code)
          refute_equal :legacy, session_era
        end

        test "does not lock an era when the era-distinctive request fails" do
          # An unsupported envelope version fails with -32022, so the connection stays unlocked
          # and a legacy initialize can still succeed afterwards.
          responses = run_transport_session([
            modern_tools_list_request(id: 1, version: "2027-01-01"),
            initialize_request(id: 2),
          ])

          assert_equal ErrorCodes::UNSUPPORTED_PROTOCOL_VERSION, responses[0].dig(:error, :code)
          refute responses[1].key?(:error)
          assert_equal :legacy, session_era
        end

        test "requires the modern envelope after a modern era lock" do
          responses = run_transport_session([
            modern_tools_list_request(id: 1),
            { jsonrpc: "2.0", method: "tools/list", id: 2 },
          ])

          refute responses[0].key?(:error)
          assert_equal JsonRpcHandler::ErrorCode::INVALID_PARAMS, responses[1].dig(:error, :code)
        end

        test "answers removed lifecycle methods with -32601 after a modern era lock" do
          removed_requests = Methods::MODERN_REMOVED_METHODS.each_with_index.map do |method, index|
            { jsonrpc: "2.0", method: method, id: index + 2 }
          end
          responses = run_transport_session([modern_tools_list_request(id: 1)] + removed_requests)

          refute responses[0].key?(:error)
          responses[1..].each_with_index do |response, index|
            method = Methods::MODERN_REMOVED_METHODS[index]
            assert_equal JsonRpcHandler::ErrorCode::METHOD_NOT_FOUND, response.dig(:error, :code), "expected -32601 for #{method}"
          end
        end

        test "#send_request raises on a modern-locked session" do
          run_transport_session([modern_tools_list_request(id: 1)])

          error = assert_raises(RuntimeError) do
            @transport.send_request("roots/list")
          end
          assert_match(/modern lifecycle/, error.message)
        end

        private

        def initialize_request(id:, protocol_version: "2025-11-25")
          {
            jsonrpc: "2.0",
            method: "initialize",
            id: id,
            params: initialize_params(
              protocolVersion: protocol_version,
              clientInfo: { name: "legacy_client", version: "1.0" },
            ),
          }
        end

        # `tools/list` stands in as the era-distinctive modern request: `ping` cannot,
        # because SEP-2575 removes it from the modern lifecycle (-32601 there).
        def modern_tools_list_request(id:, version: "2026-07-28")
          {
            jsonrpc: "2.0",
            method: "tools/list",
            id: id,
            params: {
              _meta: {
                "io.modelcontextprotocol/protocolVersion": version,
                "io.modelcontextprotocol/clientInfo": { name: "modern_client", version: "2.0" },
                "io.modelcontextprotocol/clientCapabilities": {},
              },
            },
          }
        end

        # Feeds the frames to a fresh transport session over swapped stdio and returns the parsed responses in order.
        def run_transport_session(frames)
          input = StringIO.new(frames.map { |frame| JSON.generate(frame) }.join("\n") + "\n")
          output = StringIO.new

          original_stdin = $stdin
          original_stdout = $stdout

          begin
            $stdin = input
            $stdout = output

            thread = Thread.new { @transport.open }
            sleep(0.1)
            @transport.close
            thread.join
          ensure
            $stdin = original_stdin
            $stdout = original_stdout
          end

          output.string.each_line.map { |line| JSON.parse(line, symbolize_names: true) }
        end

        def session_era
          @transport.instance_variable_get(:@session).era
        end
      end
    end
  end
end
