# frozen_string_literal: true

require "test_helper"
require "base64"
require "digest"
require "json"
require "webmock/minitest"
require "faraday"
require "mcp/client/oauth"

module MCP
  class Client
    module OAuth
      # The authorization-code flow a web application drives: `run!` sends the user to the authorization server
      # in one request, and `finish!` redeems the code in the request that receives the redirect, possibly in another process.
      class PendingAuthorizationFlowTest < Minitest::Test
        REDIRECT_URI = "https://app.example.com/oauth/callback"

        # Serializes every value through JSON, the way a database- or cache-backed storage shared across processes would,
        # so nothing reaches `finish!` except what `run!` actually persisted.
        class JSONStorage
          attr_reader :pending_lookups

          def initialize
            @entries = {}
            @pending_lookups = 0
          end

          def tokens
            read("tokens")
          end

          def save_tokens(tokens)
            write("tokens", tokens)
          end

          def client_information
            read("client_information")
          end

          def save_client_information(info)
            write("client_information", info)
          end

          def save_pending_authorization(state, pending)
            write("pending:#{state}", pending)
          end

          def pending_authorization(state)
            @pending_lookups += 1
            read("pending:#{state}")
          end

          def delete_pending_authorization(state)
            value = @entries.delete("pending:#{state}")
            value && JSON.parse(value)
          end

          private

          def read(key)
            value = @entries[key]
            value && JSON.parse(value)
          end

          def write(key, value)
            if value.nil?
              @entries.delete(key)
            else
              @entries[key] = JSON.generate(value)
            end
          end
        end

        # Holds each `pending_authorization` read until `parties` callers have made one, so concurrent `finish!` calls
        # all pass their checks before any of them consumes the entry: the window a retried redirect can land in.
        class BarrierStorage < JSONStorage
          def initialize(parties)
            super()
            @parties = parties
            @arrived = 0
            @lock = Mutex.new
            @all_arrived = ConditionVariable.new
          end

          def pending_authorization(state)
            entry = super
            @lock.synchronize do
              @arrived += 1
              if @arrived >= @parties
                @all_arrived.broadcast
              else
                @all_arrived.wait(@lock, 5)
              end
            end
            entry
          end
        end

        # Deletes like Redis `DEL`, returning a count rather than the entry.
        class CountingDeleteStorage < JSONStorage
          def delete_pending_authorization(state)
            super ? 1 : 0
          end
        end

        def setup
          WebMock.enable!
          @server_url = "https://srv.example.com/mcp"
          @prm_url = "https://srv.example.com/.well-known/oauth-protected-resource/mcp"
          @auth_base = "https://auth.example.com"
          @as_metadata_url = "#{@auth_base}/.well-known/oauth-authorization-server"
          @redirected_to = nil

          stub_request(:get, @prm_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(resource: @server_url, authorization_servers: [@auth_base]),
          )

          stub_as_metadata

          stub_request(:post, "#{@auth_base}/register").to_return(
            status: 201,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(client_id: "test-client"),
          )

          stub_request(:post, "#{@auth_base}/token").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(access_token: "test-token-from-flow", token_type: "Bearer", expires_in: 3600),
          )
        end

        def teardown
          WebMock.reset!
        end

        def test_run_saves_a_pending_authorization_and_returns_redirect_without_a_callback_handler
          storage = JSONStorage.new
          provider = provider_without_callback_handler(storage: storage)
          flow = Flow.new(provider: provider)

          result = flow.run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_equal(:redirect, result)
          assert_equal(@redirected_to, flow.authorization_url)

          query = URI.decode_www_form(@redirected_to.query).to_h
          pending = storage.pending_authorization(query.fetch("state"))
          assert_equal(@server_url, pending["server_url"])
          assert_equal(@server_url, pending["resource"])
          assert_equal(REDIRECT_URI, pending["redirect_uri"])
          assert_equal("test-client", pending["client_id"])
          assert_equal(@auth_base, pending["authorization_server_metadata"]["issuer"])
          assert_kind_of(Integer, pending["created_at"])

          # The recorded verifier is the one the authorization request committed to.
          expected_challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(pending["code_verifier"]), padding: false)
          assert_equal(expected_challenge, query.fetch("code_challenge"))

          assert_nil(provider.access_token)
          assert_not_requested(:post, "#{@auth_base}/token")
        end

        def test_finish_redeems_the_code_with_a_fresh_provider_over_the_same_storage
          storage = JSONStorage.new
          state = begin_authorization(storage)
          verifier = storage.pending_authorization(state)["code_verifier"]
          WebMock::RequestRegistry.instance.reset!

          # A fresh provider and flow over the same storage stand in for the process that receives the redirect.
          provider = provider_without_callback_handler(storage: storage)
          result = Flow.new(provider: provider).finish!(
            server_url: @server_url,
            callback_params: { "code" => "auth-code", "state" => state },
          )

          assert_equal(:authorized, result)
          assert_equal("test-token-from-flow", provider.access_token)
          assert_equal(@auth_base, provider.tokens["issuer"])
          assert_nil(storage.pending_authorization(state))

          assert_requested(:post, "#{@auth_base}/token", times: 1) do |req|
            form = URI.decode_www_form(req.body).to_h
            form["grant_type"] == "authorization_code" &&
              form["code"] == "auth-code" &&
              form["code_verifier"] == verifier &&
              form["redirect_uri"] == REDIRECT_URI &&
              form["resource"] == @server_url &&
              form["client_id"] == "test-client"
          end

          # The recorded metadata binds the exchange, so discovery and registration do not run again.
          assert_not_requested(:get, @prm_url)
          assert_not_requested(:get, @as_metadata_url)
          assert_not_requested(:post, "#{@auth_base}/register")
        end

        def test_finish_accepts_symbol_keys
          storage = JSONStorage.new
          state = begin_authorization(storage)

          result = Flow.new(provider: provider_without_callback_handler(storage: storage)).finish!(
            server_url: @server_url,
            callback_params: { code: "auth-code", state: state },
          )

          assert_equal(:authorized, result)
        end

        def test_finish_lets_only_one_of_two_concurrent_callbacks_redeem_the_code
          storage = BarrierStorage.new(2)
          state = begin_authorization(storage)

          outcomes = Array.new(2) do
            Thread.new do
              Flow.new(provider: provider_without_callback_handler(storage: storage)).finish!(
                server_url: @server_url,
                callback_params: { "code" => "auth-code", "state" => state },
              )
            rescue Flow::AuthorizationError => e
              e
            end
          end.map(&:value)

          assert_equal(1, outcomes.count(:authorized))
          refused = outcomes.grep(Flow::AuthorizationError)
          assert_equal(1, refused.size)
          assert_equal(Flow::UNKNOWN_PENDING_AUTHORIZATION_MESSAGE, refused.first.message)
          assert_requested(:post, "#{@auth_base}/token", times: 1)
        end

        def test_finish_refuses_when_storage_does_not_return_the_consumed_entry
          storage = CountingDeleteStorage.new
          state = begin_authorization(storage)

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider_without_callback_handler(storage: storage)).finish!(
              server_url: @server_url,
              callback_params: { "code" => "auth-code", "state" => state },
            )
          end

          assert_equal(Flow::UNKNOWN_PENDING_AUTHORIZATION_MESSAGE, error.message)
          assert_not_requested(:post, "#{@auth_base}/token")
        end

        def test_finish_redeems_a_pending_authorization_only_once
          storage = JSONStorage.new
          state = begin_authorization(storage)
          flow = Flow.new(provider: provider_without_callback_handler(storage: storage))
          flow.finish!(server_url: @server_url, callback_params: { "code" => "auth-code", "state" => state })

          error = assert_raises(Flow::AuthorizationError) do
            flow.finish!(server_url: @server_url, callback_params: { "code" => "auth-code", "state" => state })
          end

          assert_match(/matches no pending authorization/, error.message)
          assert_requested(:post, "#{@auth_base}/token", times: 1)
        end

        def test_finish_refuses_an_unknown_state_before_any_request
          storage = JSONStorage.new

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider_without_callback_handler(storage: storage)).finish!(
              server_url: @server_url,
              callback_params: { "code" => "auth-code", "state" => "forged-state" },
            )
          end

          assert_equal(
            "Authorization callback `state` matches no pending authorization; it is unknown, already used, or expired.",
            error.message,
          )
          assert_not_requested(:any, /.*/)
        end

        def test_finish_refuses_a_callback_without_a_usable_state
          storage = JSONStorage.new
          begin_authorization(storage)
          flow = Flow.new(provider: provider_without_callback_handler(storage: storage))

          [{ "code" => "auth-code" }, { "code" => "auth-code", "state" => "" }, { "code" => "auth-code", "state" => ["a", "b"] }, nil].each do |params|
            error = assert_raises(Flow::AuthorizationError) do
              flow.finish!(server_url: @server_url, callback_params: params)
            end

            assert_equal("Authorization callback carried no `state`.", error.message)
          end

          assert_equal(0, storage.pending_lookups)
        end

        def test_finish_refuses_an_oversized_state_without_asking_storage
          storage = JSONStorage.new

          assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider_without_callback_handler(storage: storage)).finish!(
              server_url: @server_url,
              callback_params: { "code" => "auth-code", "state" => "a" * (Flow::CALLBACK_STATE_MAX_LENGTH + 1) },
            )
          end

          assert_equal(0, storage.pending_lookups)
        end

        def test_finish_refuses_an_expired_pending_authorization_and_discards_it
          storage = JSONStorage.new
          state = begin_authorization(storage, pending_authorization_max_age: 60)
          pending = storage.pending_authorization(state)
          storage.save_pending_authorization(state, pending.merge("created_at" => pending["created_at"] - 61))

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider_without_callback_handler(storage: storage, pending_authorization_max_age: 60)).finish!(
              server_url: @server_url,
              callback_params: { "code" => "auth-code", "state" => state },
            )
          end

          assert_equal("The pending authorization has expired; start a new authorization.", error.message)
          assert_nil(storage.pending_authorization(state))
          assert_not_requested(:post, "#{@auth_base}/token")
        end

        def test_finish_keeps_the_pending_authorization_when_iss_does_not_match
          storage = JSONStorage.new
          state = begin_authorization(storage)
          flow = Flow.new(provider: provider_without_callback_handler(storage: storage))

          error = assert_raises(Flow::AuthorizationError) do
            flow.finish!(
              server_url: @server_url,
              callback_params: { "code" => "forged-code", "state" => state, "iss" => "https://evil.example.com" },
            )
          end

          assert_match(/`iss` does not match/, error.message)
          assert_not_requested(:post, "#{@auth_base}/token")

          # The forged callback did not burn the verifier: the legitimate callback still completes.
          result = flow.finish!(
            server_url: @server_url,
            callback_params: { "code" => "auth-code", "state" => state, "iss" => @auth_base },
          )

          assert_equal(:authorized, result)
        end

        def test_finish_refuses_a_missing_iss_when_the_authorization_server_advertises_it
          stub_as_metadata(authorization_response_iss_parameter_supported: true)
          storage = JSONStorage.new
          state = begin_authorization(storage)

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider_without_callback_handler(storage: storage)).finish!(
              server_url: @server_url,
              callback_params: { "code" => "auth-code", "state" => state },
            )
          end

          assert_match(/carried no `iss`/, error.message)
          refute_nil(storage.pending_authorization(state))
          assert_not_requested(:post, "#{@auth_base}/token")
        end

        def test_finish_reports_an_authorization_error_response_after_the_iss_check
          storage = JSONStorage.new
          state = begin_authorization(storage)

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider_without_callback_handler(storage: storage)).finish!(
              server_url: @server_url,
              callback_params: {
                "error" => "access_denied",
                "error_description" => "The user declined",
                "state" => state,
                "iss" => @auth_base,
              },
            )
          end

          assert_equal(
            "The authorization server returned an error to the authorization callback. access_denied: The user declined",
            error.message,
          )
          assert_equal("access_denied", error.error)
          assert_equal("The user declined", error.error_description)
          assert_nil(storage.pending_authorization(state))
          assert_not_requested(:post, "#{@auth_base}/token")
        end

        def test_finish_does_not_surface_an_error_response_whose_iss_does_not_match
          storage = JSONStorage.new
          state = begin_authorization(storage)

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider_without_callback_handler(storage: storage)).finish!(
              server_url: @server_url,
              callback_params: {
                "error" => "access_denied",
                "error_description" => "Call support at 555-0100",
                "state" => state,
                "iss" => "https://evil.example.com",
              },
            )
          end

          assert_match(/`iss` does not match/, error.message)
          refute_includes(error.message, "555-0100")
          refute_nil(storage.pending_authorization(state))
        end

        def test_finish_refuses_a_different_mcp_server
          storage = JSONStorage.new
          state = begin_authorization(storage)

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider_without_callback_handler(storage: storage)).finish!(
              server_url: "https://other.example.com/mcp",
              callback_params: { "code" => "auth-code", "state" => state },
            )
          end

          assert_equal("The pending authorization was started for a different MCP server.", error.message)
          refute_nil(storage.pending_authorization(state))
          assert_not_requested(:post, "#{@auth_base}/token")
        end

        def test_finish_refuses_when_the_client_registration_changed
          storage = JSONStorage.new
          state = begin_authorization(storage)
          storage.save_client_information("client_id" => "another-client", "issuer" => @auth_base)

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider_without_callback_handler(storage: storage)).finish!(
              server_url: @server_url,
              callback_params: { "code" => "auth-code", "state" => state },
            )
          end

          assert_equal("The client registration changed after the authorization began; start a new authorization.", error.message)
          assert_not_requested(:post, "#{@auth_base}/token")
        end

        def test_finish_redeems_the_code_with_a_client_id_metadata_document_url
          stub_as_metadata(client_id_metadata_document_supported: true)
          cimd_url = "https://app.example.com/oauth/client-metadata.json"
          storage = JSONStorage.new
          state = begin_authorization(storage, client_id_metadata_document_url: cimd_url)

          provider = provider_without_callback_handler(storage: storage, client_id_metadata_document_url: cimd_url)
          result = Flow.new(provider: provider).finish!(
            server_url: @server_url,
            callback_params: { "code" => "auth-code", "state" => state },
          )

          assert_equal(:authorized, result)
          assert_not_requested(:post, "#{@auth_base}/register")
          assert_requested(:post, "#{@auth_base}/token") do |req|
            URI.decode_www_form(req.body).to_h["client_id"] == cimd_url
          end
        end

        def test_finish_checks_the_recorded_endpoints_again
          storage = JSONStorage.new
          state = begin_authorization(storage)
          pending = storage.pending_authorization(state)
          tampered = pending.merge(
            "authorization_server_metadata" => pending["authorization_server_metadata"].merge("token_endpoint" => "http://auth.example.com/token"),
          )
          storage.save_pending_authorization(state, tampered)

          assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider_without_callback_handler(storage: storage)).finish!(
              server_url: @server_url,
              callback_params: { "code" => "auth-code", "state" => state },
            )
          end

          assert_not_requested(:post, "http://auth.example.com/token")
        end

        def test_finish_refuses_a_malformed_pending_authorization
          storage = JSONStorage.new
          state = begin_authorization(storage)
          storage.save_pending_authorization(state, storage.pending_authorization(state).merge("code_verifier" => nil))

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider_without_callback_handler(storage: storage)).finish!(
              server_url: @server_url,
              callback_params: { "code" => "auth-code", "state" => state },
            )
          end

          assert_match(/matches no pending authorization/, error.message)
          assert_not_requested(:post, "#{@auth_base}/token")
        end

        def test_finish_refuses_a_callback_without_a_code
          storage = JSONStorage.new
          state = begin_authorization(storage)

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider_without_callback_handler(storage: storage)).finish!(
              server_url: @server_url,
              callback_params: { "state" => state },
            )
          end

          assert_equal("Authorization callback carried no authorization code.", error.message)
          assert_nil(storage.pending_authorization(state))
          assert_not_requested(:post, "#{@auth_base}/token")
        end

        def test_finish_refuses_a_provider_with_a_callback_handler
          provider = Provider.new(
            client_metadata: client_metadata,
            redirect_uri: REDIRECT_URI,
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          )

          assert_raises(ArgumentError) do
            Flow.new(provider: provider).finish!(server_url: @server_url, callback_params: { "code" => "c", "state" => "s" })
          end
        end

        private

        def client_metadata
          {
            client_name: "ruby-sdk-test",
            redirect_uris: [REDIRECT_URI],
            grant_types: ["authorization_code"],
            response_types: ["code"],
            token_endpoint_auth_method: "none",
          }
        end

        def provider_without_callback_handler(storage:, **options)
          Provider.new(
            client_metadata: client_metadata,
            redirect_uri: REDIRECT_URI,
            redirect_handler: ->(url) { @redirected_to = url },
            storage: storage,
            **options,
          )
        end

        # Runs `run!` and returns the `state` the authorization server would echo back on the redirect.
        def begin_authorization(storage, **options)
          result = Flow.new(provider: provider_without_callback_handler(storage: storage, **options)).run!(
            server_url: @server_url,
            resource_metadata_url: @prm_url,
          )
          assert_equal(:redirect, result)

          URI.decode_www_form(@redirected_to.query).to_h.fetch("state")
        end

        def stub_as_metadata(**extra)
          stub_request(:get, @as_metadata_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              response_types_supported: ["code"],
              grant_types_supported: ["authorization_code"],
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
              **extra,
            ),
          )
        end
      end
    end
  end
end
