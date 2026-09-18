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

        def test_initialize_keeps_the_http_client_customizer
          customizer = ->(_faraday) {}
          provider = CrossAppAccessProvider.new(
            client_id: "xaa-client",
            client_secret: "xaa-secret",
            assertion_provider: ->(**) { "id-jag" },
            http_client_customizer: customizer,
          )

          assert_same(customizer, provider.http_client_customizer)
          assert_nil(build_provider.http_client_customizer)
        end

        def test_initialize_rejects_a_non_callable_http_client_customizer_before_writing_credentials
          storage = InMemoryStorage.new

          error = assert_raises(ArgumentError) do
            CrossAppAccessProvider.new(
              client_id: "xaa-client",
              client_secret: "xaa-secret",
              assertion_provider: ->(**) { "id-jag" },
              storage: storage,
              http_client_customizer: "recorder",
            )
          end

          assert_equal("http_client_customizer must respond to call (got String).", error.message)
          assert_nil(storage.client_information)
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

        def test_token_request_params_is_nil_by_default
          assert_nil(build_provider.token_request_params)
        end

        def test_initialize_keeps_a_frozen_copy_of_token_request_params
          params = { "audience" => +"https://api.example.com" }
          provider = CrossAppAccessProvider.new(
            client_id: "xaa-client",
            client_secret: "xaa-secret",
            assertion_provider: ->(**) { "id-jag" },
            token_request_params: params,
          )

          params["audience"] << "/changed"

          assert_equal({ "audience" => "https://api.example.com" }, provider.token_request_params)
          assert_predicate(provider.token_request_params, :frozen?)
        end

        def test_initialize_writes_no_client_information_when_token_request_params_are_rejected
          storage = InMemoryStorage.new

          error = assert_raises(Flow::InvalidTokenRequestParamsError) do
            CrossAppAccessProvider.new(
              client_id: "xaa-client",
              client_secret: "xaa-secret",
              assertion_provider: ->(**) { "id-jag" },
              storage: storage,
              token_request_params: { "assertion" => "x" },
            )
          end

          assert_includes(error.message, '"assertion"')
          assert_nil(storage.client_information)
        end
      end
    end
  end
end
