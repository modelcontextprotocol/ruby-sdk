# frozen_string_literal: true

module MCP
  class Client
    # TODO: https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#streamable-http (GET for SSE)
    # TODO: https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#resumability-and-redelivery

    class HTTP
      ACCEPT_HEADER = "application/json, text/event-stream"

      Response = Struct.new(:body, :headers, keyword_init: true)

      attr_reader :url

      def initialize(url:, headers: {})
        @url = url
        @headers = headers
      end

      # Sends a JSON-RPC request and returns only the response body.
      #
      # Use this method when:
      # - You only need the response body (not headers)
      # - You're using the transport directly without MCP::Client
      # - You don't need session management
      #
      # @param request [Hash] The JSON-RPC request to send
      # @return [Hash] The parsed response body
      def send_request(request:)
        post(body: request).body
      rescue SessionExpiredError => e
        # Preserve original error type for backward compatibility
        raise RequestHandlerError.new(
          "The #{request[:method] || request["method"]} request is not found",
          e.request,
          error_type: :not_found,
        )
      end

      # Sends a POST request and returns both body and headers.
      # Used internally by MCP::Client for session management.
      # @param body [Hash] The JSON-RPC request body
      # @param headers [Hash] Additional headers to include
      # @return [Response] A struct containing body and headers
      def post(body:, headers: {})
        method = body[:method] || body["method"]
        params = body[:params] || body["params"]

        response = client(headers).post("", body)
        parsed_body = parse_response_body(response, method, params)

        Response.new(body: parsed_body, headers: response.headers.to_h)
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
      rescue Faraday::ResourceNotFound
        # The server MAY terminate the session at any time,
        # after which it MUST respond to requests containing that session ID with HTTP 404 Not Found.
        # See: https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#session-management
        raise SessionExpiredError.new(
          "Session expired or not found (HTTP 404)",
          { method: method, params: params },
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

      def delete(headers: {})
        client(headers).delete("")
        nil
      rescue Faraday::Error
        nil
      end

      private

      attr_reader :headers

      def client(request_headers = {})
        require_faraday!
        Faraday.new(url) do |faraday|
          faraday.request(:json)
          faraday.response(:json)
          faraday.response(:raise_error)

          faraday.headers["Accept"] = ACCEPT_HEADER
          headers.each { |key, value| faraday.headers[key] = value }
          request_headers.each { |key, value| faraday.headers[key] = value }
        end
      end

      def require_faraday!
        require "faraday"
      rescue LoadError
        raise LoadError, "The 'faraday' gem is required to use the MCP client HTTP transport. " \
          "Add it to your Gemfile: gem 'faraday', '>= 2.0'" \
          "See https://rubygems.org/gems/faraday for more details."
      end

      def parse_response_body(response, method, params)
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
