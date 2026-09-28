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
      # should treat it as a secret and persist it as-is. `Flow#finish!` touches only the entry its callback's `state`
      # names, so an authorization the user never finished stays until the storage drops it: this class drops entries
      # older than `pending_authorization_max_age` the next time one is saved, and a custom storage should expire them,
      # with a TTL of that age. `delete_pending_authorization` must remove the entry and return it in one atomic step
      # (`Hash#delete` under a mutex here; `GETDEL` in Redis, `DELETE ... RETURNING` in SQL), returning `nil` when
      # there was none: the flow redeems the code only when it gets the entry back.
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

        # @param pending_authorization_max_age [Integer] seconds after which a pending authorization that was
        #   never finished is dropped from this storage, at its next save. `Provider.new` passes its own
        #   `pending_authorization_max_age` when it builds the default storage, so the two ages agree; a storage built
        #   by hand defaults to `Provider::DEFAULT_PENDING_AUTHORIZATION_MAX_AGE`.
        def initialize(pending_authorization_max_age: Provider::DEFAULT_PENDING_AUTHORIZATION_MAX_AGE)
          unless pending_authorization_max_age.is_a?(Integer) && pending_authorization_max_age.positive?
            raise ArgumentError, "pending_authorization_max_age must be a positive Integer number of seconds (got #{pending_authorization_max_age.inspect})."
          end

          @tokens = nil
          @client_information = nil
          @pending_authorizations = {}
          @pending_authorization_max_age = pending_authorization_max_age
          @pending_authorizations_mutex = Mutex.new
        end

        def save_tokens(tokens)
          @tokens = tokens
        end

        def save_client_information(info)
          @client_information = info
        end

        # Drops every pending authorization older than `pending_authorization_max_age` before saving the new one.
        # The flow refuses such an entry when it is looked up, but only a callback carrying its `state` looks it up,
        # and an authorization the user abandoned never gets one; every `401` a provider without a `callback_handler` meets
        # starts another, so without this the entries, each holding the verifier and the authorization server metadata,
        # would accumulate for the life of the process.
        def save_pending_authorization(state, pending)
          @pending_authorizations_mutex.synchronize do
            drop_expired_pending_authorizations
            @pending_authorizations[state] = pending
          end
        end

        def pending_authorization(state)
          @pending_authorizations_mutex.synchronize { @pending_authorizations[state] }
        end

        # The mutex is what makes the removal and the return one step on every Ruby implementation: `Hash#delete`
        # alone is atomic only where a global interpreter lock serializes it, and `Flow#finish!` relies on exactly
        # one of two callbacks racing on the same `state` getting the entry back.
        def delete_pending_authorization(state)
          @pending_authorizations_mutex.synchronize { @pending_authorizations.delete(state) }
        end

        # Every hash this storage holds may carry a secret (an access token, a client secret, a PKCE verifier),
        # and `inspect` is what error reporters and consoles print an object with, so it shows only whether each is present.
        def inspect
          pending_count = @pending_authorizations_mutex.synchronize { @pending_authorizations.size }

          "#<#{self.class.name} tokens=#{present_or_nil(@tokens)} client_information=#{present_or_nil(@client_information)} pending_authorizations=#{pending_count}>"
        end

        private

        # An entry's age is read from the Integer `created_at` the flow records when it saves the entry; an entry without one,
        # which the flow never writes, is left alone.
        def drop_expired_pending_authorizations
          now = Time.now.to_i

          @pending_authorizations.delete_if do |_state, pending|
            created_at = pending.is_a?(Hash) ? pending["created_at"] : nil

            created_at.is_a?(Integer) && now - created_at > @pending_authorization_max_age
          end
        end

        def present_or_nil(value)
          value.nil? ? "nil" : "[present]"
        end
      end
    end
  end
end
