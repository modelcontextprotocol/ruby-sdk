# frozen_string_literal: true

require "json"
require_relative "../../transport"

module MCP
  class Server
    module Transports
      class StdioTransport < Transport
        STATUS_INTERRUPTED = Signal.list["INT"] + 128

        # Default upper bound on a single newline-delimited frame. CRuby's `IO#gets`
        # without a limit accumulates bytes until a newline arrives, so a peer that
        # never emits one can grow a single String until the process is OOM-killed.
        # 4 MiB is large enough for any realistic JSON-RPC frame, including
        # base64-embedded images.
        MAX_LINE_BYTES = 4 * 1024 * 1024

        def initialize(server, max_line_bytes: MAX_LINE_BYTES)
          super(server)
          @open = false
          @session = nil
          # Reject `nil` or non-positive values: `IO#gets("\n", nil)` and a negative
          # limit read without an upper bound, which would silently disable the
          # protection this option exists to provide.
          unless max_line_bytes.is_a?(Integer) && max_line_bytes > 0
            raise ArgumentError, "max_line_bytes must be a positive Integer"
          end

          @max_line_bytes = max_line_bytes
          $stdin.set_encoding("UTF-8")
          $stdout.set_encoding("UTF-8")
        end

        def open
          @open = true
          @session = ServerSession.new(server: @server, transport: self)
          while @open
            begin
              line = read_line($stdin)
            rescue RequestHandlerError => e
              # Stop accumulating and end the connection gracefully rather than
              # letting an unbounded read exhaust memory or escape as an uncaught
              # backtrace. Scoped to the read so genuine request errors raised while
              # handling a frame are not swallowed here.
              @open = false
              MCP.configuration.exception_reporter.call(e, { error: "stdio frame exceeds limit" })
              break
            end
            break if line.nil?

            response = @session.handle_json(line.strip)
            send_response(response) if response
          end
        rescue Interrupt
          warn("\nExiting...")

          exit(STATUS_INTERRUPTED)
        end

        def close
          @open = false
        end

        def send_response(message)
          json_message = message.is_a?(String) ? message : JSON.generate(message)
          $stdout.puts(json_message)
          $stdout.flush
        end

        def send_notification(method, params = nil)
          notification = {
            jsonrpc: "2.0",
            method: method,
          }
          notification[:params] = params if params

          send_response(notification)
          true
        rescue => e
          MCP.configuration.exception_reporter.call(e, { error: "Failed to send notification" })
          false
        end

        # NOTE: This signature deliberately matches the abstract `Transport#send_request` contract
        # (`method, params = nil`) without the cancellation kwargs that `StreamableHTTPTransport#send_request` accepts.
        # On Ruby 2.7 the project's supported minimum a method that mixes a positional `params` Hash with
        # explicit keyword arguments cannot be called as `send_request(method, { ... })` - the trailing Hash would be
        # auto-promoted to keyword arguments. Stdio is single-threaded and blocks on `$stdin.gets`, so nested-request
        # cancellation has very limited value here regardless; servers that need cancellation propagation for nested
        # server-to-client requests should use `StreamableHTTPTransport`.
        def send_request(method, params = nil)
          request_id = generate_request_id
          request = { jsonrpc: "2.0", id: request_id, method: method }
          request[:params] = params if params

          begin
            send_response(request)
          rescue => e
            MCP.configuration.exception_reporter.call(e, { error: "Failed to send request" })
            raise
          end

          while @open && (line = read_line($stdin))
            begin
              parsed = JSON.parse(line.strip, symbolize_names: true)
            rescue JSON::ParserError => e
              MCP.configuration.exception_reporter.call(e, { error: "Failed to parse response" })
              raise
            end

            if parsed[:id] == request_id && !parsed.key?(:method)
              if parsed[:error]
                raise StandardError, "Client returned an error for #{method} request (code: #{parsed[:error][:code]}): #{parsed[:error][:message]}"
              end

              return parsed[:result]
            else
              response = @session ? @session.handle(parsed) : @server.handle(parsed)
              send_response(response) if response
            end
          end

          raise "Transport closed while waiting for response to #{method} request."
        end

        private

        # Reads one newline-delimited frame, bounded by `@max_line_bytes`. Returns
        # the line (including its trailing newline) or `nil` at EOF. Raises when the
        # limit is reached before a newline arrives, which signals a peer streaming
        # an unbounded frame. A short final frame without a trailing newline (EOF) is
        # still returned, since its length stays under the limit.
        def read_line(io)
          line = io.gets("\n", @max_line_bytes)
          if line && !line.end_with?("\n") && line.bytesize >= @max_line_bytes
            raise RequestHandlerError.new(
              "stdio frame exceeds #{@max_line_bytes} bytes without a newline",
              nil,
              error_type: :internal_error,
            )
          end

          line
        end
      end
    end
  end
end
