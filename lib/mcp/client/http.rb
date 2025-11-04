# frozen_string_literal: true

module MCP
  class Client
    class HTTP
      attr_reader :url, :session_id

      def initialize(url:, headers: {})
        @url = url
        @headers = headers
        @session_id = nil
      end

      # Sends a JSON-RPC request and returns the parsed response.
      # Supports both application/json and text/event-stream responses.
      #
      # @param request [Hash] The JSON-RPC request to send
      # @return [Hash] The parsed JSON-RPC response
      def send_request(request:)
        method = request[:method] || request["method"]
        params = request[:params] || request["params"]

        # Update session header if we have one
        update_session_header!

        response = client.post("", request)

        # Store session ID from response headers if present
        if response.headers["Mcp-Session-Id"]
          @session_id = response.headers["Mcp-Session-Id"]
        end

        # Handle different response types based on content-type
        content_type = response.headers["content-type"]

        parsed_body = if content_type&.include?("text/event-stream")
          # Parse SSE response
          parse_sse_response(response.body)
        else
          # Standard JSON response (Faraday already parsed it)
          response.body
        end

        parsed_body
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

      # Sends a JSON-RPC notification (no response expected).
      #
      # @param notification [Hash] The JSON-RPC notification to send
      # @return [nil]
      def send_notification(notification:)
        update_session_header!
        client.post("", notification)
        nil
      rescue Faraday::Error
        # Notifications don't expect a response, so we can silently fail
        # or log if needed
        nil
      end

      private

      attr_reader :headers

      def client
        require_faraday!
        @client ||= Faraday.new(url) do |faraday|
          faraday.request(:json)
          # Don't automatically parse JSON responses - we need to handle SSE too
          faraday.response(:raise_error)

          # Add Accept header to support both JSON and SSE
          faraday.headers["Accept"] = "application/json, text/event-stream"

          headers.each do |key, value|
            faraday.headers[key] = value
          end

          # Use a middleware that doesn't auto-parse to handle both content types
          faraday.response do |env|
            content_type = env.response_headers["content-type"]

            # Only auto-parse JSON, leave SSE as raw text
            if content_type&.include?("application/json")
              require "json"
              env[:body] = JSON.parse(env[:body]) if env[:body].is_a?(String) && !env[:body].empty?
            end
          end
        end
      end

      # Updates the session header on the Faraday client
      def update_session_header!
        return unless @client

        if @session_id
          @client.headers["Mcp-Session-Id"] = @session_id
        else
          @client.headers.delete("Mcp-Session-Id")
        end
      end

      def require_faraday!
        require "faraday"
      rescue LoadError
        raise LoadError, "The 'faraday' gem is required to use the MCP client HTTP transport. " \
          "Add it to your Gemfile: gem 'faraday', '>= 2.0'" \
          "See https://rubygems.org/gems/faraday for more details."
      end

      # Parses Server-Sent Events (SSE) response
      # Looks for the message event and parses its data as JSON
      def parse_sse_response(body)
        require "json"
        result = nil

        body.split("\n").each do |line|
          # SSE format: "event: message\ndata: {...}\n\n"
          if line.start_with?("data: ")
            data = line[6..-1] # Remove "data: " prefix
            result = JSON.parse(data)
          end
        end

        result || raise(RequestHandlerError.new(
          "No data found in SSE response",
          {},
          error_type: :internal_error,
        ))
      end
    end
  end
end
