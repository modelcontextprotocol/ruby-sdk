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
      # - `client_secret` - String shared secret for the `client_secret_basic` /
      #   `client_secret_post` methods. The `client_credentials` grant is for
      #   confidential clients, so a credential is mandatory; with
      #   `private_key_jwt` the credential is the `private_key` instead.
      #
      # Optional keyword arguments:
      #
      # - `token_endpoint_auth_method` - `"client_secret_basic"` (default),
      #   `"client_secret_post"`, or `"private_key_jwt"` (RFC 7523 JWT client
      #   assertion, per the `io.modelcontextprotocol/oauth-client-credentials`
      #   extension / SEP-1046). `"none"` is rejected: an unauthenticated
      #   `client_credentials` request is meaningless.
      # - `private_key` - PEM string (or `OpenSSL::PKey::PKey`) used to sign
      #   the JWT client assertion. Required with `private_key_jwt`.
      #   The key is held on the provider and never written to `storage`.
      # - `signing_algorithm` - `"ES256"` or `"RS256"`. Required with
      #   `private_key_jwt`; there is no default, so a mismatch with
      #   the server's `token_endpoint_auth_signing_alg_values_supported` fails
      #   loudly at construction instead of as a 401 (the TypeScript and Python SDKs
      #   also take the algorithm as an explicit option).
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

        SUPPORTED_AUTH_METHODS = ["client_secret_basic", "client_secret_post", "private_key_jwt"].freeze

        attr_reader :scope, :storage

        def initialize(
          client_id:,
          client_secret: nil,
          token_endpoint_auth_method: "client_secret_basic",
          private_key: nil,
          signing_algorithm: nil,
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

          client_information = { "client_id" => client_id, "token_endpoint_auth_method" => token_endpoint_auth_method }

          if token_endpoint_auth_method == "private_key_jwt"
            validate_private_key_jwt_arguments!(
              client_secret: client_secret,
              private_key: private_key,
              signing_algorithm: signing_algorithm,
            )

            # Fail fast on an unparseable key or a key/algorithm mismatch by
            # signing a throwaway assertion now rather than at token time.
            JWTClientAssertion.generate(
              client_id: client_id,
              audience: "urn:mcp:credential-validation",
              private_key: private_key,
              signing_algorithm: signing_algorithm,
            )
          else
            if blank?(client_secret)
              raise InvalidCredentialsError, "client_secret is required for the client_credentials grant with #{token_endpoint_auth_method}."
            end

            client_information["client_secret"] = client_secret
          end

          @client_id = client_id
          @private_key = private_key
          @signing_algorithm = signing_algorithm
          @scope = scope
          @storage = storage || InMemoryStorage.new
          @storage.save_client_information(client_information)
        end

        # See `Provider#authorization_flow`.
        def authorization_flow
          :client_credentials
        end

        # Returns a freshly signed RFC 7523 JWT client assertion for the `private_key_jwt` method.
        # `audience` is the authorization server's issuer identifier. Called by `Flow#post_to_token_endpoint`.
        def client_assertion(audience:)
          JWTClientAssertion.generate(
            client_id: @client_id,
            audience: audience,
            private_key: @private_key,
            signing_algorithm: @signing_algorithm,
          )
        end

        private

        def validate_private_key_jwt_arguments!(client_secret:, private_key:, signing_algorithm:)
          unless client_secret.nil?
            raise InvalidCredentialsError, "client_secret must not be set with private_key_jwt; the private key is the credential."
          end

          if private_key.nil?
            raise InvalidCredentialsError, "private_key is required for the client_credentials grant with private_key_jwt."
          end

          return unless blank?(signing_algorithm)

          raise InvalidCredentialsError, "signing_algorithm is required with private_key_jwt (one of #{JWTClientAssertion::SUPPORTED_ALGORITHMS.inspect})."
        end

        def blank?(value)
          value.nil? || (value.is_a?(String) && value.strip.empty?)
        end
      end
    end
  end
end
