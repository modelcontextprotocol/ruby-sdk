# frozen_string_literal: true

require "json"
require_relative "../../transport"

module MCP
  class Server
    module Transports
      class StdioTransport < Transport
        STATUS_INTERRUPTED = Signal.list["INT"] + 128

        def initialize(server)
          super(server)
          @open = false
          @session = nil
          $stdin.set_encoding("UTF-8")
          $stdout.set_encoding("UTF-8")
        end

        def open
          @open = true
          @session = ServerSession.new(server: @server, transport: self)
          while @open && (line = $stdin.gets)
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

          while @open && (line = $stdin.gets)
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
      end
    end
  end
end
