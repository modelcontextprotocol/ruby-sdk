# frozen_string_literal: true

module MCP
  class Client
    module OAuth
      # Default reference implementation of the storage contract that
      # `Provider` uses to persist OAuth state. Holds the two pieces of data
      # the flow saves and reads on every request:
      #
      # - `tokens`: the hash returned by the token endpoint
      #   (`access_token`, optional `refresh_token`, `expires_in`, `scope`, etc.).
      # - `client_information`: the hash returned by Dynamic Client Registration
      #   or supplied as pre-registered credentials
      #   (`client_id`, optional `client_secret`, optional
      #   `token_endpoint_auth_method`). The SDK additionally stamps an `"issuer"` member
      #   binding the credentials to the authorization server that issued them (SEP-2352);
      #   custom storages should treat the hash as opaque and persist it as-is.
      #
      # A provider without a `callback_handler` also keeps each pending authorization here, keyed by its `state`,
      # between the request that sends the user to the authorization server and the request that receives
      # the redirect (`save_pending_authorization(state, pending)`, `pending_authorization(state)`,
      # `delete_pending_authorization(state)`). A pending authorization holds the PKCE verifier, so custom storages
      # should treat it as a secret, persist it as-is, and may expire entries older than the provider's
      # `pending_authorization_max_age`, which the flow refuses anyway. `delete_pending_authorization` must remove
      # the entry and return it in one atomic step (`Hash#delete` here; `GETDEL` in Redis, `DELETE ... RETURNING` in SQL),
      # returning `nil` when there was none: the flow redeems the code only when it gets the entry back.
      #
      # This class keeps everything in process memory, so the credentials live
      # only for the lifetime of the Ruby process. Applications that need
      # persistence across restarts should supply a custom object responding to
      # the same four-method contract (`tokens`, `save_tokens(t)`,
      # `client_information`, `save_client_information(info)`) and pass it via
      # `Provider.new(storage: ...)`. The shape mirrors Python SDK's
      # `TokenStorage` Protocol; TypeScript's `OAuthClientProvider` rolls
      # the same responsibilities into a single object.
      # A web application may receive the redirect in another process, so pending authorizations
      # need shared storage.
      class InMemoryStorage
        attr_accessor :tokens, :client_information

        def initialize
          @tokens = nil
          @client_information = nil
          @pending_authorizations = {}
        end

        def save_tokens(tokens)
          @tokens = tokens
        end

        def save_client_information(info)
          @client_information = info
        end

        def save_pending_authorization(state, pending)
          @pending_authorizations[state] = pending
        end

        def pending_authorization(state)
          @pending_authorizations[state]
        end

        def delete_pending_authorization(state)
          @pending_authorizations.delete(state)
        end
      end
    end
  end
end
