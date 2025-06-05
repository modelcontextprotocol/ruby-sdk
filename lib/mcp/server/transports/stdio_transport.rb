# frozen_string_literal: true

require_relative "../../transport"
require "json"

module MCP
  class Server
    module Transports
      class StdioTransport < Transport
        class << self
          def register
            super("stdio", self)
          end
        end

        def initialize(server)
          @server = server
          @open = false
          $stdin.set_encoding("UTF-8")
          $stdout.set_encoding("UTF-8")
          super
        end

        def open
          @open = true
          while @open && (line = $stdin.gets)
            handle_json_request(line.strip)
          end
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
      end
    end
  end
end
