# frozen_string_literal: true

module MCP
  class Client
    module OAuth
      # Shared token/credential persistence for the OAuth provider classes
      # (`Provider` for the authorization-code flow and `ClientCredentialsProvider`
      # for the client_credentials flow). The two grants differ in how they authenticate,
      # but both read and write the same two pieces of state through a `storage` object:
      # the token response and the client information. This module supplies that delegation
      # so the `Flow` orchestrator can treat any provider uniformly.
      #
      # Including classes must set `@storage` to an object responding to `tokens`,
      # `save_tokens(tokens)`, `client_information`, and `save_client_information(info)`
      # (see `InMemoryStorage`).
      module StorageBackedProvider
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
