# frozen_string_literal: true

require_relative "../transport"
require "json"

module ModelContextProtocol
  module Transports
    class StdioTransport < Transport
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
    end
  end
end
