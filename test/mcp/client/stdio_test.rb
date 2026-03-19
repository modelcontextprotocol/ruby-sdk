# frozen_string_literal: true

require "test_helper"
require "json"
require "mcp/client"
require "mcp/client/stdio"
require "mcp/client/tool"

module MCP
  class Client
    class StdioTest < Minitest::Test
      def test_send_request_starts_process_and_returns_response
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        request = {
          jsonrpc: "2.0",
          id: "test-id",
          method: "tools/list",
        }

        # Simulate server responses: initialize response, then tools/list response
        Thread.new do
          # Read and respond to initialize request
          init_line = stdin_read.gets
          init_request = JSON.parse(init_line)
          init_response = {
            jsonrpc: "2.0",
            id: init_request["id"],
            result: {
              protocolVersion: "2025-11-25",
              capabilities: {},
              serverInfo: { name: "test-server", version: "1.0.0" },
            },
          }
          stdout_write.puts(JSON.generate(init_response))
          stdout_write.flush

          # Read initialized notification
          stdin_read.gets

          # Read and respond to tools/list request
          tools_line = stdin_read.gets
          tools_request = JSON.parse(tools_line)
          tools_response = {
            jsonrpc: "2.0",
            id: tools_request["id"],
            result: { tools: [{ name: "test_tool", description: "A test tool", inputSchema: {} }] },
          }
          stdout_write.puts(JSON.generate(tools_response))
          stdout_write.flush
        end

        response = transport.send_request(request: request)

        assert_equal("test-id", response["id"])
        assert_equal(1, response.dig("result", "tools").size)
        assert_equal("test_tool", response.dig("result", "tools", 0, "name"))
      ensure
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      def test_send_request_initializes_session_on_first_call
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        request = {
          jsonrpc: "2.0",
          id: "test-id",
          method: "tools/list",
        }

        received_methods = []

        Thread.new do
          # Read initialize request
          init_line = stdin_read.gets
          init_request = JSON.parse(init_line)
          received_methods << init_request["method"]

          init_response = {
            jsonrpc: "2.0",
            id: init_request["id"],
            result: {
              protocolVersion: "2025-11-25",
              capabilities: {},
              serverInfo: { name: "test-server", version: "1.0.0" },
            },
          }
          stdout_write.puts(JSON.generate(init_response))
          stdout_write.flush

          # Read initialized notification
          notification_line = stdin_read.gets
          notification = JSON.parse(notification_line)
          received_methods << notification["method"]

          # Read tools/list request
          tools_line = stdin_read.gets
          tools_request = JSON.parse(tools_line)
          received_methods << tools_request["method"]

          tools_response = {
            jsonrpc: "2.0",
            id: tools_request["id"],
            result: { tools: [] },
          }
          stdout_write.puts(JSON.generate(tools_response))
          stdout_write.flush
        end

        transport.send_request(request: request)

        assert_equal(["initialize", "notifications/initialized", "tools/list"], received_methods)
      ensure
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      def test_send_request_skips_notifications
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        request = {
          jsonrpc: "2.0",
          id: "test-id",
          method: "tools/list",
        }

        Thread.new do
          # Handle initialize handshake
          init_line = stdin_read.gets
          init_request = JSON.parse(init_line)
          stdout_write.puts(JSON.generate({
            jsonrpc: "2.0",
            id: init_request["id"],
            result: {
              protocolVersion: "2025-11-25",
              capabilities: {},
              serverInfo: { name: "test-server", version: "1.0.0" },
            },
          }))
          stdout_write.flush

          # Read initialized notification
          stdin_read.gets

          # Read tools/list request
          stdin_read.gets

          # Send a notification before the response
          notification = { jsonrpc: "2.0", method: "notifications/tools/list_changed" }
          stdout_write.puts(JSON.generate(notification))
          stdout_write.flush

          # Then send the actual response
          stdout_write.puts(JSON.generate({
            jsonrpc: "2.0",
            id: "test-id",
            result: { tools: [] },
          }))
          stdout_write.flush
        end

        response = transport.send_request(request: request)

        assert_equal("test-id", response["id"])
        assert_equal([], response.dig("result", "tools"))
      ensure
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      def test_send_request_raises_error_when_process_exits
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe

        dead_thread = mock("wait_thread")
        dead_thread.stubs(:alive?).returns(false)
        dead_thread.stubs(:value).returns(nil)

        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, dead_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])
        transport.start

        request = {
          jsonrpc: "2.0",
          id: "test-id",
          method: "tools/list",
        }

        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: request)
        end

        assert_equal("Server process has exited", error.message)
        assert_equal(:internal_error, error.error_type)
      ensure
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      def test_send_request_raises_error_on_closed_stdout
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        request = {
          jsonrpc: "2.0",
          id: "test-id",
          method: "tools/list",
        }

        Thread.new do
          # Handle initialize handshake
          init_line = stdin_read.gets
          init_request = JSON.parse(init_line)
          stdout_write.puts(JSON.generate({
            jsonrpc: "2.0",
            id: init_request["id"],
            result: {
              protocolVersion: "2025-11-25",
              capabilities: {},
              serverInfo: { name: "test-server", version: "1.0.0" },
            },
          }))
          stdout_write.flush

          # Read initialized notification
          stdin_read.gets

          # Read tools/list request, then close stdout
          stdin_read.gets
          stdout_write.close
        end

        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: request)
        end

        assert_equal("Server process closed stdout unexpectedly", error.message)
        assert_equal(:internal_error, error.error_type)
      ensure
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      def test_close_resets_state
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, stderr_write = IO.pipe

        wait_thread = mock("wait_thread")
        wait_thread.stubs(:alive?).returns(true)
        wait_thread.stubs(:value).returns(nil)

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])
        transport.start

        assert(transport.instance_variable_get(:@started))

        transport.close

        refute(transport.instance_variable_get(:@started))
        refute(transport.instance_variable_get(:@initialized))
      ensure
        stdin_read.close
        begin
          stdin_write.close
        rescue
          nil
        end
        begin
          stdout_read.close
        rescue
          nil
        end
        stdout_write.close
        begin
          stderr_read.close
        rescue
          nil
        end
        stderr_write.close
      end

      def test_send_request_skips_initialization_on_second_call
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        received_methods = []

        Thread.new do
          # First call: initialize handshake
          init_line = stdin_read.gets
          init_request = JSON.parse(init_line)
          received_methods << init_request["method"]

          stdout_write.puts(JSON.generate({
            jsonrpc: "2.0",
            id: init_request["id"],
            result: {
              protocolVersion: "2025-11-25",
              capabilities: {},
              serverInfo: { name: "test-server", version: "1.0.0" },
            },
          }))
          stdout_write.flush

          # Read initialized notification
          notification_line = stdin_read.gets
          received_methods << JSON.parse(notification_line)["method"]

          # First request: tools/list
          first_line = stdin_read.gets
          first_request = JSON.parse(first_line)
          received_methods << first_request["method"]

          stdout_write.puts(JSON.generate({
            jsonrpc: "2.0",
            id: first_request["id"],
            result: { tools: [] },
          }))
          stdout_write.flush

          # Second request: tools/list (no re-initialization)
          second_line = stdin_read.gets
          second_request = JSON.parse(second_line)
          received_methods << second_request["method"]

          stdout_write.puts(JSON.generate({
            jsonrpc: "2.0",
            id: second_request["id"],
            result: { tools: [] },
          }))
          stdout_write.flush
        end

        transport.send_request(request: { jsonrpc: "2.0", id: "first", method: "tools/list" })
        transport.send_request(request: { jsonrpc: "2.0", id: "second", method: "tools/list" })

        assert_equal(
          ["initialize", "notifications/initialized", "tools/list", "tools/list"],
          received_methods,
        )
      ensure
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      def test_env_is_passed_to_process
        transport = Stdio.new(command: "ruby", args: ["server.rb"], env: { "FOO" => "bar" })

        Open3.expects(:popen3).with({ "FOO" => "bar" }, "ruby", "server.rb").returns(
          [StringIO.new, StringIO.new, StringIO.new, mock_wait_thread],
        )

        transport.start
      end

      def test_send_request_raises_error_on_invalid_json
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        request = {
          jsonrpc: "2.0",
          id: "test-id",
          method: "tools/list",
        }

        Thread.new do
          # Handle initialize handshake
          init_line = stdin_read.gets
          init_request = JSON.parse(init_line)
          stdout_write.puts(JSON.generate({
            jsonrpc: "2.0",
            id: init_request["id"],
            result: {
              protocolVersion: "2025-11-25",
              capabilities: {},
              serverInfo: { name: "test-server", version: "1.0.0" },
            },
          }))
          stdout_write.flush

          # Read initialized notification
          stdin_read.gets

          # Read tools/list request, then send invalid JSON
          stdin_read.gets
          stdout_write.puts("not valid json")
          stdout_write.flush
        end

        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: request)
        end

        assert_equal("Failed to parse server response", error.message)
        assert_equal(:internal_error, error.error_type)
        assert_instance_of(JSON::ParserError, error.original_error)
      ensure
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      def test_send_request_raises_error_when_initialization_fails
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        request = {
          jsonrpc: "2.0",
          id: "test-id",
          method: "tools/list",
        }

        Thread.new do
          # Read initialize request and return an error
          init_line = stdin_read.gets
          init_request = JSON.parse(init_line)
          stdout_write.puts(JSON.generate({
            jsonrpc: "2.0",
            id: init_request["id"],
            error: { code: -32600, message: "Invalid Request", data: "Unsupported protocol version" },
          }))
          stdout_write.flush
        end

        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: request)
        end

        assert_equal("Server initialization failed: Invalid Request", error.message)
        assert_equal(:internal_error, error.error_type)
      ensure
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      def test_close_kills_process_on_timeout
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        hanging_thread = mock("wait_thread")
        hanging_thread.stubs(:alive?).returns(true)
        hanging_thread.stubs(:pid).returns(99999)
        hanging_thread.stubs(:value).raises(Timeout::Error)

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, hanging_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])
        transport.start

        Process.expects(:kill).with("TERM", 99999).once
        Process.expects(:kill).with("KILL", 99999).once

        transport.close
      ensure
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      def test_read_response_raises_error_on_timeout
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"], read_timeout: 0.01)

        request = {
          jsonrpc: "2.0",
          id: "test-id",
          method: "tools/list",
        }

        Thread.new do
          # Handle initialize handshake
          init_line = stdin_read.gets
          init_request = JSON.parse(init_line)
          stdout_write.puts(JSON.generate({
            jsonrpc: "2.0",
            id: init_request["id"],
            result: {
              protocolVersion: "2025-11-25",
              capabilities: {},
              serverInfo: { name: "test-server", version: "1.0.0" },
            },
          }))
          stdout_write.flush

          # Read initialized notification
          stdin_read.gets

          # Read tools/list request but don't respond (simulate timeout)
          stdin_read.gets
        end

        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: request)
        end

        assert_equal("Timed out waiting for server response", error.message)
        assert_equal(:internal_error, error.error_type)
      ensure
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      def test_send_request_raises_error_when_stdin_is_closed
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        server_thread = Thread.new do
          # Handle initialize handshake
          init_line = stdin_read.gets
          init_request = JSON.parse(init_line)
          stdout_write.puts(JSON.generate({
            jsonrpc: "2.0",
            id: init_request["id"],
            result: {
              protocolVersion: "2025-11-25",
              capabilities: {},
              serverInfo: { name: "test-server", version: "1.0.0" },
            },
          }))
          stdout_write.flush

          # Read initialized notification
          stdin_read.gets

          # Read and respond to first request
          line = stdin_read.gets
          request = JSON.parse(line)
          stdout_write.puts(JSON.generate({
            jsonrpc: "2.0",
            id: request["id"],
            result: {},
          }))
          stdout_write.flush
        end

        # Complete handshake with a successful request
        transport.send_request(request: { jsonrpc: "2.0", id: "setup", method: "ping" })
        server_thread.join

        # Now close stdin to simulate broken pipe
        stdin_write.close

        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: { jsonrpc: "2.0", id: "test-id", method: "tools/list" })
        end

        assert_equal("Failed to write to server process", error.message)
        assert_equal(:internal_error, error.error_type)
      ensure
        stdin_read.close
        begin
          stdin_write.close
        rescue
          nil
        end
        stdout_read.close
        stdout_write.close
      end

      def test_close_is_noop_when_not_started
        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        # Should not raise
        transport.close
      end

      def test_start_raises_error_when_already_started
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])
        transport.start

        error = assert_raises(RuntimeError) do
          transport.start
        end

        assert_equal("MCP::Client::Stdio already started", error.message)
      ensure
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      def test_start_raises_error_for_invalid_command
        Open3.stubs(:popen3).raises(Errno::ENOENT.new("No such file or directory - nonexistent_command"))

        transport = Stdio.new(command: "nonexistent_command")

        error = assert_raises(RequestHandlerError) do
          transport.start
        end

        assert_match(/Failed to spawn server process/, error.message)
        assert_equal(:internal_error, error.error_type)
        assert_instance_of(Errno::ENOENT, error.original_error)
      end

      def test_send_request_raises_error_for_missing_result
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        request = {
          jsonrpc: "2.0",
          id: "test-id",
          method: "tools/list",
        }

        Thread.new do
          # Read initialize request and return a response without result
          init_line = stdin_read.gets
          init_request = JSON.parse(init_line)
          stdout_write.puts(JSON.generate({
            jsonrpc: "2.0",
            id: init_request["id"],
          }))
          stdout_write.flush
        end

        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: request)
        end

        assert_equal("Server initialization failed: missing result in response", error.message)
        assert_equal(:internal_error, error.error_type)
      ensure
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      private

      def mock_wait_thread
        thread = mock("wait_thread")
        thread.stubs(:alive?).returns(true)
        thread.stubs(:value).returns(nil)
        thread
      end
    end
  end
end
