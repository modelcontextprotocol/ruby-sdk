# frozen_string_literal: true

module MCP
  class Client
    module OAuth
      # OAuth client configuration for the MCP Enterprise Managed Authorization extension (SEP-990, "Cross-App Access"):
      # the client obtains an Identity Assertion Authorization Grant (ID-JAG) from an enterprise identity provider and
      # presents it to the MCP authorization server with the RFC 7523 `jwt-bearer` grant, authenticating with
      # `client_secret_basic`. Handed to `MCP::Client::HTTP` via the `oauth:` keyword, the same as `Provider`.
      #
      # Mirrors `CrossAppAccessProvider` in the TypeScript SDK: the assertion is supplied by a callable so it can come
      # from `IDJAGTokenExchange` (the common case), an enterprise secret store, or a test double.
      #
      # Required keyword arguments:
      #
      # - `client_id`     - String identifying the pre-registered confidential client at the MCP authorization server.
      # - `client_secret` - String shared secret for `client_secret_basic`.
      # - `assertion_provider` - Callable invoked as `call(audience:, resource:)`, returning the ID-JAG assertion to
      #   present. `audience` is the authorization server's issuer identifier and `resource` is the canonical MCP server URL;
      #   pass both through to `IDJAGTokenExchange.request` when exchanging an IdP ID token.
      #
      # Optional keyword arguments:
      #
      # - `scope`   - String of space-separated scopes to request when the server's `WWW-Authenticate` and
      #   the Protected Resource Metadata do not specify one.
      # - `storage` - Object responding to `tokens`, `save_tokens(tokens)`, `client_information`, and `save_client_information(info)`.
      #   Defaults to an `InMemoryStorage`.
      #
      # https://github.com/modelcontextprotocol/modelcontextprotocol/issues/990
      class CrossAppAccessProvider
        include StorageBackedProvider

        # Raised when the provider is constructed without the pieces the `jwt-bearer` grant needs.
        class InvalidConfigurationError < ArgumentError; end

        attr_reader :scope, :storage

        def initialize(client_id:, client_secret:, assertion_provider:, scope: nil, storage: nil)
          if blank?(client_id)
            raise InvalidConfigurationError, "client_id is required for the jwt-bearer grant."
          end

          if blank?(client_secret)
            raise InvalidConfigurationError, "client_secret is required: SEP-990 authenticates the jwt-bearer grant with client_secret_basic."
          end

          unless assertion_provider.respond_to?(:call)
            raise InvalidConfigurationError, "assertion_provider must be callable as `call(audience:, resource:)` and return the ID-JAG assertion."
          end

          @assertion_provider = assertion_provider
          @scope = scope
          @storage = storage || InMemoryStorage.new
          @storage.save_client_information(
            "client_id" => client_id,
            "client_secret" => client_secret,
            "token_endpoint_auth_method" => "client_secret_basic",
          )
        end

        # See `Provider#authorization_flow`.
        def authorization_flow
          :jwt_bearer
        end

        # Returns the ID-JAG assertion to present at the MCP authorization server. Called by `Flow#run_jwt_bearer!` with the audience
        # and resource resolved during discovery.
        def jwt_bearer_assertion(audience:, resource:)
          @assertion_provider.call(audience: audience, resource: resource)
        end

        private

        def blank?(value)
          value.nil? || (value.is_a?(String) && value.strip.empty?)
        end
      end
    end
  end
end
