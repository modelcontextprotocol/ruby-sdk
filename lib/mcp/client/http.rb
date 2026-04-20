# frozen_string_literal: true

module MCP
  class Client
    class HTTP
      ACCEPT_HEADER = "application/json, text/event-stream"

      attr_reader :url

      def initialize(url:, headers: {}, &block)
        @url = url
        @headers = headers
        @faraday_customizer = block
      end

      def send_request(request:)
        method = request[:method] || request["method"]
        params = request[:params] || request["params"]

        response = client.post("", request)
        parse_response_body(response, method, params)
      rescue Faraday::BadRequestError => e
        raise RequestHandlerError.new(
          "The #{method} request is invalid",
          { method: method, params: params },
          error_type: :bad_request,
          original_error: e,
        )
      rescue Faraday::UnauthorizedError => e
        raise RequestHandlerError.new(
          "You are unauthorized to make #{method} requests",
          { method: method, params: params },
          error_type: :unauthorized,
          original_error: e,
        )
      rescue Faraday::ForbiddenError => e
        raise RequestHandlerError.new(
          "You are forbidden to make #{method} requests",
          { method: method, params: params },
          error_type: :forbidden,
          original_error: e,
        )
      rescue Faraday::ResourceNotFound => e
        raise RequestHandlerError.new(
          "The #{method} request is not found",
          { method: method, params: params },
          error_type: :not_found,
          original_error: e,
        )
      rescue Faraday::UnprocessableEntityError => e
        raise RequestHandlerError.new(
          "The #{method} request is unprocessable",
          { method: method, params: params },
          error_type: :unprocessable_entity,
          original_error: e,
        )
      rescue Faraday::Error => e # Catch-all
        raise RequestHandlerError.new(
          "Internal error handling #{method} request",
          { method: method, params: params },
          error_type: :internal_error,
          original_error: e,
        )
      end

      private

      attr_reader :headers

      def client
        require_faraday!
        @client ||= Faraday.new(url) do |faraday|
          faraday.request(:json)
          faraday.response(:json)
          faraday.response(:raise_error)

          faraday.headers["Accept"] = ACCEPT_HEADER
          headers.each do |key, value|
            faraday.headers[key] = value
          end

          @faraday_customizer&.call(faraday)
        end
      end

      def require_faraday!
        require "faraday"
      rescue LoadError
        raise LoadError, "The 'faraday' gem is required to use the MCP client HTTP transport. " \
          "Add it to your Gemfile: gem 'faraday', '>= 2.0'" \
          "See https://rubygems.org/gems/faraday for more details."
      end

      def require_event_stream_parser!
        require "event_stream_parser"
      rescue LoadError
        raise LoadError, "The 'event_stream_parser' gem is required to parse SSE responses. " \
          "Add it to your Gemfile: gem 'event_stream_parser', '>= 1.0'. " \
          "See https://rubygems.org/gems/event_stream_parser for more details."
      end

      def parse_response_body(response, method, params)
        # 202 Accepted is the server's ACK for a JSON-RPC notification or response; no body is expected.
        # https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#sending-messages-to-the-server
        return if response.status == 202

        content_type = response.headers["Content-Type"]

        if content_type&.include?("text/event-stream")
          parse_sse_response(response.body, method, params)
        elsif content_type&.include?("application/json")
          response.body
        else
          raise RequestHandlerError.new(
            "Unsupported Content-Type: #{content_type.inspect}. Expected application/json or text/event-stream.",
            { method: method, params: params },
            error_type: :unsupported_media_type,
          )
        end
      end

      def parse_sse_response(body, method, params)
        require_event_stream_parser!

        json_rpc_response = nil
        parser = EventStreamParser::Parser.new
        parser.feed(body.to_s) do |_type, data, _id|
          next if data.empty?

          begin
            parsed = JSON.parse(data)
            json_rpc_response = parsed if parsed.is_a?(Hash) && (parsed.key?("result") || parsed.key?("error"))
          rescue JSON::ParserError
            next
          end
        end

        return json_rpc_response if json_rpc_response

        raise RequestHandlerError.new(
          "No valid JSON-RPC response found in SSE stream",
          { method: method, params: params },
          error_type: :parse_error,
        )
      end
    end
  end
end
