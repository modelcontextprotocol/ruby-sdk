# frozen_string_literal: true

module MCP
  class Client
    # TODO: HTTP GET for SSE streaming is not yet implemented.
    #   https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#listening-for-messages-from-the-server
    # TODO: Resumability and redelivery with Last-Event-ID is not yet implemented.
    #   https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#resumability-and-redelivery
    class HTTP
      ACCEPT_HEADER = "application/json, text/event-stream"
      SESSION_ID_HEADER = "Mcp-Session-Id"

      attr_reader :url, :session_id, :protocol_version

      def initialize(url:, headers: {}, &block)
        @url = url
        @headers = headers
        @faraday_customizer = block
        @session_id = nil
        @protocol_version = nil
      end

      # Sends a JSON-RPC request and returns the parsed response body.
      # Tracks the session ID and protocol version returned by `initialize`
      # and automatically includes them on subsequent requests.
      def send_request(request:)
        method = request[:method] || request["method"]
        params = request[:params] || request["params"]

        response = client.post("", request, session_headers)
        body = parse_response_body(response, method, params)

        capture_session_info(method, response, body)

        body
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
        # The server MAY terminate the session at any time, after which it MUST
        # respond with HTTP 404 to requests containing that session ID.
        # https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#session-management
        clear_session
        raise SessionExpiredError.new(
          "The #{method} request is not found",
          { method: method, params: params },
        )
      rescue Faraday::UnprocessableEntityError => e
        raise RequestHandlerError.new(
          "The #{method} request is unprocessable",
          { method: method, params: params },
          error_type: :unprocessable_entity,
          original_error: e,
        )
      rescue Faraday::Error => e
        raise RequestHandlerError.new(
          "Internal error handling #{method} request",
          { method: method, params: params },
          error_type: :internal_error,
          original_error: e,
        )
      end

      # Terminates the session via DELETE. Silently succeeds if the server
      # rejects the request; session state is cleared regardless.
      # https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#session-termination
      def close
        return unless @session_id

        begin
          client.delete("", nil, session_headers)
        rescue Faraday::Error
          # Server may respond 405 Method Not Allowed if it doesn't support DELETE;
          # that's fine, we still clear local state.
        end

        clear_session
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

      def session_headers
        h = {}
        h[SESSION_ID_HEADER] = @session_id if @session_id
        h
      end

      def capture_session_info(method, response, body)
        return unless method.to_s == "initialize"

        # Faraday normalizes header names to lowercase.
        @session_id ||= response.headers[SESSION_ID_HEADER.downcase]
        @protocol_version ||= body.is_a?(Hash) ? body.dig("result", "protocolVersion") : nil
      end

      def clear_session
        @session_id = nil
        @protocol_version = nil
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
          "Add it to your Gemfile: gem 'event_stream_parser', '>= 1.0'" \
          "See https://rubygems.org/gems/event_stream_parser for more details."
      end

      def parse_response_body(response, method, params)
        content_type = response.headers["Content-Type"]

        if content_type&.include?("text/event-stream")
          parse_sse_response(response.body, method, params)
        elsif content_type&.include?("application/json")
          response.body
        elsif response.status == 202
          # Server accepted the request and will deliver the response via an SSE stream.
          { "accepted" => true }
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
