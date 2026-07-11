# frozen_string_literal: true

require "test_helper"
require "json"
require "mcp/client"
require "mcp/client/stdio"
require "mcp/client/tool"

module MCP
  class Client
    class StdioTest < Minitest::Test
      def test_send_request_raises_when_connect_not_called
        Open3.expects(:popen3).never

        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        error = assert_raises(RuntimeError) do
          transport.send_request(request: { jsonrpc: "2.0", id: "test-id", method: "tools/list" })
        end

        assert_equal("MCP::Client#connect must be called before sending requests.", error.message)
      end

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
        server_thread = Thread.new do
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

        transport.connect
        response = transport.send_request(request: request)

        assert_equal("test-id", response["id"])
        assert_equal(1, response.dig("result", "tools").size)
        assert_equal("test_tool", response.dig("result", "tools", 0, "name"))
      ensure
        server_thread.join
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
        stderr_read.close
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

        transport.connect
        response = transport.send_request(request: request)

        assert_equal("test-id", response["id"])
        assert_empty(response.dig("result", "tools"))
      ensure
        server_thread.join
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      def test_send_request_skips_non_object_frames
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

        server_thread = Thread.new do
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

          # Non-object frames are skipped like any other non-matching frame.
          stdout_write.puts("[[]]")
          stdout_write.puts("null")
          stdout_write.flush

          # Then send the actual response
          stdout_write.puts(JSON.generate({
            jsonrpc: "2.0",
            id: "test-id",
            result: { tools: [] },
          }))
          stdout_write.flush
        end

        transport.connect
        response = transport.send_request(request: request)

        assert_equal("test-id", response["id"])
        assert_empty(response.dig("result", "tools"))
      ensure
        server_thread.join
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

        error = assert_raises(RequestHandlerError) do
          transport.connect
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

          # Read tools/list request, then close stdout
          stdin_read.gets
          stdout_write.close
        end

        transport.connect
        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: request)
        end

        assert_equal("Server process closed stdout unexpectedly", error.message)
        assert_equal(:internal_error, error.error_type)
      ensure
        server_thread.join
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

      def test_multiple_send_requests_do_not_reinitialize
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        received_methods = []

        server_thread = Thread.new do
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

        transport.connect
        transport.send_request(request: { jsonrpc: "2.0", id: "first", method: "tools/list" })
        transport.send_request(request: { jsonrpc: "2.0", id: "second", method: "tools/list" })

        assert_equal(
          ["initialize", "notifications/initialized", "tools/list", "tools/list"],
          received_methods,
        )
      ensure
        server_thread.join
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

          # Read tools/list request, then send invalid JSON
          stdin_read.gets
          stdout_write.puts("not valid json")
          stdout_write.flush
        end

        transport.connect
        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: request)
        end

        assert_equal("Failed to parse server response", error.message)
        assert_equal(:internal_error, error.error_type)
        assert_instance_of(JSON::ParserError, error.original_error)
      ensure
        server_thread.join
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

          # Read tools/list request but don't respond (simulate timeout)
          stdin_read.gets
        end

        transport.connect
        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: request)
        end

        assert_equal("Timed out waiting for server response", error.message)
        assert_equal(:internal_error, error.error_type)
      ensure
        server_thread.join
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

        transport.connect
        # Complete a successful request before breaking the pipe.
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

      def test_connect_performs_initialize_handshake_explicitly
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        received_methods = []

        server_thread = Thread.new do
          init_line = stdin_read.gets
          init_request = JSON.parse(init_line)
          received_methods << init_request["method"]
          stdout_write.puts(JSON.generate(
            jsonrpc: "2.0",
            id: init_request["id"],
            result: {
              protocolVersion: "2025-11-25",
              capabilities: { tools: {} },
              serverInfo: { name: "test-server", version: "1.0.0" },
            },
          ))
          stdout_write.flush

          notification_line = stdin_read.gets
          received_methods << JSON.parse(notification_line)["method"]
        end

        result = transport.connect

        server_thread.join

        assert_equal(["initialize", "notifications/initialized"], received_methods)
        assert_equal("2025-11-25", result["protocolVersion"])
        assert_equal({ "tools" => {} }, result["capabilities"])
        assert_equal({ "name" => "test-server", "version" => "1.0.0" }, result["serverInfo"])
      ensure
        server_thread.join
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      def test_send_request_does_not_warn_after_explicit_connect
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        server_thread = Thread.new do
          init_line = stdin_read.gets
          init_request = JSON.parse(init_line)
          stdout_write.puts(JSON.generate(
            jsonrpc: "2.0",
            id: init_request["id"],
            result: {
              protocolVersion: "2025-11-25",
              capabilities: {},
              serverInfo: { name: "test-server", version: "1.0.0" },
            },
          ))
          stdout_write.flush

          stdin_read.gets

          ping_line = stdin_read.gets
          ping_request = JSON.parse(ping_line)
          stdout_write.puts(JSON.generate(
            jsonrpc: "2.0",
            id: ping_request["id"],
            result: {},
          ))
          stdout_write.flush
        end

        assert_silent do
          transport.connect
        end

        response = nil
        assert_silent do
          response = transport.send_request(request: { jsonrpc: "2.0", id: "ping-id", method: "ping" })
        end

        assert_equal("ping-id", response["id"])
      ensure
        server_thread.join
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      def test_connect_caches_server_info
        transport, server_thread, pipes = stub_successful_connect

        transport.connect

        assert_equal("2025-11-25", transport.server_info["protocolVersion"])
        assert_equal({ "tools" => {} }, transport.server_info["capabilities"])
      ensure
        server_thread.join
        pipes.each(&:close)
      end

      def test_connect_is_idempotent
        transport, server_thread, pipes = stub_successful_connect

        first_result = transport.connect
        second_result = transport.connect

        assert_same(first_result, second_result)
      ensure
        server_thread.join
        pipes.each(&:close)
      end

      def test_connect_accepts_custom_parameters
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        sent_init_params = nil

        server_thread = Thread.new do
          init_line = stdin_read.gets
          init_request = JSON.parse(init_line)
          sent_init_params = init_request["params"]
          stdout_write.puts(JSON.generate(
            jsonrpc: "2.0",
            id: init_request["id"],
            result: { protocolVersion: "2025-03-26" },
          ))
          stdout_write.flush
          stdin_read.gets
        end

        transport.connect(
          client_info: { name: "my-app", version: "9.9" },
          protocol_version: "2025-03-26",
          capabilities: { roots: { listChanged: true } },
        )

        assert_equal("2025-03-26", sent_init_params["protocolVersion"])
        assert_equal({ "name" => "my-app", "version" => "9.9" }, sent_init_params["clientInfo"])
        assert_equal({ "roots" => { "listChanged" => true } }, sent_init_params["capabilities"])
      ensure
        server_thread.join
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      def test_connect_raises_on_jsonrpc_error_response
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        server_thread = Thread.new do
          init_line = stdin_read.gets
          init_request = JSON.parse(init_line)
          stdout_write.puts(JSON.generate(
            jsonrpc: "2.0",
            id: init_request["id"],
            error: { code: -32602, message: "boom" },
          ))
          stdout_write.flush
        end

        error = assert_raises(RequestHandlerError) do
          transport.connect
        end

        assert_includes(error.message, "boom")
        refute_predicate(transport, :connected?)
      ensure
        server_thread.join
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      def test_connect_raises_on_missing_result
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        server_thread = Thread.new do
          init_line = stdin_read.gets
          init_request = JSON.parse(init_line)
          stdout_write.puts(JSON.generate(
            jsonrpc: "2.0",
            id: init_request["id"],
          ))
          stdout_write.flush
        end

        error = assert_raises(RequestHandlerError) do
          transport.connect
        end

        assert_includes(error.message, "missing result in response")
        refute_predicate(transport, :connected?)
      ensure
        server_thread.join
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      def test_connect_raises_on_non_hash_result
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        server_thread = Thread.new do
          init_line = stdin_read.gets
          init_request = JSON.parse(init_line)
          stdout_write.puts(JSON.generate(
            jsonrpc: "2.0",
            id: init_request["id"],
            result: [],
          ))
          stdout_write.flush
        end

        error = assert_raises(RequestHandlerError) do
          transport.connect
        end

        assert_includes(error.message, "missing result in response")
        refute_predicate(transport, :connected?)
        assert_nil(transport.server_info)
      ensure
        server_thread.join
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      def test_connect_clears_state_when_initialized_notification_fails
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        server_thread = Thread.new do
          init_line = stdin_read.gets
          init_request = JSON.parse(init_line)
          # Close stdin_read first so the next write to @stdin (the notification) raises EPIPE.
          stdin_read.close
          stdout_write.puts(JSON.generate(
            jsonrpc: "2.0",
            id: init_request["id"],
            result: { protocolVersion: "2025-11-25" },
          ))
          stdout_write.flush
        end

        assert_raises(RequestHandlerError) do
          transport.connect
        end

        refute_predicate(transport, :connected?)
        assert_nil(transport.server_info)
      ensure
        server_thread.join
        [stdin_read, stdin_write, stdout_read, stdout_write].each do |io|
          io.close unless io.closed?
        end
      end

      def test_connect_can_be_retried_after_failed_handshake
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        server_thread = Thread.new do
          # First handshake: server returns an unsupported protocol version.
          init_line = stdin_read.gets
          init_request = JSON.parse(init_line)
          stdout_write.puts(JSON.generate(
            jsonrpc: "2.0",
            id: init_request["id"],
            result: { protocolVersion: "1999-01-01" },
          ))
          stdout_write.flush

          # Second handshake: server returns a supported protocol version.
          init_line = stdin_read.gets
          init_request = JSON.parse(init_line)
          stdout_write.puts(JSON.generate(
            jsonrpc: "2.0",
            id: init_request["id"],
            result: { protocolVersion: "2025-11-25" },
          ))
          stdout_write.flush
          stdin_read.gets
        end

        assert_raises(RequestHandlerError) do
          transport.connect
        end

        refute_predicate(transport, :connected?)
        assert_nil(transport.server_info)

        result = transport.connect

        server_thread.join

        assert_predicate(transport, :connected?)
        assert_equal("2025-11-25", result["protocolVersion"])
      ensure
        server_thread.join
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      def test_connect_raises_on_unsupported_protocol_version
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        sent_methods = []

        server_thread = Thread.new do
          init_line = stdin_read.gets
          init_request = JSON.parse(init_line)
          sent_methods << init_request["method"]
          stdout_write.puts(JSON.generate(
            jsonrpc: "2.0",
            id: init_request["id"],
            result: { protocolVersion: "1999-01-01" },
          ))
          stdout_write.flush
        end

        error = assert_raises(RequestHandlerError) do
          transport.connect
        end

        assert_includes(error.message, "unsupported protocol version")
        assert_includes(error.message, "1999-01-01")
        assert_equal(["initialize"], sent_methods)
        refute_predicate(transport, :connected?)
        assert_nil(transport.server_info)
      ensure
        server_thread.join
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      def test_connected_is_false_before_first_send_request
        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        refute_predicate(transport, :connected?)
      end

      def test_connected_is_true_after_explicit_connect
        transport, server_thread, pipes = stub_successful_connect

        refute_predicate(transport, :connected?)

        transport.connect

        assert_predicate(transport, :connected?)
      ensure
        server_thread.join
        pipes.each(&:close)
      end

      def test_connected_is_false_after_close
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, stderr_write = IO.pipe

        wait_thread = mock("wait_thread")
        wait_thread.stubs(:alive?).returns(true)
        wait_thread.stubs(:value).returns(nil)

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])
        transport.start
        transport.instance_variable_set(:@initialized, true)

        assert_predicate(transport, :connected?)

        transport.close

        refute_predicate(transport, :connected?)
      ensure
        [stdin_read, stdin_write, stdout_read, stdout_write, stderr_read, stderr_write].each do |io|
          io.close unless io.closed?
        end
      end

      def test_server_info_is_nil_before_connect
        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        assert_nil(transport.server_info)
      end

      def test_server_info_is_cleared_after_close
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, stderr_write = IO.pipe

        wait_thread = mock("wait_thread")
        wait_thread.stubs(:alive?).returns(true)
        wait_thread.stubs(:value).returns(nil)

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])
        transport.start
        transport.instance_variable_set(:@initialized, true)
        transport.instance_variable_set(:@server_info, { "protocolVersion" => "2025-11-25" })

        transport.close

        assert_nil(transport.server_info)
      ensure
        [stdin_read, stdin_write, stdout_read, stdout_write, stderr_read, stderr_write].each do |io|
          io.close unless io.closed?
        end
      end

      def test_new_raises_argument_error_when_max_line_bytes_is_not_a_positive_integer
        [nil, 0, -1, 1.5, "1024"].each do |invalid|
          error = assert_raises(ArgumentError) do
            Stdio.new(command: "ruby", args: ["server.rb"], max_line_bytes: invalid)
          end
          assert_equal("max_line_bytes must be a positive Integer", error.message)
        end
      end

      def test_send_request_raises_when_response_frame_exceeds_max_line_bytes
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"], max_line_bytes: 1024)

        request = { jsonrpc: "2.0", id: "test-id", method: "tools/list" }

        server_thread = Thread.new do
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

          # Read initialized notification.
          stdin_read.gets

          # Read tools/list request, then stream an unbounded frame with no newline.
          stdin_read.gets
          stdout_write.write("A" * 2000)
          stdout_write.flush
        end

        transport.connect

        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: request)
        end

        assert_match(/exceeds 1024 bytes without a newline/, error.message)
        assert_equal(:internal_error, error.error_type)
        # The stream is desynced (leftover bytes in the pipe), so the transport is closed
        # rather than left resumable on a corrupt stream.
        refute_predicate(transport, :connected?)
      ensure
        server_thread.join
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      def test_send_request_accepts_response_within_custom_max_line_bytes
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"], max_line_bytes: 1024)

        request = { jsonrpc: "2.0", id: "test-id", method: "tools/list" }

        server_thread = Thread.new do
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

          stdin_read.gets

          tools_line = stdin_read.gets
          tools_request = JSON.parse(tools_line)
          stdout_write.puts(JSON.generate({
            jsonrpc: "2.0",
            id: tools_request["id"],
            result: { tools: [] },
          }))
          stdout_write.flush
        end

        transport.connect

        response = transport.send_request(request: request)

        assert_equal("test-id", response["id"])
        assert_equal({ "tools" => [] }, response["result"])
      ensure
        server_thread.join
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      def test_send_notification_writes_json_line_without_waiting_for_response
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        notification = {
          jsonrpc: "2.0",
          method: MCP::Methods::NOTIFICATIONS_CANCELLED,
          params: { requestId: "abc-123", reason: "user cancel" },
        }

        # Server: respond to initialize, then read the notification line.
        server_thread = Thread.new do
          init_line = stdin_read.gets
          init_request = JSON.parse(init_line)
          stdout_write.puts(JSON.generate({
            jsonrpc: "2.0",
            id: init_request["id"],
            result: { protocolVersion: "2025-11-25", capabilities: {}, serverInfo: { name: "test", version: "1.0.0" } },
          }))
          stdout_write.flush

          stdin_read.gets # skip initialized notification

          stdin_read.gets # read the cancellation notification line we are testing
        end

        result = transport.send_notification(notification: notification)

        assert_nil(result, "send_notification must return nil (no response expected)")
      ensure
        server_thread.join
        stdin_read.close
        stdin_write.close
        stdout_read.close
        stdout_write.close
      end

      def test_concurrent_write_message_does_not_interleave_lines
        # Regression: cancellation can call `send_notification` from a thread while `send_request` is mid-flight
        # on another thread. The two writes must serialize so JSON-RPC lines do not interleave on stdin.
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        # Server: respond to initialize, then accept multiple lines.
        server_thread = Thread.new do
          init_line = stdin_read.gets
          init_request = JSON.parse(init_line)
          stdout_write.puts(JSON.generate({
            jsonrpc: "2.0",
            id: init_request["id"],
            result: { protocolVersion: "2025-11-25", capabilities: {}, serverInfo: { name: "t", version: "1.0.0" } },
          }))
          stdout_write.flush
          stdin_read.gets # initialized
        end

        # Force initialization synchronously.
        notification = {
          jsonrpc: "2.0",
          method: MCP::Methods::NOTIFICATIONS_CANCELLED,
          params: { requestId: "warmup" },
        }
        transport.send_notification(notification: notification)
        server_thread.join

        # Now hammer send_notification from many threads concurrently. Each line is one JSON object terminated by `\n`;
        # if writes interleave, the received text would not be one valid JSON object per line.
        threads = 8.times.map do |i|
          Thread.new do
            10.times do |j|
              transport.send_notification(
                notification: {
                  jsonrpc: "2.0",
                  method: MCP::Methods::NOTIFICATIONS_CANCELLED,
                  params: { requestId: "t#{i}-#{j}" },
                },
              )
            end
          end
        end
        threads.each(&:join)

        # Drain everything written to stdin and verify each line parses as JSON.
        stdin_write.close
        lines = []
        until stdin_read.eof?
          line = stdin_read.gets
          break if line.nil?

          lines << line
        end
        lines.each do |line|
          assert(JSON.parse(line.strip), "interleaved write produced unparseable line: #{line.inspect}")
        end
        assert_operator(lines.size, :>=, 80, "expected at least 80 notification lines")
      ensure
        stdout_read.close
        stdout_write.close
        begin
          stderr_read.close
        rescue
          nil
        end
      end

      private

      def stub_successful_connect
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stderr_read, _ = IO.pipe

        Open3.stubs(:popen3).returns([stdin_write, stdout_read, stderr_read, mock_wait_thread])

        transport = Stdio.new(command: "ruby", args: ["server.rb"])

        server_thread = Thread.new do
          init_line = stdin_read.gets
          init_request = JSON.parse(init_line)
          stdout_write.puts(JSON.generate(
            jsonrpc: "2.0",
            id: init_request["id"],
            result: {
              protocolVersion: "2025-11-25",
              capabilities: { tools: {} },
              serverInfo: { name: "test-server", version: "1.0.0" },
            },
          ))
          stdout_write.flush
          stdin_read.gets
        end

        [transport, server_thread, [stdin_read, stdin_write, stdout_read, stdout_write]]
      end

      def mock_wait_thread
        thread = mock("wait_thread")
        thread.stubs(:alive?).returns(true)
        thread.stubs(:value).returns(nil)
        thread
      end
    end
  end
end
