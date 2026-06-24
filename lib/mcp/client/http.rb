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

      # Raised when an `oauth:` provider is paired with an MCP URL that is neither HTTPS nor
      # a loopback `http://` URL, since a bearer token sent over plain HTTP to a remote host
      # is trivially observed and stolen.
      class InsecureURLError < ArgumentError; end

      # Faraday request middleware that compares the outgoing request URL
      # against the URL snapshotted at `MCP::Client::HTTP#initialize` time.
      # Registered after the user's customizer so it sees `env.url` *after*
      # any custom middleware has had a chance to rewrite it - closing
      # the `Faraday env.url = URI("https://attacker...")` bypass that a plain
      # `client.url_prefix` check would miss. The comparison includes
      # the query string, so a middleware that rewrites `env.url.query` to
      # a different tenant (e.g. `?tenant=evil`) is rejected as well; otherwise
      # the audience-binding check on the OAuth side could be bypassed at
      # the send step.
      class OAuthURLGuard
        def initialize(app, expected_url:)
          @app = app
          @expected_url = expected_url
        end

        def call(env)
          effective = MCP::Client::OAuth::Discovery.canonicalize_url(env.url.to_s)
          unless effective == @expected_url
            # Surface the *canonicalized* form (no userinfo, no fragment) so
            # credentials like `user:pass@` cannot leak into logs, stack
            # traces, or exception reporters.
            raise InsecureURLError,
              "Effective request URL #{effective.inspect} does not match the URL " \
                "validated at initialize time (#{@expected_url.inspect}); refusing to send a bearer token."
          end
          @app.call(env)
        end
      end

      attr_reader :url, :session_id, :protocol_version, :server_info, :oauth

      def initialize(url:, headers: {}, oauth: nil, &block)
        if oauth && !MCP::Client::OAuth::Discovery.secure_url?(url)
          # Mask credentials (userinfo) and query parameters before quoting the URL in the error message
          # so they cannot leak into logs.
          safe_url = MCP::Client::OAuth::Discovery.canonicalize_origin_and_path(url)
          raise InsecureURLError,
            "MCP URL #{safe_url.inspect} must use https or be a loopback http URL when an oauth provider is set; " \
              "sending bearer tokens over plain http to a remote host would leak them on the wire."
        end

        @url = url
        @headers = headers
        @faraday_customizer = block
        @oauth = oauth
        # Snapshot the canonical URL at construction time. This single value
        # serves two related roles, both of which need to see the query string:
        #
        # - As the RFC 8707 `resource` claim sent on the authorization and
        #   token requests (and as the base for PRM discovery URLs) -
        #   matching the TS / Python SDKs' `resourceUrlFromServerUrl` /
        #   `resource_url_from_server_url` so multi-tenant servers that scope
        #   by `?tenant=...` round-trip correctly.
        # - As the comparison value for the URL guard middleware. Comparing
        #   query strings as well as origin + path is required so a Faraday
        #   middleware that rewrites `env.url.query` to a different tenant
        #   cannot send the bearer token to the wrong audience while
        #   the resource binding on the OAuth side stays correct.
        #
        # Saved only when `oauth:` is set so non-OAuth transports keep their
        # existing behavior.
        @oauth_server_url = oauth ? MCP::Client::OAuth::Discovery.canonicalize_url(url) : nil
        @session_id = nil
        @protocol_version = nil
        @server_info = nil
        @connected = false
      end

      # Performs the MCP `initialize` handshake: sends an `initialize` request
      # followed by the required `notifications/initialized` notification.
      # The server's `InitializeResult` (protocol version, capabilities, server
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
          clear_session
          error = response["error"]
          raise RequestHandlerError.new(
            "Server initialization failed: #{error["message"]}",
            { method: MCP::Methods::INITIALIZE },
            error_type: :internal_error,
          )
        end

        unless response.is_a?(Hash) && response["result"].is_a?(Hash)
          clear_session
          raise RequestHandlerError.new(
            "Server initialization failed: missing result in response",
            { method: MCP::Methods::INITIALIZE },
            error_type: :internal_error,
          )
        end

        @server_info = response["result"]
        negotiated_protocol_version = @server_info["protocolVersion"]
        unless MCP::Configuration::SUPPORTED_STABLE_PROTOCOL_VERSIONS.include?(negotiated_protocol_version)
          clear_session
          raise RequestHandlerError.new(
            "Server initialization failed: unsupported protocol version #{negotiated_protocol_version.inspect}",
            { method: MCP::Methods::INITIALIZE },
            error_type: :internal_error,
          )
        end

        begin
          send_request(request: {
            jsonrpc: JsonRpcHandler::Version::V2_0,
            method: MCP::Methods::NOTIFICATIONS_INITIALIZED,
          })
        rescue StandardError
          clear_session
          raise
        end

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
      # After a successful `initialize` handshake, the session ID and protocol version returned by
      # the server are captured and automatically included on subsequent requests.
      #
      # If a block is given, it is invoked just before Faraday's `post` is called.
      # Faraday's synchronous `post` does not expose a post-write / pre-response hook,
      # so this is the latest send-boundary signal the adapter exposes; the actual TCP write happens
      # inside `post`. `MCP::Client#dispatch_with_cancellation` uses this yield to release
      # the cancel-dispatch thread, which then issues a separate `notifications/cancelled` POST
      # that may overlap with the original request on the network. The spec covers this:
      # the sender has issued the request and still believes it in-progress, and receivers MAY ignore
      # a cancellation referring to an unknown request id when the cancel POST happens to arrive first.
      # https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation
      def send_request(request:)
        method = request[:method] || request["method"]
        params = request[:params] || request["params"]
        oauth_retried = false
        step_up_retried = false

        begin
          yield if block_given?
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
          # Run the OAuth flow at most once per `send_request` invocation.
          # The `oauth_retried` flag lives outside the `begin` so it survives `retry`,
          # ensuring a server returning 401 indefinitely raises rather than loops.
          if @oauth && !oauth_retried
            oauth_retried = true
            run_oauth_flow!(unauthorized_error: e)
            retry
          end

          raise RequestHandlerError.new(
            "You are unauthorized to make #{method} requests",
            { method: method, params: params },
            error_type: :unauthorized,
            original_error: e,
          )
        rescue Faraday::ForbiddenError => e
          # OAuth 2.0 step-up: a 403 carrying `error="insufficient_scope"` in
          # the Bearer challenge means the existing access token is valid
          # but lacks scopes the server now requires for this operation.
          # Re-run the full authorization flow with the escalated scope from
          # the challenge and retry once. A plain 403 without the challenge is
          # surfaced unchanged.
          if @oauth && !step_up_retried && insufficient_scope_challenge?(e)
            step_up_retried = true
            run_step_up_flow!(forbidden_error: e)

            retry
          end

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
        rescue Faraday::Error => e
          raise RequestHandlerError.new(
            "Internal error handling #{method} request",
            { method: method, params: params },
            error_type: :internal_error,
            original_error: e,
          )
        end
      end

      # Sends a JSON-RPC notification (no response expected). Used by `Client#cancel` to deliver
      # `notifications/cancelled` for an in-flight request. The server acknowledges with HTTP 202 Accepted
      # per the Streamable HTTP spec.
      def send_notification(notification:)
        method = notification[:method] || notification["method"]

        client.post("", notification, session_headers)
        nil
      rescue Faraday::Error => e
        raise RequestHandlerError.new(
          "Failed to send #{method} notification",
          { method: method },
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
        unless @session_id
          clear_session
          return
        end

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

          # Register the URL identity guard *after* the user's customizer
          # so it sits closest to the adapter in the request stack. That way
          # the guard sees `env.url` after any customizer-added middleware has had
          # a chance to rewrite it, closing the `env.url = URI("https://...")`
          # bypass that a `Faraday::Connection#url_prefix` check cannot detect.
          faraday.use(OAuthURLGuard, expected_url: @oauth_server_url) if @oauth_server_url
        end
      end

      # Per spec, the client MUST include `MCP-Session-Id` (when the server assigned one)
      # and `MCP-Protocol-Version` on all requests after `initialize`.
      #
      # https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#session-management
      # https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#protocol-version-header
      def session_headers
        request_headers = {}
        request_headers[SESSION_ID_HEADER] = @session_id if @session_id
        request_headers[PROTOCOL_VERSION_HEADER] = @protocol_version if @protocol_version
        if @oauth && (token = @oauth.access_token)
          request_headers["Authorization"] = "Bearer #{token}"
        end
        request_headers
      end

      # Drives the OAuth orchestrator on a 401 from the MCP endpoint.
      # The `WWW-Authenticate` header (when present) supplies the `resource_metadata`
      # URL and an optional `scope` challenge per RFC 9728 Section 5.1.
      #
      # If the provider already holds a refresh token, we try to exchange it
      # for a fresh access token first; only when that fails (e.g., the refresh token was revoked)
      # do we fall back to the full Authorization Code + PKCE + DCR flow.
      #
      # https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization#error-handling
      def run_oauth_flow!(unauthorized_error:)
        params = parse_www_authenticate_from_error(unauthorized_error)
        flow = MCP::Client::OAuth::Flow.new(provider: @oauth)
        return if attempt_refresh(flow: flow, resource_metadata_url: params["resource_metadata"])

        run_full_authorization_flow!(flow: flow, params: params)
      end

      # Drives a full Authorization Code + PKCE flow without first attempting
      # to refresh the access token. Used for the MCP scope-selection-strategy
      # step-up path: the provider already holds a valid access token,
      # but the server returned a 403 with
      # `WWW-Authenticate: ... error="insufficient_scope", scope="..."`
      # per RFC 6750 Section 3.1. Refreshing the existing token would re-issue
      # the same scope set the server already rejected, so the SDK must run
      # a fresh authorization request. The request asks for the union of
      # the currently granted scope and the newly demanded scope; otherwise
      # the caller would lose previously held scopes and trigger another step-up
      # on the next operation that needs them.
      # https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization#scope-selection-strategy
      def run_step_up_flow!(forbidden_error:)
        params = parse_www_authenticate_from_error(forbidden_error)
        flow = MCP::Client::OAuth::Flow.new(provider: @oauth)
        params = params.merge("scope" => escalated_step_up_scope(params["scope"]))

        run_full_authorization_flow!(flow: flow, params: params)
      end

      # Returns the space-separated union of the currently granted scope (read
      # from the stored token response per RFC 6749 Section 5.1) and the scope
      # demanded by the step-up challenge. Duplicates are collapsed; order
      # follows first appearance so existing scopes precede the newly added
      # ones. Returns `nil` when neither side carries a scope so
      # `build_authorization_url` omits the `scope` parameter entirely.
      def escalated_step_up_scope(challenge_scope)
        tokens = @oauth.tokens
        granted = tokens.is_a?(Hash) ? (tokens["scope"] || tokens[:scope]) : nil
        scopes = [granted, challenge_scope].compact.flat_map { |scope| scope.to_s.split }.uniq

        scopes.empty? ? nil : scopes.join(" ")
      end

      # True when the response on `forbidden_error` carries a Bearer challenge
      # with `error="insufficient_scope"` per RFC 6750 Section 3.1 and the MCP
      # scope-selection-strategy section. A 403 without that signal is not a
      # step-up challenge and must not trigger re-authorization.
      def insufficient_scope_challenge?(forbidden_error)
        parse_www_authenticate_from_error(forbidden_error)["error"] == "insufficient_scope"
      end

      def parse_www_authenticate_from_error(error)
        response = error.response || {}
        response_headers = response[:headers] || {}
        header = response_headers["www-authenticate"] || response_headers["WWW-Authenticate"]
        MCP::Client::OAuth::Discovery.parse_www_authenticate(header)
      end

      def run_full_authorization_flow!(flow:, params:)
        # Use the URL snapshotted at `initialize` time so a post-construction
        # mutation of `@url` cannot redirect PRM/AS discovery and the authorize
        # URL to an attacker-controlled host.
        flow.run!(
          server_url: @oauth_server_url,
          resource_metadata_url: params["resource_metadata"],
          scope: params["scope"],
        )
      end

      # Tries to swap a saved `refresh_token` for a fresh access token. Returns truthy
      # on success and falsy on either "no refresh token available" or "refresh attempt failed"
      # (in which case the caller should run the full interactive flow).
      def attempt_refresh(flow:, resource_metadata_url:)
        return false unless refresh_token_available?

        # Use the snapshotted URL for the same reason as `run_oauth_flow!` above:
        # post-construction `@url` mutation must not redirect token-refresh
        # discovery to an attacker-controlled host. Use the query-bearing form
        # so the refresh request's RFC 8707 `resource` claim matches
        # the original authorization request.
        flow.refresh!(server_url: @oauth_server_url, resource_metadata_url: resource_metadata_url)
        true
      rescue MCP::Client::OAuth::Flow::InvalidGrantError
        # The refresh token has been revoked or expired by the AS. Wipe it so
        # the full interactive flow runs fresh on the retry.
        @oauth.clear_tokens!
        false
      rescue MCP::Client::OAuth::Flow::AuthorizationError
        # Transient failure (network, 5xx, AS metadata, etc.). Leave the refresh
        # token in place; the next attempt may succeed and we avoid forcing
        # the user through an interactive reauth for a recoverable error.
        false
      end

      def refresh_token_available?
        tokens = @oauth.tokens
        return false unless tokens.is_a?(Hash)

        !(tokens["refresh_token"] || tokens[:refresh_token]).to_s.empty?
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
