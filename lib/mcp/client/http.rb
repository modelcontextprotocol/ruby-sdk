# frozen_string_literal: true

# require "json_rpc_handler"
# require_relative "shared/instrumentation"
# require_relative "shared/methods"

module ModelContextProtocol
  module Client
    class Http
      DEFAULT_VERSION = "0.1.0"

      attr_reader :url, :version

      def initialize(url:, version: DEFAULT_VERSION)
        @url = url
        @version = version
      end

      def tools
        response = client.post(
          "",
          method: "tools/list",
          jsonrpc: "2.0",
          id: request_id,
          mcp: { method: "tools/list", jsonrpc: "2.0", id: request_id },
        ).body

        ::ModelContextProtocol::Client::Tools.new(response)
      end

      def call_tool(tool:, input:)
        response = client.post(
          "",
          {
            jsonrpc: "2.0",
            id: request_id,
            method: "tools/call",
            params: { name: tool.name, arguments: input },
            mcp: { jsonrpc: "2.0", id: request_id, method: "tools/call", params: { name: tool.name, arguments: input } },
          },
        ).body

        response.dig("result", "content", 0, "text")
      end

      private

      def client
        @client ||= Faraday.new(url) do |faraday|
          faraday.request(:json)
          faraday.response(:json)
          # TODO: error middleware?
        end
      end

      def request_id
        SecureRandom.uuid_v7
      end
    end
  end
end
