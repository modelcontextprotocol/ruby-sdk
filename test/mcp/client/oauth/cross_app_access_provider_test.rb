# frozen_string_literal: true

require "test_helper"
require "mcp/client/oauth"

module MCP
  class Client
    module OAuth
      class CrossAppAccessProviderTest < Minitest::Test
        def build_provider(assertion_provider: ->(**) { "id-jag" })
          CrossAppAccessProvider.new(
            client_id: "xaa-client",
            client_secret: "xaa-secret",
            assertion_provider: assertion_provider,
          )
        end

        def test_initialize_stores_credentials_with_basic_auth_method
          provider = build_provider

          info = provider.client_information
          assert_equal("xaa-client", info["client_id"])
          assert_equal("xaa-secret", info["client_secret"])
          assert_equal("client_secret_basic", info["token_endpoint_auth_method"])
        end

        def test_authorization_flow_is_jwt_bearer
          assert_equal(:jwt_bearer, build_provider.authorization_flow)
        end

        def test_jwt_bearer_assertion_passes_audience_and_resource_through
          received = nil
          provider = build_provider(
            assertion_provider: ->(audience:, resource:) {
              received = { audience: audience, resource: resource }
              "id-jag-assertion"
            },
          )

          assertion = provider.jwt_bearer_assertion(
            audience: "https://auth.example.com",
            resource: "https://srv.example.com/mcp",
          )

          assert_equal("id-jag-assertion", assertion)
          assert_equal(
            { audience: "https://auth.example.com", resource: "https://srv.example.com/mcp" },
            received,
          )
        end

        def test_initialize_rejects_missing_client_id
          assert_raises(CrossAppAccessProvider::InvalidConfigurationError) do
            CrossAppAccessProvider.new(
              client_id: " ",
              client_secret: "xaa-secret",
              assertion_provider: ->(**) { "id-jag" },
            )
          end
        end

        def test_initialize_rejects_missing_client_secret
          # SEP-990 authenticates the jwt-bearer grant with client_secret_basic.
          assert_raises(CrossAppAccessProvider::InvalidConfigurationError) do
            CrossAppAccessProvider.new(
              client_id: "xaa-client",
              client_secret: nil,
              assertion_provider: ->(**) { "id-jag" },
            )
          end
        end

        def test_initialize_rejects_non_callable_assertion_provider
          assert_raises(CrossAppAccessProvider::InvalidConfigurationError) do
            CrossAppAccessProvider.new(
              client_id: "xaa-client",
              client_secret: "xaa-secret",
              assertion_provider: "not callable",
            )
          end
        end

        def test_token_helpers_delegate_to_storage
          provider = build_provider
          provider.save_tokens("access_token" => "xaa-token")

          assert_equal("xaa-token", provider.access_token)
          provider.clear_tokens!
          assert_nil(provider.tokens)
        end
      end
    end
  end
end
