# frozen_string_literal: true

require "test_helper"
require "base64"
require "json"
require "webmock/minitest"
require "faraday"
require "mcp/client/oauth"

module MCP
  class Client
    module OAuth
      class FlowTest < Minitest::Test
        def setup
          WebMock.enable!
          @server_url = "https://srv.example.com/mcp"
          @prm_url = "https://srv.example.com/.well-known/oauth-protected-resource/mcp"
          @auth_base = "https://auth.example.com"
          @as_metadata_url = "#{@auth_base}/.well-known/oauth-authorization-server"

          stub_request(:get, @prm_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              resource: "https://srv.example.com/mcp",
              authorization_servers: [@auth_base],
            ),
          )

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
            ),
          )

          stub_request(:post, "#{@auth_base}/register").to_return(
            status: 201,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(client_id: "test-client", client_name: "ruby-sdk-test"),
          )

          stub_request(:post, "#{@auth_base}/token").to_return do |req|
            form = URI.decode_www_form(req.body).to_h
            {
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: JSON.generate(
                access_token: "test-token-from-flow",
                token_type: "Bearer",
                expires_in: 3600,
                grant_type_received: form["grant_type"],
                code_verifier_received: form["code_verifier"],
              ),
            }
          end
        end

        def teardown
          WebMock.reset!
        end

        def client_credentials_provider(token_endpoint_auth_method: "client_secret_basic")
          ClientCredentialsProvider.new(
            client_id: "cc-client",
            client_secret: "cc-secret",
            token_endpoint_auth_method: token_endpoint_auth_method,
          )
        end

        # Runs the full authorization flow and returns the `scope` query parameter
        # sent on the authorization request. The caller stubs the AS metadata;
        # this helper supplies a provider whose `grant_types` and optional pre-set
        # `scope` drive the SEP-2207 offline_access decision.
        def capture_authorization_scope(grant_types:, provider_scope: nil)
          captured_scope = nil
          state_holder = {}
          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: grant_types,
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) {
              query = URI.decode_www_form(url.query).to_h
              captured_scope = query["scope"]
              state_holder[:state] = query.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", state_holder[:state]] },
            scope: provider_scope,
          )

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          captured_scope
        end

        def test_run_uses_client_credentials_grant_for_client_credentials_provider
          provider = client_credentials_provider

          result = Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_equal(:authorized, result)
          assert_equal("test-token-from-flow", provider.access_token)
          # No authorization-code machinery: /authorize is never contacted
          # (no stub exists for it, so a request would raise), and DCR is not
          # run because credentials are pre-registered.
          assert_not_requested(:post, "#{@auth_base}/register")
          assert_requested(:post, "#{@auth_base}/token") do |req|
            form = URI.decode_www_form(req.body).to_h
            expected_basic = "Basic " + Base64.strict_encode64("cc-client:cc-secret")
            form["grant_type"] == "client_credentials" &&
              !form.key?("code") &&
              !form.key?("code_verifier") &&
              req.headers["Authorization"] == expected_basic
          end
        end

        def test_run_client_credentials_with_client_secret_post_sends_credentials_in_body
          # `client_secret_post` puts the credentials in the form body rather
          # than an HTTP Basic header (RFC 6749 Section 2.3.1).
          provider = client_credentials_provider(token_endpoint_auth_method: "client_secret_post")

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_requested(:post, "#{@auth_base}/token") do |req|
            form = URI.decode_www_form(req.body).to_h
            form["grant_type"] == "client_credentials" &&
              form["client_id"] == "cc-client" &&
              form["client_secret"] == "cc-secret" &&
              req.headers["Authorization"].nil?
          end
        end

        def test_run_client_credentials_raises_clean_error_when_client_information_missing
          # The constructor always stores credentials, but if a custom storage loses them
          # the grant must fail with a domain error rather than a `NoMethodError` from
          # the authorization-code registration helper.
          provider = client_credentials_provider
          provider.storage.save_client_information(nil)

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end
          assert_match(/client_credentials grant/, error.message)
          assert_not_requested(:post, "#{@auth_base}/token")
        end

        def test_run_client_credentials_succeeds_with_matching_stored_issuer
          provider = client_credentials_provider
          provider.storage.save_client_information(
            provider.storage.client_information.merge("issuer" => @auth_base),
          )

          result = Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_equal(:authorized, result)
        end

        def test_run_client_credentials_raises_for_mismatched_stored_issuer
          # Per SEP-2352, static machine-to-machine credentials bound to another authorization server must surface
          # an error instead of being replayed; re-registration is not an option for pre-registered credentials.
          provider = client_credentials_provider
          provider.storage.save_client_information(
            provider.storage.client_information.merge("issuer" => "https://old-as.example.com"),
          )

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          assert_match(/bound to a different authorization server/, error.message)
          assert_not_requested(:post, "#{@auth_base}/token")
        end

        def test_run_client_credentials_requests_scope_from_prm_scopes_supported
          stub_request(:get, @prm_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              resource: "https://srv.example.com/mcp",
              authorization_servers: [@auth_base],
              scopes_supported: ["mcp:read", "mcp:write"],
            ),
          )

          provider = client_credentials_provider

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_requested(:post, "#{@auth_base}/token") do |req|
            URI.decode_www_form(req.body).to_h["scope"] == "mcp:read mcp:write"
          end
        end

        def test_run_client_credentials_with_private_key_jwt_sends_signed_assertion
          # SEP-1046 / RFC 7523 Section 2.2: the token request authenticates
          # with a signed JWT assertion; `client_id` and any shared secret are
          # absent from the body, and the assertion's audience is the AS issuer.
          stub_request(:get, @as_metadata_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              token_endpoint: "#{@auth_base}/token",
              grant_types_supported: ["client_credentials"],
              token_endpoint_auth_methods_supported: ["private_key_jwt"],
              token_endpoint_auth_signing_alg_values_supported: ["ES256"],
            ),
          )

          # `OpenSSL::PKey::EC.generate` only exists from the openssl gem 2.2 (Ruby 3.0);
          # fall back to the pre-3.0 API on older Rubies.
          key = if OpenSSL::PKey::EC.respond_to?(:generate)
            OpenSSL::PKey::EC.generate("prime256v1")
          else
            OpenSSL::PKey::EC.new("prime256v1").tap(&:generate_key)
          end
          provider = ClientCredentialsProvider.new(
            client_id: "cc-client",
            token_endpoint_auth_method: "private_key_jwt",
            private_key: key,
            signing_algorithm: "ES256",
          )

          result = Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_equal(:authorized, result)
          assert_equal("test-token-from-flow", provider.access_token)
          assert_requested(:post, "#{@auth_base}/token") do |req|
            form = URI.decode_www_form(req.body).to_h
            payload_segment = form["client_assertion"].to_s.split(".")[1].to_s
            claims = JSON.parse(Base64.urlsafe_decode64(payload_segment + "=" * (-payload_segment.length % 4)))

            form["grant_type"] == "client_credentials" &&
              form["client_assertion_type"] == "urn:ietf:params:oauth:client-assertion-type:jwt-bearer" &&
              !form.key?("client_id") &&
              !form.key?("client_secret") &&
              req.headers["Authorization"].nil? &&
              claims["iss"] == "cc-client" &&
              claims["sub"] == "cc-client" &&
              claims["aud"] == @auth_base &&
              form["resource"] == "https://srv.example.com/mcp"
          end
        end

        def test_run_uses_authorization_code_grant_for_default_provider
          # A standard `Provider` declares `authorization_flow == :authorization_code`,
          # so `Flow` runs the interactive grant regardless of what `client_metadata[:grant_types]` happens to list.
          state_holder = {}
          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code", "client_credentials"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) {
              state_holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", state_holder[:state]] },
          )

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_requested(:post, "#{@auth_base}/token") do |req|
            URI.decode_www_form(req.body).to_h["grant_type"] == "authorization_code"
          end
        end

        # Runs the full authorization flow with a minimal provider so tests can assert on
        # the Dynamic Client Registration request body. The default loopback redirect URI
        # exercises SEP-837's `"native"` inference; passing an HTTPS `redirect_uri` exercises
        # the `"web"` inference.
        def run_authorization_flow(redirect_uri: "http://localhost:0/callback", client_metadata_extra: {})
          state_holder = {}
          provider = Provider.new(
            client_metadata: {
              redirect_uris: [redirect_uri],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            }.merge(client_metadata_extra),
            redirect_uri: redirect_uri,
            redirect_handler: ->(url) { state_holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state") },
            callback_handler: -> { ["test-auth-code", state_holder[:state]] },
          )

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
        end

        def test_run_registers_native_application_type_for_loopback_redirect_uri
          run_authorization_flow

          assert_requested(:post, "#{@auth_base}/register") do |req|
            JSON.parse(req.body)["application_type"] == "native"
          end
        end

        def test_run_registers_web_application_type_for_https_redirect_uri
          run_authorization_flow(redirect_uri: "https://app.example.com/callback")

          assert_requested(:post, "#{@auth_base}/register") do |req|
            JSON.parse(req.body)["application_type"] == "web"
          end
        end

        def test_run_does_not_override_explicit_application_type
          run_authorization_flow(client_metadata_extra: { application_type: "web" })

          assert_requested(:post, "#{@auth_base}/register") do |req|
            JSON.parse(req.body)["application_type"] == "web"
          end
        end

        def test_run_does_not_override_explicit_string_keyed_application_type
          run_authorization_flow(
            redirect_uri: "https://app.example.com/callback",
            client_metadata_extra: { "application_type" => "native" },
          )

          assert_requested(:post, "#{@auth_base}/register") do |req|
            JSON.parse(req.body)["application_type"] == "native"
          end
        end

        def test_run_completes_full_authorization_flow
          captured_authorization_url = nil
          state_value = nil

          provider = Provider.new(
            client_metadata: {
              client_name: "ruby-sdk-test",
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) {
              captured_authorization_url = url
              state_value = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", state_value] },
          )

          flow = Flow.new(provider: provider)
          result = flow.run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_equal(:authorized, result)
          assert_equal("test-token-from-flow", provider.access_token)

          query = URI.decode_www_form(captured_authorization_url.query).to_h
          assert_equal("code", query["response_type"])
          assert_equal("test-client", query["client_id"])
          assert_equal("S256", query["code_challenge_method"])
          assert_equal("http://localhost:0/callback", query["redirect_uri"])
          assert_equal("https://srv.example.com/mcp", query["resource"])

          assert_requested(:get, @prm_url)
          assert_requested(:post, "#{@auth_base}/register")
          assert_requested(:post, "#{@auth_base}/token") do |req|
            form = URI.decode_www_form(req.body).to_h
            form["grant_type"] == "authorization_code" &&
              form["code"] == "test-auth-code" &&
              !form["code_verifier"].to_s.empty? &&
              form["resource"] == "https://srv.example.com/mcp"
          end
        end

        def test_run_requests_offline_access_when_advertised_and_refresh_token_grant_declared
          # SEP-2207: a client that declares the `refresh_token` grant type requests `offline_access`
          # when the AS advertises it, so it can obtain a refresh token.
          stub_request(:get, @as_metadata_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              response_types_supported: ["code"],
              grant_types_supported: ["authorization_code", "refresh_token"],
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
              scopes_supported: ["mcp:basic", "offline_access"],
            ),
          )

          captured = capture_authorization_scope(grant_types: ["authorization_code", "refresh_token"])

          assert_includes(captured.split, "offline_access")
        end

        def test_run_does_not_request_offline_access_when_refresh_token_grant_not_declared
          # The AS advertises offline_access, but the client did not opt into refresh tokens,
          # so the scope is not requested.
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
              scopes_supported: ["mcp:basic", "offline_access"],
            ),
          )

          captured = capture_authorization_scope(grant_types: ["authorization_code"])

          refute_includes(captured.to_s.split, "offline_access")
        end

        def test_run_does_not_request_offline_access_when_server_does_not_advertise_it
          # SEP-2207 forbids requesting offline_access when the AS does not list it,
          # even if the client declared the refresh_token grant type.
          stub_request(:get, @as_metadata_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              response_types_supported: ["code"],
              grant_types_supported: ["authorization_code", "refresh_token"],
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
              scopes_supported: ["mcp:basic", "mcp:read"],
            ),
          )

          captured = capture_authorization_scope(grant_types: ["authorization_code", "refresh_token"])

          refute_includes(captured.to_s.split, "offline_access")
        end

        def test_run_strips_offline_access_from_provider_scope_when_server_does_not_advertise_it
          # SDK policy: even when `offline_access` reaches the resolved scope from a provider-supplied scope
          # (or a challenge / PRM scope), do not propagate it to the AS when the AS does not advertise the scope.
          # SEP-2207 itself only says clients should not request unsupported scopes; this strip is the SDK's
          # defensive layer against misbehaving resource servers and misconfigured PRMs that surface `offline_access`
          # even though the AS has not opted in.
          stub_request(:get, @as_metadata_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              response_types_supported: ["code"],
              grant_types_supported: ["authorization_code", "refresh_token"],
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
              scopes_supported: ["mcp:basic"],
            ),
          )

          captured = capture_authorization_scope(
            grant_types: ["authorization_code", "refresh_token"],
            provider_scope: "mcp:basic offline_access",
          )

          refute_includes(captured.to_s.split, "offline_access")
          assert_includes(captured.to_s.split, "mcp:basic")
        end

        def test_run_strips_sole_offline_access_scope_when_server_does_not_advertise_it
          # When stripping leaves an empty scope, no `scope` parameter is sent.
          stub_request(:get, @as_metadata_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              response_types_supported: ["code"],
              grant_types_supported: ["authorization_code", "refresh_token"],
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
              scopes_supported: ["mcp:basic"],
            ),
          )

          captured = capture_authorization_scope(
            grant_types: ["authorization_code", "refresh_token"],
            provider_scope: "offline_access",
          )

          assert_nil(captured)
        end

        def test_run_does_not_duplicate_offline_access_already_in_scope
          stub_request(:get, @as_metadata_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              response_types_supported: ["code"],
              grant_types_supported: ["authorization_code", "refresh_token"],
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
              scopes_supported: ["mcp:basic", "offline_access"],
            ),
          )

          captured = capture_authorization_scope(
            grant_types: ["authorization_code", "refresh_token"],
            provider_scope: "mcp:basic offline_access",
          )

          assert_equal(1, captured.split.count("offline_access"))
        end

        def test_run_raises_on_state_mismatch
          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "wrong-state"] },
          )

          assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end
        end

        def test_run_raises_when_pkce_unsupported
          stub_request(:get, @as_metadata_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              response_types_supported: ["code"],
              code_challenge_methods_supported: ["plain"],
            ),
          )

          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          )

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          assert_match(/S256/, error.message)
        end

        def test_run_raises_when_authorization_endpoint_is_missing
          stub_request(:get, @as_metadata_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              # NB: no `authorization_endpoint`.
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              response_types_supported: ["code"],
              code_challenge_methods_supported: ["S256"],
            ),
          )

          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          )

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          assert_match(/authorization_endpoint/i, error.message)
        end

        def test_run_raises_when_authorization_endpoint_is_malformed_uri
          stub_request(:get, @as_metadata_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              authorization_endpoint: "ht!tp:bad uri",
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              response_types_supported: ["code"],
              code_challenge_methods_supported: ["S256"],
            ),
          )

          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          )

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          assert_match(/authorization_endpoint/i, error.message)
        end

        def test_run_raises_when_prm_resource_is_malformed_uri
          stub_request(:get, @prm_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              resource: "ht!tp:bad uri",
              authorization_servers: [@auth_base],
            ),
          )

          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          )

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          assert_match(/PRM `resource`|not a valid URI/i, error.message)
        end

        def test_run_falls_back_to_legacy_discovery_when_prm_is_not_a_json_object
          # Valid JSON but the wrong shape. Any PRM discovery failure selects the legacy 2025-03-26 path
          # (matching the TypeScript and Python SDKs); here the legacy path also dead-ends, surfacing
          # a domain error rather than a raw `TypeError` from indexing the array.
          stub_request(:get, @prm_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: "[]",
          )
          stub_request(:get, "https://srv.example.com/.well-known/oauth-protected-resource/mcp").to_return(status: 404)
          stub_request(:get, "https://srv.example.com/.well-known/oauth-protected-resource").to_return(status: 404)
          stub_request(:get, "https://srv.example.com/.well-known/oauth-authorization-server").to_return(status: 404)
          stub_request(:get, "https://srv.example.com/.well-known/openid-configuration").to_return(status: 404)
          stub_request(:post, "https://srv.example.com/register").to_return(status: 404)

          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          )

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          assert_match(/Dynamic client registration failed/i, error.message)
          assert_requested(:get, "https://srv.example.com/.well-known/oauth-authorization-server")
        end

        # Builds a provider for the legacy-discovery tests, capturing the authorization URL so tests can assert
        # which endpoint was used.
        def build_legacy_discovery_provider(holder)
          Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) {
              holder[:authorization_url] = url
              holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", holder[:state]] },
          )
        end

        def stub_prm_not_found
          stub_request(:get, "https://srv.example.com/.well-known/oauth-protected-resource/mcp").to_return(status: 404)
          stub_request(:get, "https://srv.example.com/.well-known/oauth-protected-resource").to_return(status: 404)
        end

        def test_run_falls_back_to_server_origin_metadata_without_prm
          # Legacy 2025-03-26 shape: no PRM, AS metadata served from the MCP server origin,
          # OAuth endpoints under a path prefix whose `issuer` differs from the discovery origin.
          # The legacy path must not apply the RFC 8414 issuer byte-match (the legacy spec predates it).
          stub_prm_not_found
          stub_request(:get, "https://srv.example.com/.well-known/oauth-authorization-server").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: "https://srv.example.com/oauth",
              authorization_endpoint: "https://srv.example.com/oauth/authorize",
              token_endpoint: "https://srv.example.com/oauth/token",
              registration_endpoint: "https://srv.example.com/oauth/register",
              response_types_supported: ["code"],
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
            ),
          )
          stub_request(:post, "https://srv.example.com/oauth/register").to_return(
            status: 201,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(client_id: "legacy-client"),
          )
          stub_request(:post, "https://srv.example.com/oauth/token").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(access_token: "legacy-token", token_type: "Bearer", expires_in: 3600),
          )

          holder = {}
          provider = build_legacy_discovery_provider(holder)

          result = Flow.new(provider: provider).run!(server_url: @server_url)

          assert_equal(:authorized, result)
          assert_equal("legacy-token", provider.access_token)
          assert_equal("/oauth/authorize", holder[:authorization_url].path)
          assert_requested(:post, "https://srv.example.com/oauth/register")
          assert_requested(:post, "https://srv.example.com/oauth/token")
        end

        def test_run_falls_back_to_default_endpoints_without_any_metadata
          # Legacy 2025-03-26 "Fallbacks for Servers without Metadata Discovery": with no PRM and no AS metadata,
          # the client MUST use /authorize, /token, and /register at the authorization base URL, still sending PKCE S256.
          stub_prm_not_found
          stub_request(:get, "https://srv.example.com/.well-known/oauth-authorization-server").to_return(status: 404)
          stub_request(:get, "https://srv.example.com/.well-known/openid-configuration").to_return(status: 404)
          stub_request(:post, "https://srv.example.com/register").to_return(
            status: 201,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(client_id: "legacy-client"),
          )
          stub_request(:post, "https://srv.example.com/token").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(access_token: "legacy-token", token_type: "Bearer", expires_in: 3600),
          )

          holder = {}
          provider = build_legacy_discovery_provider(holder)

          result = Flow.new(provider: provider).run!(server_url: @server_url)

          assert_equal(:authorized, result)
          assert_equal("/authorize", holder[:authorization_url].path)
          query = URI.decode_www_form(holder[:authorization_url].query).to_h
          assert_equal("S256", query["code_challenge_method"])
          refute_empty(query["code_challenge"].to_s)
          assert_requested(:post, "https://srv.example.com/register")
          assert_requested(:post, "https://srv.example.com/token") do |req|
            URI.decode_www_form(req.body).to_h["code_verifier"].to_s != ""
          end
        end

        def test_run_legacy_fallback_rejects_insecure_authorization_base
          # The Communication Security requirement still applies on the legacy path: a remote plain-http origin must not
          # become the authorization base URL.
          stub_request(:get, "http://internal.example.com/.well-known/oauth-protected-resource/mcp").to_return(status: 404)
          stub_request(:get, "http://internal.example.com/.well-known/oauth-protected-resource").to_return(status: 404)

          holder = {}
          provider = build_legacy_discovery_provider(holder)

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: "http://internal.example.com/mcp")
          end

          assert_match(/legacy authorization base URL/, error.message)
        end

        def test_run_keeps_strict_issuer_validation_when_prm_is_present
          # The legacy issuer-check relaxation must not leak into the modern path: with PRM present,
          # a mismatched issuer still aborts.
          stub_request(:get, @as_metadata_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: "https://evil.example.com",
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              code_challenge_methods_supported: ["S256"],
            ),
          )

          holder = {}
          provider = build_legacy_discovery_provider(holder)

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          assert_match(/`issuer` does not match/, error.message)
        end

        def test_run_raises_when_prm_authorization_servers_is_not_an_array
          # `authorization_servers` MUST be an Array per RFC 9728. A misbehaving
          # PRM that returns a String would otherwise reach `.first` and raise
          # raw `NoMethodError` out of the SDK.
          stub_request(:get, @prm_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              resource: "https://srv.example.com/mcp",
              authorization_servers: "https://auth.example.com",
            ),
          )

          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          )

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          assert_match(/authorization_servers/i, error.message)
        end

        def test_run_raises_when_token_response_is_not_a_json_object
          # The token endpoint MUST return a JSON object per RFC 6749 §5.1.
          # A non-object body would otherwise be persisted into the provider
          # and raise raw exceptions the next time `provider.access_token`
          # is read.
          stub_request(:post, "#{@auth_base}/token").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: "[]",
          )

          state_holder = {}
          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) {
              state_holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", state_holder[:state]] },
          )

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          assert_match(/Token endpoint response is not a JSON object/i, error.message)
        end

        def test_run_treats_whitespace_only_stored_client_id_as_unregistered
          # `"   "` (whitespace only) is just as meaningless as `""`.
          # The check on stored client_information must trigger DCR rather than
          # passing the blank value through to the token endpoint.
          stub_request(:post, "#{@auth_base}/register").to_return(
            status: 201,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(client_id: "registered-after-whitespace"),
          )

          state_holder = {}
          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) {
              state_holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", state_holder[:state]] },
          )
          provider.save_client_information("client_id" => "   ")

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_requested(:post, "#{@auth_base}/register")
          assert_equal("registered-after-whitespace", provider.client_information.fetch("client_id"))
        end

        def test_run_raises_when_as_metadata_is_not_a_json_object
          stub_request(:get, @as_metadata_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: "null",
          )

          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          )

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          assert_match(/not a JSON object/i, error.message)
        end

        def test_run_raises_when_dcr_response_has_blank_client_id
          # A blank `client_id` is just as invalid as a missing one: peer SDKs
          # (TS / Python) require a non-empty string, and treating `""` as
          # truthy would let a misbehaving AS register a "client" the SDK can
          # never authenticate as.
          stub_request(:post, "#{@auth_base}/register").to_return(
            status: 201,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(client_id: "", client_name: "blank-id"),
          )

          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          )

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          assert_match(/client_id/i, error.message)
        end

        def test_run_treats_blank_stored_client_id_as_unregistered
          # Pre-stored `client_information` with a blank `client_id` must
          # trigger DCR rather than skipping registration; otherwise
          # the token endpoint receives `client_id=""` which the AS will reject.
          stub_request(:post, "#{@auth_base}/register").to_return(
            status: 201,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(client_id: "registered-after-blank"),
          )

          state_holder = {}
          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) {
              state_holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", state_holder[:state]] },
          )
          provider.save_client_information("client_id" => "")

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_requested(:post, "#{@auth_base}/register")
          assert_equal("registered-after-blank", provider.client_information.fetch("client_id"))
        end

        def test_run_raises_when_dcr_response_lacks_client_id
          stub_request(:post, "#{@auth_base}/register").to_return(
            status: 201,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(client_name: "test-but-no-id"),
          )

          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          )

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          assert_match(/client_id/i, error.message)
        end

        # Builds a provider whose callback returns the given `iss` shape:
        # `:omitted` keeps the legacy 2-element `[code, state]` form, any other value (including nil) returns
        # the 3-element `[code, state, iss]` form that opts into SEP-2468 / RFC 9207 issuer validation.
        def build_iss_validation_provider(callback_iss: :omitted)
          state_holder = {}
          callback_handler = if callback_iss == :omitted
            -> { ["test-auth-code", state_holder[:state]] }
          else
            -> { ["test-auth-code", state_holder[:state], callback_iss] }
          end

          Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) {
              state_holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: callback_handler,
          )
        end

        # Re-stubs the AS metadata with `authorization_response_iss_parameter_supported: true`.
        def stub_as_metadata_with_iss_support
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
              authorization_response_iss_parameter_supported: true,
            ),
          )
        end

        def test_run_completes_when_authorization_response_iss_matches_issuer
          provider = build_iss_validation_provider(callback_iss: @auth_base)

          result = Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_equal(:authorized, result)
          assert_equal("test-token-from-flow", provider.access_token)
        end

        def test_run_aborts_before_code_exchange_when_authorization_response_iss_mismatches
          provider = build_iss_validation_provider(callback_iss: "https://evil.example.com")

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          # Per RFC 9207, the client MUST NOT send the authorization code to a token endpoint after an `iss` mismatch.
          assert_match(/`iss` does not match/, error.message)
          assert_not_requested(:post, "#{@auth_base}/token")
        end

        def test_run_aborts_when_iss_is_missing_but_as_advertises_iss_support
          stub_as_metadata_with_iss_support
          provider = build_iss_validation_provider(callback_iss: nil)

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          assert_match(/carried no `iss`/, error.message)
          assert_not_requested(:post, "#{@auth_base}/token")
        end

        def test_run_completes_with_legacy_two_element_callback_even_when_as_advertises_iss_support
          stub_as_metadata_with_iss_support
          provider = build_iss_validation_provider

          result = Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_equal(:authorized, result)
        end

        def test_run_completes_when_iss_is_missing_and_as_does_not_advertise_iss_support
          provider = build_iss_validation_provider(callback_iss: nil)

          result = Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_equal(:authorized, result)
        end

        def test_run_validates_present_iss_even_when_as_does_not_advertise_iss_support
          provider = build_iss_validation_provider(callback_iss: "https://evil.example.com")

          assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          assert_not_requested(:post, "#{@auth_base}/token")
        end

        def test_run_skips_dcr_when_client_information_already_stored
          stub_request(:post, "#{@auth_base}/register").to_raise(StandardError.new("DCR should not be called."))

          state_holder = {}
          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) {
              state_holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", state_holder[:state]] },
          )
          provider.save_client_information("client_id" => "preregistered-client")

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_equal("test-token-from-flow", provider.access_token)
          assert_not_requested(:post, "#{@auth_base}/register")
        end

        def test_run_accepts_symbol_keys_in_preregistered_client_information
          stub_request(:post, "#{@auth_base}/register").to_raise(StandardError.new("DCR should not be called."))

          state_holder = {}
          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) {
              state_holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", state_holder[:state]] },
          )
          provider.save_client_information(client_id: "preregistered-symbol")

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_equal("test-token-from-flow", provider.access_token)
          assert_not_requested(:post, "#{@auth_base}/register")
        end

        # Builds a provider that completes the non-interactive authorization
        # flow against the stubs from `setup`, for the SEP-2352 issuer-binding
        # tests.
        def build_issuer_binding_provider
          state_holder = {}
          Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) {
              state_holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", state_holder[:state]] },
          )
        end

        def test_run_skips_dcr_when_stored_issuer_matches
          stub_request(:post, "#{@auth_base}/register").to_raise(StandardError.new("DCR should not be called."))

          provider = build_issuer_binding_provider
          provider.save_client_information("client_id" => "preregistered-client", "issuer" => @auth_base)

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_equal("test-token-from-flow", provider.access_token)
          assert_not_requested(:post, "#{@auth_base}/register")
        end

        def test_run_reregisters_when_authorization_server_changes
          provider = build_issuer_binding_provider
          provider.save_client_information("client_id" => "old-client", "issuer" => "https://other-as.example.com")
          provider.save_tokens("access_token" => "old-as-token")

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_requested(:post, "#{@auth_base}/register")
          info = provider.client_information
          assert_equal("test-client", info["client_id"])
          assert_equal(@auth_base, info["issuer"])
        end

        def test_run_clears_stale_tokens_when_authorization_server_changes
          # Abort the flow right after the discard (DCR fails) to observe that tokens minted by
          # the old authorization server were wiped before any re-registration attempt.
          stub_request(:post, "#{@auth_base}/register").to_return(status: 500, body: "")

          provider = build_issuer_binding_provider
          provider.save_client_information("client_id" => "old-client", "issuer" => "https://other-as.example.com")
          provider.save_tokens("access_token" => "old-as-token", "refresh_token" => "old-as-rt")

          assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          assert_nil(provider.tokens)
          assert_nil(provider.client_information)
        end

        def test_run_binds_legacy_client_information_to_issuer_on_first_use
          # Credentials persisted before issuer binding existed (or supplied as pre-registered credentials)
          # are reused and stamped with the current issuer rather than discarded.
          stub_request(:post, "#{@auth_base}/register").to_raise(StandardError.new("DCR should not be called."))

          provider = build_issuer_binding_provider
          provider.save_client_information("client_id" => "preregistered-client")

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_not_requested(:post, "#{@auth_base}/register")
          assert_equal(@auth_base, provider.client_information["issuer"])
        end

        def test_run_binds_symbol_keyed_client_information_to_issuer_on_first_use
          stub_request(:post, "#{@auth_base}/register").to_raise(StandardError.new("DCR should not be called."))

          provider = build_issuer_binding_provider
          provider.save_client_information(client_id: "preregistered-symbol")

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_not_requested(:post, "#{@auth_base}/register")
          assert_equal("test-token-from-flow", provider.access_token)
          assert_equal(@auth_base, provider.client_information["issuer"])
        end

        def test_run_reuses_portable_cimd_client_id_across_authorization_servers
          # Per SEP-2352, a CIMD `client_id` (an HTTPS URL) is portable across authorization servers:
          # reuse it and re-bind the issuer instead of discarding the registration.
          stub_request(:post, "#{@auth_base}/register").to_raise(StandardError.new("DCR should not be called."))

          provider = build_issuer_binding_provider
          provider.save_client_information(
            "client_id" => "https://app.example.com/client-metadata.json",
            "issuer" => "https://other-as.example.com",
          )

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_not_requested(:post, "#{@auth_base}/register")
          info = provider.client_information
          assert_equal("https://app.example.com/client-metadata.json", info["client_id"])
          assert_equal(@auth_base, info["issuer"])
        end

        def test_run_persists_issuer_with_dcr_client_information
          provider = build_issuer_binding_provider

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_requested(:post, "#{@auth_base}/register")
          info = provider.client_information
          assert_equal("test-client", info["client_id"])
          assert_equal(@auth_base, info["issuer"])
        end

        def test_run_skips_dcr_when_as_supports_cimd_and_provider_has_cimd_url
          # When the AS advertises Client ID Metadata Document support and the provider was configured with a CIMD URL,
          # the SDK uses the URL as the OAuth `client_id` and does not call /register.
          stub_request(:get, @as_metadata_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              response_types_supported: ["code"],
              grant_types_supported: ["authorization_code"],
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
              client_id_metadata_document_supported: true,
            ),
          )
          stub_request(:post, "#{@auth_base}/register").to_raise(StandardError.new("DCR should not be called."))

          captured_authorization_url = nil
          state_holder = {}
          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) {
              captured_authorization_url = url
              state_holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", state_holder[:state]] },
            client_id_metadata_document_url: "https://app.example.com/client-metadata.json",
          )

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_not_requested(:post, "#{@auth_base}/register")
          query = URI.decode_www_form(captured_authorization_url.query).to_h
          assert_equal("https://app.example.com/client-metadata.json", query["client_id"])
          assert_requested(:post, "#{@auth_base}/token") do |req|
            URI.decode_www_form(req.body).to_h["client_id"] == "https://app.example.com/client-metadata.json"
          end
          # The CIMD URL is NOT persisted to storage: AS metadata is re-read on every flow,
          # so a later AS that no longer advertises CIMD will not be sent a stale CIMD `client_id`.
          assert_nil(provider.client_information)
        end

        def test_run_falls_back_to_dcr_when_provider_has_cimd_url_but_as_does_not_advertise_support
          # The provider may carry a CIMD URL across multiple servers; if a particular AS does not advertise CIMD support,
          # the SDK must still register via DCR rather than send an unsupported `client_id`.
          state_holder = {}
          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) {
              state_holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", state_holder[:state]] },
            client_id_metadata_document_url: "https://app.example.com/client-metadata.json",
          )

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_requested(:post, "#{@auth_base}/register")
          assert_equal("test-client", provider.client_information["client_id"])
        end

        def test_run_does_not_enter_cimd_branch_when_support_advertised_as_string_false
          # A misconfigured AS that ships `"client_id_metadata_document_supported": "false"`
          # is truthy in Ruby. The SDK must NOT route through CIMD on truthy non-boolean values;
          # only a JSON `boolean true` opts in.
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
              client_id_metadata_document_supported: "false",
            ),
          )

          state_holder = {}
          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) {
              state_holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", state_holder[:state]] },
            client_id_metadata_document_url: "https://app.example.com/client-metadata.json",
          )

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_requested(:post, "#{@auth_base}/register")
          assert_equal("test-client", provider.client_information["client_id"])
        end

        def test_run_does_not_enter_cimd_branch_when_support_advertised_as_string_true
          # Mirror of the previous test for the other truthy non-boolean value:
          # `"true"` is also a string, not the JSON boolean the spec requires.
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
              client_id_metadata_document_supported: "true",
            ),
          )

          state_holder = {}
          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) {
              state_holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", state_holder[:state]] },
            client_id_metadata_document_url: "https://app.example.com/client-metadata.json",
          )

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_requested(:post, "#{@auth_base}/register")
        end

        def test_run_does_not_persist_cimd_client_id_so_later_flow_recovers_when_as_drops_support
          # Regression for the storage side-effect: if the SDK persisted the CIMD URL on the first flow,
          # a second flow against an AS that no longer advertises CIMD support would still send the URL as
          # the `client_id` and skip DCR. Re-running with the same provider must honour the updated AS metadata.
          shared_storage = InMemoryStorage.new
          state_holder = {}
          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) {
              state_holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", state_holder[:state]] },
            storage: shared_storage,
            client_id_metadata_document_url: "https://app.example.com/client-metadata.json",
          )

          # First flow: AS supports CIMD, so DCR is skipped.
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
              client_id_metadata_document_supported: true,
            ),
          )
          stub_request(:post, "#{@auth_base}/register").to_return(
            status: 201,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(client_id: "test-client"),
          )

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          assert_nil(shared_storage.client_information, "CIMD client_id must not be persisted")

          # Second flow: AS no longer advertises CIMD. The SDK must register via DCR rather than reuse a stale CIMD URL.
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
            ),
          )

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_requested(:post, "#{@auth_base}/register")
          assert_equal("test-client", shared_storage.client_information["client_id"])
        end

        def test_run_skips_cimd_when_pre_registered_client_information_exists
          # Pre-registered `client_information` wins over CIMD: the user explicitly chose a DCR-style identity,
          # so neither DCR nor the CIMD URL should overwrite it.
          stub_request(:get, @as_metadata_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              response_types_supported: ["code"],
              grant_types_supported: ["authorization_code"],
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
              client_id_metadata_document_supported: true,
            ),
          )
          stub_request(:post, "#{@auth_base}/register").to_raise(StandardError.new("DCR should not be called."))

          captured_authorization_url = nil
          state_holder = {}
          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) {
              captured_authorization_url = url
              state_holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", state_holder[:state]] },
            client_id_metadata_document_url: "https://app.example.com/client-metadata.json",
          )
          provider.save_client_information("client_id" => "preregistered-client")

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          query = URI.decode_www_form(captured_authorization_url.query).to_h
          assert_equal("preregistered-client", query["client_id"])
        end

        def test_run_uses_basic_auth_when_token_endpoint_auth_method_is_client_secret_basic
          state_holder = {}
          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "client_secret_basic",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) {
              state_holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", state_holder[:state]] },
          )
          provider.save_client_information(
            "client_id" => "pre-registered-client",
            "client_secret" => "pre-registered-secret",
            "token_endpoint_auth_method" => "client_secret_basic",
          )

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          expected = "Basic " + Base64.strict_encode64("pre-registered-client:pre-registered-secret")
          assert_requested(:post, "#{@auth_base}/token") do |req|
            req.headers["Authorization"] == expected &&
              !URI.decode_www_form(req.body).to_h.key?("client_secret")
          end
        end

        def test_run_form_urlencodes_basic_auth_credentials_with_special_characters
          state_holder = {}
          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "client_secret_basic",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) {
              state_holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", state_holder[:state]] },
          )
          # Per RFC 6749 Section 2.3.1, credentials must be `application/x-www-form-urlencoded`
          # before being joined with ":" and base64-encoded. A `:` in the secret would
          # otherwise be ambiguous with the username/password separator.
          provider.save_client_information(
            "client_id" => "client:with colon",
            "client_secret" => "secret:with:colons and spaces",
            "token_endpoint_auth_method" => "client_secret_basic",
          )

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          encoded_id = URI.encode_www_form_component("client:with colon")
          encoded_secret = URI.encode_www_form_component("secret:with:colons and spaces")
          expected = "Basic " + Base64.strict_encode64("#{encoded_id}:#{encoded_secret}")
          assert_requested(:post, "#{@auth_base}/token") do |req|
            req.headers["Authorization"] == expected
          end
        end

        def test_run_rejects_non_https_resource_metadata_url
          # `WWW-Authenticate` may carry a `resource_metadata=` URL we have never
          # seen before; if it isn't HTTPS-or-loopback, an attacker could lure us
          # into fetching a doctored PRM document over plain HTTP.
          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          )

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(
              server_url: @server_url,
              resource_metadata_url: "http://attacker.example.com/.well-known/oauth-protected-resource",
            )
          end

          assert_match(/resource_metadata|HTTPS|Communication Security/i, error.message)
        end

        def test_run_rejects_when_as_metadata_issuer_does_not_match
          # RFC 8414 Section 3.3: the AS metadata's `issuer` value MUST equal
          # the discovery URL. A metadata document advertising a different issuer
          # than the one PRM pointed at is treated as a confused-deputy attempt.
          stub_request(:get, @as_metadata_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: "https://other-auth.example.com",
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
            ),
          )

          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          )

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          assert_match(/issuer/i, error.message)
        end

        def test_run_rejects_when_as_metadata_issuer_differs_by_trailing_slash
          # RFC 8414 Section 3.3 requires the issuer to be identical, not "equivalent
          # after normalization". `https://auth.example.com` and
          # `https://auth.example.com/` are different strings and MUST NOT match.
          stub_request(:get, @as_metadata_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: "#{@auth_base}/",
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
            ),
          )

          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          )

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          assert_match(/issuer/i, error.message)
        end

        def test_run_rejects_when_as_metadata_issuer_differs_by_case
          stub_request(:get, @as_metadata_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base.upcase,
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
            ),
          )

          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          )

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          assert_match(/issuer/i, error.message)
        end

        def test_run_rejects_when_as_metadata_lacks_issuer
          stub_request(:get, @as_metadata_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
            ),
          )

          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          )

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          assert_match(/issuer/i, error.message)
        end

        def test_run_rejects_non_https_authorization_server
          # Communication Security: an `http://` authorization server URL (other
          # than loopback) MUST be refused. Returning a non-HTTPS auth server
          # from a hijacked PRM would let the attacker steer the client at
          # an endpoint they control to harvest tokens.
          stub_request(:get, @prm_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              resource: "https://srv.example.com/mcp",
              authorization_servers: ["http://auth.example.com"],
            ),
          )

          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          )

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          assert_match(/HTTPS|Communication Security/i, error.message)
        end

        def test_run_rejects_non_https_token_endpoint
          # Even when PRM and AS metadata discovery happen over HTTPS, the AS
          # metadata document itself can advertise an `http://` token endpoint.
          # That endpoint is where the bearer token lands, so it MUST be rejected.
          stub_request(:get, @as_metadata_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "http://insecure.example.com/token",
              registration_endpoint: "#{@auth_base}/register",
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
            ),
          )

          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          )

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          assert_match(/HTTPS|Communication Security|token_endpoint/i, error.message)
        end

        def test_refresh_swaps_refresh_token_for_new_access_token
          # Refresh should NOT hit /register (no DCR) and SHOULD post
          # grant_type=refresh_token with the saved refresh_token.
          stub_request(:post, "#{@auth_base}/register").to_raise(StandardError.new("DCR should not be called."))

          stub_request(:post, "#{@auth_base}/token")
            .with(body: hash_including("grant_type" => "refresh_token", "refresh_token" => "saved-rt"))
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: JSON.generate(access_token: "fresh-at", token_type: "Bearer", expires_in: 3600),
            )

          provider = Provider.new(
            client_metadata: { redirect_uris: ["http://localhost:0/callback"] },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { [nil, nil] },
          )
          provider.save_client_information("client_id" => "test-client")
          provider.save_tokens("access_token" => "stale-at", "refresh_token" => "saved-rt")

          result = Flow.new(provider: provider).refresh!(
            server_url: @server_url,
            resource_metadata_url: @prm_url,
          )

          assert_equal(:refreshed, result)
          assert_equal("fresh-at", provider.access_token)
          # New response did not include a refresh_token, so the old one is preserved (RFC 6749 Section 6).
          assert_equal("saved-rt", provider.tokens["refresh_token"])
        end

        def test_refresh_succeeds_when_stored_issuer_matches
          stub_request(:post, "#{@auth_base}/token").with(
            body: hash_including("grant_type" => "refresh_token", "refresh_token" => "saved-rt"),
          ).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(access_token: "fresh-at", token_type: "Bearer", expires_in: 3600),
          )

          provider = Provider.new(
            client_metadata: { redirect_uris: ["http://localhost:0/callback"] },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { [nil, nil] },
          )
          provider.save_client_information("client_id" => "test-client", "issuer" => @auth_base)
          provider.save_tokens("access_token" => "stale-at", "refresh_token" => "saved-rt")

          result = Flow.new(provider: provider).refresh!(
            server_url: @server_url,
            resource_metadata_url: @prm_url,
          )

          assert_equal(:refreshed, result)
          assert_equal("fresh-at", provider.access_token)
        end

        def test_refresh_raises_when_stored_issuer_differs
          # Per SEP-2352, another authorization server's credentials must not be replayed at this token endpoint;
          # the caller falls back to the full flow, which discards the stale registration and re-registers.
          stub_request(:post, "#{@auth_base}/token").to_raise(StandardError.new("Token endpoint should not be called."))

          provider = Provider.new(
            client_metadata: { redirect_uris: ["http://localhost:0/callback"] },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { [nil, nil] },
          )
          provider.save_client_information("client_id" => "old-client", "issuer" => "https://other-as.example.com")
          provider.save_tokens("access_token" => "stale-at", "refresh_token" => "saved-rt")

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).refresh!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          assert_match(/different authorization server/, error.message)
          assert_not_requested(:post, "#{@auth_base}/token")
        end

        def test_refresh_uses_cimd_url_as_client_id_when_provider_has_cimd_and_as_supports_it
          # Regression: the CIMD branch in `ensure_client_registered` does not persist `client_information`,
          # so a refresh call that requires stored client info would always fail after a CIMD-only flow.
          # `refresh!` must reconstruct the CIMD `client_id` from live AS metadata + the provider URL on every call.
          stub_request(:get, @as_metadata_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              response_types_supported: ["code"],
              grant_types_supported: ["authorization_code", "refresh_token"],
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
              client_id_metadata_document_supported: true,
            ),
          )
          stub_request(:post, "#{@auth_base}/register").to_raise(StandardError.new("DCR should not be called."))
          stub_request(:post, "#{@auth_base}/token").with(
            body: hash_including(
              "grant_type" => "refresh_token",
              "refresh_token" => "saved-rt",
              "client_id" => "https://app.example.com/client-metadata.json",
            ),
          ).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(access_token: "fresh-at", token_type: "Bearer", expires_in: 3600),
          )

          provider = Provider.new(
            client_metadata: { redirect_uris: ["http://localhost:0/callback"] },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { [nil, nil] },
            client_id_metadata_document_url: "https://app.example.com/client-metadata.json",
          )
          provider.save_tokens("access_token" => "stale-at", "refresh_token" => "saved-rt")

          result = Flow.new(provider: provider).refresh!(
            server_url: @server_url,
            resource_metadata_url: @prm_url,
          )

          assert_equal(:refreshed, result)
          assert_equal("fresh-at", provider.access_token)
          assert_nil(provider.client_information, "refresh must not persist a CIMD client_information entry")
        end

        def test_refresh_raises_when_provider_has_cimd_url_but_as_no_longer_advertises_support
          # If the AS later drops CIMD support and the provider has neither a stored `client_information` nor
          # an alternative identity, refresh has no way to authenticate. Fail loudly rather than send a CIMD
          # `client_id` the AS no longer recognises.
          stub_request(:get, @as_metadata_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              response_types_supported: ["code"],
              grant_types_supported: ["authorization_code", "refresh_token"],
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
            ),
          )

          provider = Provider.new(
            client_metadata: { redirect_uris: ["http://localhost:0/callback"] },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { [nil, nil] },
            client_id_metadata_document_url: "https://app.example.com/client-metadata.json",
          )
          provider.save_tokens("access_token" => "stale-at", "refresh_token" => "saved-rt")

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).refresh!(server_url: @server_url, resource_metadata_url: @prm_url)
          end
          assert_match(/client_id_metadata_document_supported/, error.message)
          assert_not_requested(:post, "#{@auth_base}/token")
        end

        def test_refresh_prefers_stored_client_information_over_cimd_url
          # Even when both are available, an explicitly stored `client_information` wins.
          # CIMD MUST NOT silently override it.
          stub_request(:get, @as_metadata_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              response_types_supported: ["code"],
              grant_types_supported: ["authorization_code", "refresh_token"],
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
              client_id_metadata_document_supported: true,
            ),
          )
          stub_request(:post, "#{@auth_base}/token").with(
            body: hash_including(
              "grant_type" => "refresh_token",
              "client_id" => "preregistered-client",
            ),
          ).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(access_token: "fresh-at", token_type: "Bearer", expires_in: 3600),
          )

          provider = Provider.new(
            client_metadata: { redirect_uris: ["http://localhost:0/callback"] },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { [nil, nil] },
            client_id_metadata_document_url: "https://app.example.com/client-metadata.json",
          )
          provider.save_client_information("client_id" => "preregistered-client")
          provider.save_tokens("access_token" => "stale-at", "refresh_token" => "saved-rt")

          Flow.new(provider: provider).refresh!(server_url: @server_url, resource_metadata_url: @prm_url)

          assert_equal("fresh-at", provider.access_token)
        end

        def test_refresh_raises_when_cimd_support_advertised_as_string_true
          # Mirror of the `run!` strict-boolean tests on the refresh path: a truthy non-boolean value
          # such as the string `"true"` must NOT be treated as CIMD support. With no stored `client_information`
          # and no genuine CIMD support, refresh has no identity to authenticate with.
          stub_request(:get, @as_metadata_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              response_types_supported: ["code"],
              grant_types_supported: ["authorization_code", "refresh_token"],
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
              client_id_metadata_document_supported: "true",
            ),
          )

          provider = Provider.new(
            client_metadata: { redirect_uris: ["http://localhost:0/callback"] },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { [nil, nil] },
            client_id_metadata_document_url: "https://app.example.com/client-metadata.json",
          )
          provider.save_tokens("access_token" => "stale-at", "refresh_token" => "saved-rt")

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).refresh!(server_url: @server_url, resource_metadata_url: @prm_url)
          end
          assert_match(/client_id_metadata_document_supported/, error.message)
          assert_not_requested(:post, "#{@auth_base}/token")
        end

        def test_refresh_raises_when_no_refresh_token
          provider = Provider.new(
            client_metadata: { redirect_uris: ["http://localhost:0/callback"] },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { [nil, nil] },
          )
          provider.save_client_information("client_id" => "test-client")
          provider.save_tokens("access_token" => "only-at")

          assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).refresh!(server_url: @server_url, resource_metadata_url: @prm_url)
          end
        end

        def test_refresh_raises_when_token_endpoint_rejects_refresh
          stub_request(:post, "#{@auth_base}/token").to_return(status: 401, body: "")

          provider = Provider.new(
            client_metadata: { redirect_uris: ["http://localhost:0/callback"] },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { [nil, nil] },
          )
          provider.save_client_information("client_id" => "test-client")
          provider.save_tokens("access_token" => "stale-at", "refresh_token" => "revoked-rt")

          assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).refresh!(server_url: @server_url, resource_metadata_url: @prm_url)
          end
        end

        def test_refresh_raises_invalid_grant_error_when_token_endpoint_says_invalid_grant
          stub_request(:post, "#{@auth_base}/token").to_return(
            status: 400,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(error: "invalid_grant", error_description: "refresh token expired"),
          )

          provider = Provider.new(
            client_metadata: { redirect_uris: ["http://localhost:0/callback"] },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { [nil, nil] },
          )
          provider.save_client_information("client_id" => "test-client")
          provider.save_tokens("access_token" => "stale-at", "refresh_token" => "revoked-rt")

          assert_raises(Flow::InvalidGrantError) do
            Flow.new(provider: provider).refresh!(server_url: @server_url, resource_metadata_url: @prm_url)
          end
        end

        def test_refresh_raises_generic_authorization_error_on_5xx
          stub_request(:post, "#{@auth_base}/token").to_return(status: 503, body: "")

          provider = Provider.new(
            client_metadata: { redirect_uris: ["http://localhost:0/callback"] },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { [nil, nil] },
          )
          provider.save_client_information("client_id" => "test-client")
          provider.save_tokens("access_token" => "stale-at", "refresh_token" => "live-rt")

          err = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).refresh!(server_url: @server_url, resource_metadata_url: @prm_url)
          end
          refute_kind_of(
            Flow::InvalidGrantError,
            err,
            "5xx must not be classified as invalid_grant; transient failures must preserve the refresh token",
          )
        end

        def test_resolve_scope_prefers_prm_scopes_supported_over_provider_scope
          stub_request(:get, @prm_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              resource: "https://srv.example.com/mcp",
              authorization_servers: [@auth_base],
              scopes_supported: ["mcp:read", "mcp:write"],
            ),
          )

          captured = nil
          provider = Provider.new(
            client_metadata: { redirect_uris: ["http://localhost:0/callback"] },
            redirect_uri: "http://localhost:0/callback",
            scope: "provider-supplied-scope",
            redirect_handler: ->(url) { captured = url },
            callback_handler: -> {
              [
                "code-1",
                URI.decode_www_form(captured.query).to_h["state"],
              ]
            },
          )

          Flow.new(provider: provider).run!(
            server_url: @server_url,
            resource_metadata_url: @prm_url,
            scope: nil,
          )

          authorized_params = URI.decode_www_form(captured.query).to_h
          assert_equal(
            "mcp:read mcp:write",
            authorized_params["scope"],
            "PRM scopes_supported must win over provider.scope when challenge scope is absent",
          )
        end

        def test_resolve_scope_falls_back_to_provider_scope_when_prm_omits_scopes_supported
          captured = nil
          provider = Provider.new(
            client_metadata: { redirect_uris: ["http://localhost:0/callback"] },
            redirect_uri: "http://localhost:0/callback",
            scope: "provider-fallback",
            redirect_handler: ->(url) { captured = url },
            callback_handler: -> {
              [
                "code-1",
                URI.decode_www_form(captured.query).to_h["state"],
              ]
            },
          )

          Flow.new(provider: provider).run!(
            server_url: @server_url,
            resource_metadata_url: @prm_url,
            scope: nil,
          )

          authorized_params = URI.decode_www_form(captured.query).to_h
          assert_equal(
            "provider-fallback",
            authorized_params["scope"],
            "provider.scope is the last-resort fallback when neither challenge nor PRM supplies one",
          )
        end

        def test_token_endpoint_defaults_to_client_secret_basic_for_confidential_clients
          captured_authorization = nil
          captured_form = nil
          stub_request(:post, "#{@auth_base}/token").to_return do |req|
            captured_authorization = req.headers["Authorization"]
            captured_form = URI.decode_www_form(req.body).to_h
            {
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: JSON.generate(access_token: "tok", token_type: "Bearer"),
            }
          end

          provider = Provider.new(
            client_metadata: { redirect_uris: ["http://localhost:0/callback"] },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { [nil, nil] },
          )
          # Confidential pre-registered client without `token_endpoint_auth_method`.
          provider.save_client_information(
            "client_id" => "preregistered",
            "client_secret" => "s3cret",
          )
          provider.save_tokens("access_token" => "stale", "refresh_token" => "live-rt")

          Flow.new(provider: provider).refresh!(server_url: @server_url, resource_metadata_url: @prm_url)

          expected = Base64.strict_encode64("preregistered:s3cret")
          assert_equal(
            "Basic #{expected}",
            captured_authorization,
            "default to client_secret_basic per RFC 6749 §2.3.1 and TS/Python SDK convention",
          )
          refute(
            captured_form.key?("client_secret"),
            "client_secret must not be duplicated in the form when sent via Basic auth",
          )
        end

        def test_run_blocks_percent_encoded_dot_segment_bypass_in_server_url
          # Same audience-binding bypass as the literal `..` case, but using
          # the percent-encoded form `%2e%2e`. RFC 3986 Section 6.2.2.2 normalization must
          # decode `%2e`/`%2E` before resolving dot-segments.
          stub_request(:get, "https://srv.example.com/api/%2e%2e/evil/.well-known/oauth-protected-resource")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: JSON.generate(
                resource: "https://srv.example.com/api",
                authorization_servers: [@auth_base],
              ),
            )

          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          )

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(
              server_url: "https://srv.example.com/api/%2e%2e/evil",
              resource_metadata_url: "https://srv.example.com/api/%2e%2e/evil/.well-known/oauth-protected-resource",
            )
          end

          assert_match(/resource/i, error.message)
        end

        def test_run_blocks_dot_segment_bypass_in_server_url
          # An attacker-supplied server URL like "/api/../evil" must not be
          # treated as covered by a PRM whose resource is the more privileged
          # "/api". Canonicalization resolves the dot-segments so the bypass
          # is detected.
          stub_request(:get, "https://srv.example.com/api/../evil/.well-known/oauth-protected-resource")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: JSON.generate(
                resource: "https://srv.example.com/api",
                authorization_servers: [@auth_base],
              ),
            )

          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          )

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(
              server_url: "https://srv.example.com/api/../evil",
              resource_metadata_url: "https://srv.example.com/api/../evil/.well-known/oauth-protected-resource",
            )
          end

          assert_match(/resource/i, error.message)
        end

        def test_run_strips_userinfo_from_resource_parameter_when_server_url_carries_credentials
          # `Discovery.canonicalize_url` drops `user:pass@`, so the RFC 8707
          # `resource` parameter sent on both the authorization request and
          # the token exchange must contain only the origin + path: shipping
          # the raw URL would hand the user's credentials to the authorization
          # server.
          stub_request(:get, @prm_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(authorization_servers: [@auth_base]),
          )

          captured_url = nil
          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) { captured_url = url },
            callback_handler: -> {
              [
                "test-auth-code",
                URI.decode_www_form(captured_url.query).to_h.fetch("state"),
              ]
            },
          )

          Flow.new(provider: provider).run!(
            server_url: "https://hunter2:t0psecret@srv.example.com/mcp",
            resource_metadata_url: @prm_url,
          )

          query = URI.decode_www_form(captured_url.query).to_h
          assert_equal("https://srv.example.com/mcp", query["resource"])
          refute_includes(query["resource"], "hunter2")
          refute_includes(query["resource"], "t0psecret")

          assert_requested(:post, "#{@auth_base}/token") do |req|
            form = URI.decode_www_form(req.body).to_h
            form["resource"] == "https://srv.example.com/mcp"
          end
        end

        def test_run_resource_mismatch_error_does_not_leak_userinfo
          # When PRM advertises a `resource` that does not cover the MCP server
          # URL, the mismatch error message MUST cite the canonicalized URLs so
          # that `user:pass@` cannot reach logs, stack traces, or exception
          # reporters.
          stub_request(:get, @prm_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              resource: "https://hunter2:t0psecret@evil.example.com/mcp",
              authorization_servers: [@auth_base],
            ),
          )

          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { [nil, nil] },
          )

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(
              server_url: "https://hunter2:t0psecret@srv.example.com/mcp",
              resource_metadata_url: @prm_url,
            )
          end

          refute_includes(error.message, "hunter2")
          refute_includes(error.message, "t0psecret")
        end

        def test_run_blocks_cross_tenant_query_bypass
          # A hijacked PRM that advertises a different tenant's `resource`
          # MUST cause an audience-binding failure rather than allowing
          # the client to mint a token bound to the attacker's tenant for
          # the victim's MCP server.
          stub_request(:get, @prm_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              resource: "https://srv.example.com/mcp?tenant=evil",
              authorization_servers: [@auth_base],
            ),
          )

          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { [nil, nil] },
          )

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(
              server_url: "https://srv.example.com/mcp?tenant=victim",
              resource_metadata_url: @prm_url,
            )
          end

          assert_match(/resource/i, error.message)
        end

        def test_run_raises_on_resource_mismatch
          stub_request(:get, @prm_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              resource: "https://evil.example.com/mcp",
              authorization_servers: [@auth_base],
            ),
          )

          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          )

          error = assert_raises(Flow::AuthorizationError) do
            Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)
          end

          assert_match(/resource/i, error.message)
        end

        def test_run_sends_server_url_as_resource_when_prm_omits_it
          stub_request(:get, @prm_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(authorization_servers: [@auth_base]),
          )

          state_holder = {}
          provider = Provider.new(
            client_metadata: {
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) {
              state_holder[:url] = url
              state_holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", state_holder[:state]] },
          )

          Flow.new(provider: provider).run!(server_url: @server_url, resource_metadata_url: @prm_url)

          query = URI.decode_www_form(state_holder[:url].query).to_h
          assert_equal("https://srv.example.com/mcp", query["resource"])

          assert_requested(:post, "#{@auth_base}/token") do |req|
            URI.decode_www_form(req.body).to_h["resource"] == "https://srv.example.com/mcp"
          end
        end
      end
    end
  end
end
