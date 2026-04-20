# frozen_string_literal: true

require "securerandom"
require_relative "../../json_rpc_handler"
require_relative "../configuration"
require_relative "../methods"
require_relative "../version"

module MCP
  class Client
    # TODO: HTTP GET for SSE streaming is not yet implemented.
    #   https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#listening-for-messages-from-the-server
    # TODO: Resumability and redelivery with Last-Event-ID is not yet implemented.
    #   https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#resumability-and-redelivery
    class HTTP
      ACCEPT_HEADER = "application/json, text/event-stream"
      SESSION_ID_HEADER = "Mcp-Session-Id"
      PROTOCOL_VERSION_HEADER = "MCP-Protocol-Version"

      attr_reader :url, :session_id, :protocol_version, :server_info

      def initialize(url:, headers: {}, &block)
        @url = url
        @headers = headers
        @faraday_customizer = block
        @session_id = nil
        @protocol_version = nil
        @server_info = nil
        @connected = false
      end

      # Performs the MCP `initialize` handshake: sends an `initialize` request
      # followed by the required `notifications/initialized` notification. The
      # server's `InitializeResult` (protocol version, capabilities, server
      # info, instructions) is cached on the transport and returned.
      #
      # Idempotent: a second call returns the cached `InitializeResult` without
      # contacting the server. After `close`, state is cleared and `connect`
      # will handshake again.
      #
      # @param client_info [Hash, nil] `{ name:, version: }` identifying the client.
      #   Defaults to `{ name: "mcp-ruby-client", version: MCP::VERSION }`.
      # @param protocol_version [String, nil] Protocol version to offer. Defaults
      #   to `MCP::Configuration::LATEST_STABLE_PROTOCOL_VERSION`.
      # @param capabilities [Hash] Capabilities advertised by the client. Defaults to `{}`.
      # @return [Hash] The server's `InitializeResult`.
      # @raise [RequestHandlerError] If the server responds with a JSON-RPC error
      #   or a malformed result.
      # https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle#initialization
      def connect(client_info: nil, protocol_version: nil, capabilities: {})
        return @server_info if connected?

        client_info ||= { name: "mcp-ruby-client", version: MCP::VERSION }
        protocol_version ||= MCP::Configuration::LATEST_STABLE_PROTOCOL_VERSION

        response = send_request(request: {
          jsonrpc: JsonRpcHandler::Version::V2_0,
          id: SecureRandom.uuid,
          method: MCP::Methods::INITIALIZE,
          params: {
            protocolVersion: protocol_version,
            capabilities: capabilities,
            clientInfo: client_info,
          },
        })

        if response.is_a?(Hash) && response.key?("error")
          error = response["error"]
          raise RequestHandlerError.new(
            "Server initialization failed: #{error["message"]}",
            { method: MCP::Methods::INITIALIZE },
            error_type: :internal_error,
          )
        end

        unless response.is_a?(Hash) && response["result"].is_a?(Hash)
          raise RequestHandlerError.new(
            "Server initialization failed: missing result in response",
            { method: MCP::Methods::INITIALIZE },
            error_type: :internal_error,
          )
        end

        @server_info = response["result"]

        send_request(request: {
          jsonrpc: JsonRpcHandler::Version::V2_0,
          method: MCP::Methods::NOTIFICATIONS_INITIALIZED,
        })

        @connected = true
        @server_info
      end

      # Returns true once `connect` has completed the full handshake
      # (`initialize` response received and `notifications/initialized` sent).
      # Returns false before the first handshake and after `close`.
      def connected?
        @connected
      end

      # Sends a JSON-RPC request and returns the parsed response body.
      # After a successful `initialize` handshake, the session ID and protocol
      # version returned by the server are captured and automatically included
      # on subsequent requests.
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
      rescue Faraday::ResourceNotFound => e
        # Per spec, 404 is the session-expired signal only when the request
        # actually carried an `Mcp-Session-Id`. A 404 without a session attached
        # (e.g. wrong URL or a stateless server) surfaces as a generic not-found.
        # https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#session-management
        if @session_id
          clear_session
          raise SessionExpiredError.new(
            "The #{method} request is not found",
            { method: method, params: params },
            original_error: e,
          )
        else
          raise RequestHandlerError.new(
            "The #{method} request is not found",
            { method: method, params: params },
            error_type: :not_found,
            original_error: e,
          )
        end
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

      # Terminates the session by sending an HTTP DELETE to the MCP endpoint
      # with the current `Mcp-Session-Id` header, and clears locally tracked
      # session state afterward. No-op when no session has been established.
      #
      # Per spec, the server MAY respond with HTTP 405 Method Not Allowed when
      # it does not support client-initiated termination, and returns 404 for
      # a session it has already terminated. Both mean the session is gone —
      # the desired end state. Other errors surface to the caller; local
      # session state is cleared either way.
      # https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#session-management
      def close
        return unless @session_id

        begin
          client.delete("", nil, session_headers)
        rescue Faraday::ClientError => e
          raise unless [404, 405].include?(e.response&.dig(:status))
        ensure
          clear_session
        end
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

      # Per spec, the client MUST include `MCP-Session-Id` (when the server assigned one)
      # and `MCP-Protocol-Version` on all requests after `initialize`.
      # https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#session-management
      # https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#protocol-version-header
      def session_headers
        request_headers = {}
        request_headers[SESSION_ID_HEADER] = @session_id if @session_id
        request_headers[PROTOCOL_VERSION_HEADER] = @protocol_version if @protocol_version
        request_headers
      end

      def capture_session_info(method, response, body)
        return unless method.to_s == Methods::INITIALIZE

        # Faraday normalizes header names to lowercase.
        session_id = response.headers[SESSION_ID_HEADER.downcase]
        @session_id ||= session_id unless session_id.to_s.empty?
        @protocol_version ||= body.is_a?(Hash) ? body.dig("result", "protocolVersion") : nil
      end

      def clear_session
        @session_id = nil
        @protocol_version = nil
        @server_info = nil
        @connected = false
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
