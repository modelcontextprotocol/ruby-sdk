# frozen_string_literal: true

require "test_helper"
require "mcp/client/oauth"

module MCP
  class Client
    module OAuth
      class ClientCredentialsProviderTest < Minitest::Test
        # Every parameter the flow sets on a token request, spelled out rather than read from
        # `Flow::RESERVED_TOKEN_REQUEST_PARAMS`, so a key dropped from that constant fails here.
        RESERVED_TOKEN_REQUEST_PARAMS = [
          "grant_type",
          "client_id",
          "client_secret",
          "client_assertion",
          "client_assertion_type",
          "scope",
          "resource",
          "code",
          "code_verifier",
          "redirect_uri",
          "refresh_token",
          "assertion",
        ].freeze

        def test_initialize_stores_credentials_as_client_information
          provider = ClientCredentialsProvider.new(client_id: "cc-client", client_secret: "cc-secret")

          info = provider.client_information
          assert_equal("cc-client", info["client_id"])
          assert_equal("cc-secret", info["client_secret"])
          assert_equal("client_secret_basic", info["token_endpoint_auth_method"])
        end

        def test_authorization_flow_is_client_credentials
          provider = ClientCredentialsProvider.new(client_id: "cc-client", client_secret: "cc-secret")

          assert_equal(:client_credentials, provider.authorization_flow)
        end

        def test_initialize_accepts_client_secret_post
          provider = ClientCredentialsProvider.new(
            client_id: "cc-client",
            client_secret: "cc-secret",
            token_endpoint_auth_method: "client_secret_post",
          )

          assert_equal("client_secret_post", provider.client_information["token_endpoint_auth_method"])
        end

        def test_initialize_rejects_missing_client_id
          ["", "   ", nil].each do |value|
            assert_raises(ClientCredentialsProvider::InvalidCredentialsError, "should reject #{value.inspect}") do
              ClientCredentialsProvider.new(client_id: value, client_secret: "cc-secret")
            end
          end
        end

        def test_initialize_rejects_missing_client_secret
          # The client_credentials grant is for confidential clients, so a credential is mandatory.
          ["", "   ", nil].each do |value|
            assert_raises(ClientCredentialsProvider::InvalidCredentialsError, "should reject #{value.inspect}") do
              ClientCredentialsProvider.new(client_id: "cc-client", client_secret: value)
            end
          end
        end

        def test_initialize_rejects_none_auth_method
          # An unauthenticated client_credentials request is meaningless.
          assert_raises(ClientCredentialsProvider::InvalidCredentialsError) do
            ClientCredentialsProvider.new(
              client_id: "cc-client",
              client_secret: "cc-secret",
              token_endpoint_auth_method: "none",
            )
          end
        end

        def test_token_helpers_delegate_to_storage
          provider = ClientCredentialsProvider.new(client_id: "cc-client", client_secret: "cc-secret")
          provider.save_tokens("access_token" => "cc-token")

          assert_equal("cc-token", provider.access_token)
          provider.clear_tokens!
          assert_nil(provider.tokens)
        end

        # `OpenSSL::PKey::EC.generate` only exists from the openssl gem 2.2 (Ruby 3.0),
        # while `EC#generate_key` raises on openssl 3.0+ where PKey objects are immutable,
        # so branch on availability to keep CI green on every supported Ruby.
        def generate_es256_key
          if OpenSSL::PKey::EC.respond_to?(:generate)
            OpenSSL::PKey::EC.generate("prime256v1")
          else
            OpenSSL::PKey::EC.new("prime256v1").tap(&:generate_key)
          end
        end

        def private_key_jwt_provider(key: generate_es256_key)
          ClientCredentialsProvider.new(
            client_id: "cc-client",
            token_endpoint_auth_method: "private_key_jwt",
            private_key: key,
            signing_algorithm: "ES256",
          )
        end

        def test_initialize_accepts_private_key_jwt
          provider = private_key_jwt_provider

          info = provider.client_information
          assert_equal("cc-client", info["client_id"])
          assert_equal("private_key_jwt", info["token_endpoint_auth_method"])
        end

        def test_initialize_private_key_jwt_does_not_persist_the_key_or_a_secret
          # The PEM must never reach a (potentially persistent) storage backend.
          provider = private_key_jwt_provider

          info = provider.client_information
          refute(info.key?("client_secret"))
          refute(info.values.any? { |value| value.to_s.include?("PRIVATE KEY") })
        end

        def test_initialize_private_key_jwt_requires_private_key
          assert_raises(ClientCredentialsProvider::InvalidCredentialsError) do
            ClientCredentialsProvider.new(
              client_id: "cc-client",
              token_endpoint_auth_method: "private_key_jwt",
              signing_algorithm: "ES256",
            )
          end
        end

        def test_initialize_private_key_jwt_requires_signing_algorithm
          assert_raises(ClientCredentialsProvider::InvalidCredentialsError) do
            ClientCredentialsProvider.new(
              client_id: "cc-client",
              token_endpoint_auth_method: "private_key_jwt",
              private_key: generate_es256_key,
            )
          end
        end

        def test_initialize_private_key_jwt_rejects_client_secret
          assert_raises(ClientCredentialsProvider::InvalidCredentialsError) do
            ClientCredentialsProvider.new(
              client_id: "cc-client",
              client_secret: "cc-secret",
              token_endpoint_auth_method: "private_key_jwt",
              private_key: generate_es256_key,
              signing_algorithm: "ES256",
            )
          end
        end

        def test_initialize_private_key_jwt_fails_fast_on_key_algorithm_mismatch
          assert_raises(JWTClientAssertion::InvalidKeyError) do
            ClientCredentialsProvider.new(
              client_id: "cc-client",
              token_endpoint_auth_method: "private_key_jwt",
              private_key: OpenSSL::PKey::RSA.new(2048),
              signing_algorithm: "ES256",
            )
          end
        end

        def test_client_assertion_returns_signed_jwt_for_the_audience
          provider = private_key_jwt_provider

          assertion = provider.client_assertion(audience: "https://auth.example.com")
          payload_segment = assertion.split(".")[1]
          claims = JSON.parse(Base64.urlsafe_decode64(payload_segment + "=" * (-payload_segment.length % 4)))

          assert_equal("cc-client", claims["iss"])
          assert_equal("cc-client", claims["sub"])
          assert_equal("https://auth.example.com", claims["aud"])
        end

        def test_token_request_params_is_nil_by_default
          provider = ClientCredentialsProvider.new(client_id: "cc-client", client_secret: "cc-secret")

          assert_nil(provider.token_request_params)
        end

        def test_initialize_keeps_a_frozen_copy_of_token_request_params
          params = { "audience" => +"https://api.example.com" }
          provider = ClientCredentialsProvider.new(client_id: "cc-client", client_secret: "cc-secret", token_request_params: params)

          params["audience"] << "/changed"
          params["organization"] = "org_123"

          assert_equal({ "audience" => "https://api.example.com" }, provider.token_request_params)
          assert_predicate(provider.token_request_params, :frozen?)
          assert_predicate(provider.token_request_params["audience"], :frozen?)
        end

        def test_initialize_rejects_token_request_params_that_the_sdk_sets_itself
          RESERVED_TOKEN_REQUEST_PARAMS.each do |key|
            error = assert_raises(Flow::InvalidTokenRequestParamsError, "should reject #{key.inspect}") do
              ClientCredentialsProvider.new(client_id: "cc-client", client_secret: "cc-secret", token_request_params: { key => "x" })
            end

            assert_includes(error.message, key.inspect)
          end
        end

        def test_initialize_rejects_token_request_params_that_are_not_a_hash_of_strings
          ["audience=x", { audience: "x" }, { "audience" => 1 }, { "audience" => nil }].each do |params|
            assert_raises(Flow::InvalidTokenRequestParamsError, "should reject #{params.inspect}") do
              ClientCredentialsProvider.new(client_id: "cc-client", client_secret: "cc-secret", token_request_params: params)
            end
          end
        end

        def test_initialize_rejects_token_request_params_that_compare_keys_by_identity
          # Two equal keys are two entries in such a Hash and would silently collapse into one when copied.
          error = assert_raises(Flow::InvalidTokenRequestParamsError) do
            ClientCredentialsProvider.new(
              client_id: "cc-client",
              client_secret: "cc-secret",
              token_request_params: { "audience" => "x" }.compare_by_identity,
            )
          end

          assert_match(/identity/, error.message)
        end

        def test_initialize_copies_keys_that_hash_would_share_with_the_caller
          # `Hash` copies and freezes only keys whose class is exactly `String`; a subclass key would otherwise
          # stay shared with the caller, and a later `replace` would turn it into a reserved name.
          key = Class.new(String).new("audience")
          provider = ClientCredentialsProvider.new(client_id: "cc-client", client_secret: "cc-secret", token_request_params: { key => "x" })

          key.replace("grant_type")

          assert_equal({ "audience" => "x" }, provider.token_request_params)
          refute_same(key, provider.token_request_params.keys.first)
          assert_predicate(provider.token_request_params.keys.first, :frozen?)
        end

        def test_initialize_keeps_empty_token_request_params_as_a_frozen_empty_hash
          provider = ClientCredentialsProvider.new(client_id: "cc-client", client_secret: "cc-secret", token_request_params: {})

          assert_equal({}, provider.token_request_params)
          assert_predicate(provider.token_request_params, :frozen?)
        end

        def test_initialize_writes_no_client_information_when_token_request_params_are_rejected
          storage = InMemoryStorage.new

          assert_raises(Flow::InvalidTokenRequestParamsError) do
            ClientCredentialsProvider.new(
              client_id: "cc-client",
              client_secret: "cc-secret",
              storage: storage,
              token_request_params: { "grant_type" => "password" },
            )
          end

          assert_nil(storage.client_information)
        end
      end
    end
  end
end
