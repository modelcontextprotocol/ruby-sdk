# frozen_string_literal: true

module MCP
  class Client
    module OAuth
      # Pluggable OAuth client configuration handed to `MCP::Client::HTTP` via
      # the `oauth:` keyword. Inspired by the OAuthClientProvider in the TypeScript SDK
      # and httpx.Auth-based provider in the Python SDK.
      #
      # Required keyword arguments:
      # - `client_metadata`  - Hash sent to the authorization server's Dynamic Client
      #   Registration endpoint. Must include at minimum `redirect_uris`,
      #   `grant_types`, `response_types`, and `token_endpoint_auth_method`.
      # - `redirect_uri`     - String: the redirect URI used for the authorization
      #   request. Must be one of `redirect_uris` in `client_metadata`.
      # - `redirect_handler` - Callable invoked with the fully-built authorization
      #   URL (a `URI`). Implementations typically open the user's browser.
      # - `callback_handler` - Callable invoked after `redirect_handler`. Returns
      #   `[code, state]` where `code` is the authorization code and `state` is
      #   the `state` parameter received on the redirect URI.
      #
      # Optional keyword arguments:
      # - `scope`   - String of space-separated scopes to request when the server's
      #   `WWW-Authenticate` does not specify one.
      # - `storage` - Object responding to `tokens`, `save_tokens(tokens)`,
      #   `client_information`, and `save_client_information(info)`. Defaults to
      #   an `InMemoryStorage`.
      class Provider
        # Raised when `Provider#initialize` is called with a `redirect_uri` that
        # is neither HTTPS nor a loopback `http://` URL, per the MCP
        # authorization spec's Communication Security requirement.
        class InsecureRedirectURIError < ArgumentError; end

        # Raised when the `redirect_uri` argument is not listed in
        # `client_metadata[:redirect_uris]` / `["redirect_uris"]`. Registering
        # the URI with the authorization server but then sending a different
        # one with the authorization request would be rejected by the AS at
        # runtime; failing at construction surfaces the bug earlier.
        class UnregisteredRedirectURIError < ArgumentError; end

        attr_reader :client_metadata,
          :redirect_uri,
          :scope,
          :storage,
          :redirect_handler,
          :callback_handler

        def initialize(
          client_metadata:,
          redirect_uri:,
          redirect_handler:,
          callback_handler:,
          scope: nil,
          storage: nil
        )
          unless Discovery.secure_url?(redirect_uri)
            raise InsecureRedirectURIError,
              "redirect_uri #{redirect_uri.inspect} must use https or be a loopback http URL " \
                "(localhost, 127.0.0.0/8, or ::1) per the MCP authorization Communication Security requirement."
          end

          registered = Array(client_metadata[:redirect_uris] || client_metadata["redirect_uris"])
          unless registered.include?(redirect_uri)
            raise UnregisteredRedirectURIError,
              "redirect_uri #{redirect_uri.inspect} must be listed in client_metadata[:redirect_uris] " \
                "(got #{registered.inspect}); otherwise the authorization server will reject the authorization request."
          end

          @client_metadata = client_metadata
          @redirect_uri = redirect_uri
          @redirect_handler = redirect_handler
          @callback_handler = callback_handler
          @scope = scope
          @storage = storage || InMemoryStorage.new
        end

        def access_token
          tokens&.dig("access_token") || tokens&.dig(:access_token)
        end

        def tokens
          @storage.tokens
        end

        def save_tokens(tokens)
          @storage.save_tokens(tokens)
        end

        def client_information
          @storage.client_information
        end

        def save_client_information(info)
          @storage.save_client_information(info)
        end

        def clear_tokens!
          @storage.save_tokens(nil)
        end
      end
    end
  end
end
