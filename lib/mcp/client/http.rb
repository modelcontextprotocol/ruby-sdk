# frozen_string_literal: true

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
        response = make_request(method: "tools/list").body

        ::ModelContextProtocol::Client::Tools.new(response)
      end

      def call_tool(tool:, input:)
        response = make_request(
          method: "tools/call",
          params: { name: tool.name, arguments: input },
        ).body

        response.dig("result", "content", 0, "text")
      end

      private

      # TODO: support auth
      def client
        @client ||= Faraday.new(url) do |faraday|
          faraday.request(:json)
          faraday.response(:json)
          faraday.response(:raise_error)
        end
      end

      def make_request(method:, params: nil)
        client.post(
          "",
          {
            jsonrpc: "2.0",
            id: request_id,
            method:,
            params:,
            mcp: { jsonrpc: "2.0", id: request_id, method:, params: }.compact,
          }.compact,
        )
      rescue Faraday::BadRequestError => e
        raise RequestHandlerError.new(
          "The #{method} request is invalid",
          { method:, params: },
          error_type: :bad_request,
          original_error: e,
        )
      rescue Faraday::UnauthorizedError => e
        raise RequestHandlerError.new(
          "You are unauthorized to make #{method} requests",
          { method:, params: },
          error_type: :unauthorized,
          original_error: e,
        )
      rescue Faraday::ForbiddenError => e
        raise RequestHandlerError.new(
          "You are forbidden to make #{method} requests",
          { method:, params: },
          error_type: :forbidden,
          original_error: e,
        )
      rescue Faraday::ResourceNotFound => e
        raise RequestHandlerError.new(
          "The #{method} request is not found",
          { method:, params: },
          error_type: :not_found,
          original_error: e,
        )
      rescue Faraday::UnprocessableEntityError => e
        raise RequestHandlerError.new(
          "The #{method} request is unprocessable",
          { method:, params: },
          error_type: :unprocessable_entity,
          original_error: e,
        )
      rescue Faraday::Error => e # Catch-all
        raise RequestHandlerError.new(
          "Internal error handling #{method} request",
          { method:, params: },
          error_type: :internal_error,
          original_error: e,
        )
      end

      def request_id
        SecureRandom.uuid_v7
      end
    end
  end
end
