# frozen_string_literal: true

module MCP
  class Client
    module OAuth
      # Shared token/credential persistence for the OAuth provider classes
      # (`Provider` for the authorization-code flow, `ClientCredentialsProvider`
      # for the client_credentials flow, and `CrossAppAccessProvider` for the jwt-bearer flow).
      # The grants differ in how they authenticate, but all read and write the same two pieces of state
      # through a `storage` object: the token response and the client information. This module supplies
      # that delegation so the `Flow` orchestrator can treat any provider uniformly.
      #
      # Including classes must set `@storage` to an object responding to `tokens`,
      # `save_tokens(tokens)`, `client_information`, and `save_client_information(info)`
      # (see `InMemoryStorage`).
      module StorageBackedProvider
        # Optional `->(request) { true | false }` hook, called with an `AuthorizationRequest`.
        # An MCP server names its own authorization server and the scopes to ask for, so this is where
        # an embedding application sees both before the request is made and can decline to proceed.
        # `nil` (the default) authorizes whatever the server asked for, which is the behavior every
        # MCP SDK has today.
        attr_reader :authorization_request_validator

        # Optional Hash of String keys and values added to every token request the provider makes, for parameters
        # the authorization server requires beyond the grant itself (RFC 6749 Section 8.2 leaves room for them;
        # Auth0's `audience` is the usual one). `nil` (the default) adds nothing.
        # Set through `frozen_token_request_params`, which refuses a key `Flow` sets itself or a wrongly shaped value
        # with `Flow::InvalidTokenRequestParamsError`.
        attr_reader :token_request_params

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

        private

        # Constructors call this before writing to `storage`, so a rejected provider leaves it untouched.
        # The copy has its own frozen keys and values, so a later change to the caller's Hash, to a key,
        # or to a value cannot alter what is sent to the token endpoint. Keys are copied explicitly
        # because `Hash` copies and freezes only keys whose class is exactly `String`.
        def frozen_token_request_params(params)
          return if params.nil?

          problem = Flow.token_request_params_problem(params)
          raise Flow::InvalidTokenRequestParamsError, "token_request_params #{problem}" if problem

          params.each_with_object({}) { |(key, value), copy| copy[key.dup.freeze] = value.dup.freeze }.freeze
        end
      end
    end
  end
end
