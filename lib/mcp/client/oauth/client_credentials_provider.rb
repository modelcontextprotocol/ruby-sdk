# frozen_string_literal: true

module MCP
  class Client
    module OAuth
      # OAuth client configuration for the OAuth 2.1 `client_credentials` grant
      # (machine-to-machine, no user and no browser redirect). Handed to
      # `MCP::Client::HTTP` via the `oauth:` keyword, the same as `Provider`.
      # The interactive Authorization Code flow lives in `Provider`;
      # this class exists so a credentials-only client never has to supply
      # the redirect arguments that grant has no use for, mirroring the dedicated
      # `ClientCredentialsProvider` in the TypeScript SDK and
      # `ClientCredentialsOAuthProvider` in the Python SDK.
      #
      # Required keyword arguments:
      #
      # - `client_id`     - String identifying the pre-registered confidential client.
      # - `client_secret` - String shared secret. The `client_credentials` grant
      #   is for confidential clients, so a credential is mandatory.
      #
      # Optional keyword arguments:
      #
      # - `token_endpoint_auth_method` - `"client_secret_basic"` (default) or
      #   `"client_secret_post"`. `"none"` is rejected: an unauthenticated
      #   `client_credentials` request is meaningless.
      # - `scope`   - String of space-separated scopes to request when the server's
      #   `WWW-Authenticate` and the Protected Resource Metadata do not specify one.
      # - `storage` - Object responding to `tokens`, `save_tokens(tokens)`,
      #   `client_information`, and `save_client_information(info)`. Defaults to
      #   an `InMemoryStorage`. The `client_id` / `client_secret` are written
      #   into it so the token exchange reads them through the same path as
      #   a pre-registered authorization-code client.
      class ClientCredentialsProvider
        include StorageBackedProvider

        # Raised when the credentials required for the `client_credentials` grant are
        # missing or the requested client authentication method cannot carry them.
        class InvalidCredentialsError < ArgumentError; end

        SUPPORTED_AUTH_METHODS = ["client_secret_basic", "client_secret_post"].freeze

        attr_reader :scope, :storage

        def initialize(
          client_id:,
          client_secret:,
          token_endpoint_auth_method: "client_secret_basic",
          scope: nil,
          storage: nil
        )
          if blank?(client_id)
            raise InvalidCredentialsError, "client_id is required for the client_credentials grant."
          end

          unless SUPPORTED_AUTH_METHODS.include?(token_endpoint_auth_method)
            raise InvalidCredentialsError,
              "token_endpoint_auth_method must be one of #{SUPPORTED_AUTH_METHODS.inspect} for the " \
                "client_credentials grant (got #{token_endpoint_auth_method.inspect}); an unauthenticated " \
                "client_credentials request is not allowed."
          end

          if blank?(client_secret)
            raise InvalidCredentialsError,
              "client_secret is required for the client_credentials grant with #{token_endpoint_auth_method}."
          end

          @scope = scope
          @storage = storage || InMemoryStorage.new
          @storage.save_client_information(
            "client_id" => client_id,
            "client_secret" => client_secret,
            "token_endpoint_auth_method" => token_endpoint_auth_method,
          )
        end

        # See `Provider#authorization_flow`.
        def authorization_flow
          :client_credentials
        end

        private

        def blank?(value)
          value.nil? || (value.is_a?(String) && value.strip.empty?)
        end
      end
    end
  end
end
