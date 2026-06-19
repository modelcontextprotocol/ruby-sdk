# frozen_string_literal: true

require "test_helper"
require "mcp/client/oauth"

module MCP
  class Client
    module OAuth
      class ClientCredentialsProviderTest < Minitest::Test
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
      end
    end
  end
end
