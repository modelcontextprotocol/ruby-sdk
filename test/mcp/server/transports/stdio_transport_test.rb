# frozen_string_literal: true

require "test_helper"

module MCP
  class Server
    module Transports
      class StdioTransportTest < ActiveSupport::TestCase
        include InstrumentationTestHelper

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
      end
    end
  end
end
