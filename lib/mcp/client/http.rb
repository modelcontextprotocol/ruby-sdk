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

        response.body
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

      private

      attr_reader :headers

      def client
        require_faraday!
        @client ||= Faraday.new(url) do |faraday|
          faraday.request(:json)
          faraday.response(:json)
          faraday.response(:raise_error)

          headers.each do |key, value|
            faraday.headers[key] = value
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
    end
  end
end
