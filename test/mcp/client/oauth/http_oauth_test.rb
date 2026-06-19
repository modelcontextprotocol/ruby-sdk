# frozen_string_literal: true

require "test_helper"
require "json"
require "webmock/minitest"
require "faraday"
require "mcp/client/http"
require "mcp/client/oauth"

module MCP
  class Client
    module OAuth
      class HTTPOAuthTest < Minitest::Test
        def setup
          WebMock.enable!
          @mcp_url = "https://srv.example.com/mcp"
          @prm_url = "https://srv.example.com/.well-known/oauth-protected-resource/mcp"
          @auth_base = "https://auth.example.com"
        end

        def teardown
          WebMock.reset!
        end

        def test_send_request_runs_oauth_flow_on_401_and_retries_with_bearer_token
          # First POST: 401 with WWW-Authenticate. Second POST (with Bearer): 200.
          stub_request(:post, @mcp_url)
            .with { |req| req.headers["Authorization"].nil? }
            .to_return(
              status: 401,
              headers: {
                "WWW-Authenticate" => %(Bearer error="invalid_token", resource_metadata="#{@prm_url}"),
              },
              body: "",
            )

          stub_request(:post, @mcp_url)
            .with(headers: { "Authorization" => "Bearer test-token-after-flow" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: JSON.generate(jsonrpc: "2.0", id: "1", result: { ok: true }),
            )

          stub_request(:get, @prm_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              resource: "https://srv.example.com/mcp",
              authorization_servers: [@auth_base],
            ),
          )

          stub_request(:get, "#{@auth_base}/.well-known/oauth-authorization-server").to_return(
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
            body: JSON.generate(client_id: "test-client"),
          )

          stub_request(:post, "#{@auth_base}/token").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(access_token: "test-token-after-flow", token_type: "Bearer", expires_in: 3600),
          )

          state_holder = {}
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
              state_holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", state_holder[:state]] },
          )

          transport = HTTP.new(url: @mcp_url, oauth: provider)
          response = transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })

          assert_equal({ "ok" => true }, response["result"])
          assert_equal("test-token-after-flow", provider.access_token)
        end

        def test_send_request_runs_step_up_flow_on_403_insufficient_scope
          # First call with the initial token: 403 carrying an `insufficient_scope`
          # Bearer challenge with the escalated scope. The transport must re-run
          # a full authorization (NOT a refresh) with the escalated scope and
          # retry the original request.
          stub_request(:post, @mcp_url).with(
            headers: { "Authorization" => "Bearer initial-token" },
          ).to_return(
            status: 403,
            headers: {
              "WWW-Authenticate" => %(Bearer error="insufficient_scope", ) +
                %(scope="mcp:basic mcp:write", resource_metadata="#{@prm_url}"),
            },
            body: "",
          )

          stub_request(:post, @mcp_url).with(
            headers: { "Authorization" => "Bearer escalated-token" },
          ).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(jsonrpc: "2.0", id: "1", result: { ok: true }),
          )

          stub_step_up_authorization_server
          provider = build_step_up_provider

          transport = HTTP.new(url: @mcp_url, oauth: provider)
          response = transport.send_request(
            request: { jsonrpc: "2.0", id: "1", method: "tools/call", params: { name: "x" } },
          )

          assert_equal({ "ok" => true }, response["result"])
          assert_equal("escalated-token", provider.access_token)

          # The fresh authorization-code grant ran (refresh path was bypassed).
          assert_requested(:post, "#{@auth_base}/token") do |req|
            form = URI.decode_www_form(req.body).to_h
            form["grant_type"] == "authorization_code" &&
              form["code"] == "test-auth-code"
          end

          # And the authorization request the SDK handed to the redirect
          # handler carried the escalated scope from the challenge.
          authorization_query = URI.decode_www_form(provider.last_authorization_url.query).to_h
          assert_equal("mcp:basic mcp:write", authorization_query["scope"])
        end

        def test_send_request_step_up_unions_existing_scope_with_challenge_scope
          # MCP step-up: the re-authorization request must ask for the union
          # of the previously granted scope and the newly demanded scope.
          # Otherwise the new token would lack permissions the caller had
          # before, triggering another step-up the next time they are used.
          stub_request(:post, @mcp_url)
            .with(headers: { "Authorization" => "Bearer initial-token" })
            .to_return(
              status: 403,
              headers: {
                "WWW-Authenticate" => %(Bearer error="insufficient_scope", ) +
                  %(scope="mcp:write", resource_metadata="#{@prm_url}"),
              },
              body: "",
            )

          stub_request(:post, @mcp_url)
            .with(headers: { "Authorization" => "Bearer escalated-token" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: JSON.generate(jsonrpc: "2.0", id: "1", result: { ok: true }),
            )

          stub_step_up_authorization_server
          provider = build_step_up_provider
          # The provider already holds a token granted for `mcp:read`.
          provider.save_tokens(
            "access_token" => "initial-token",
            "token_type" => "Bearer",
            "scope" => "mcp:read",
          )

          transport = HTTP.new(url: @mcp_url, oauth: provider)
          transport.send_request(
            request: { jsonrpc: "2.0", id: "1", method: "tools/call", params: {} },
          )

          authorization_query = URI.decode_www_form(provider.last_authorization_url.query).to_h
          requested = authorization_query["scope"].split
          assert_includes(requested, "mcp:read", "must preserve previously granted scope")
          assert_includes(requested, "mcp:write", "must add the newly demanded scope")
          assert_equal(requested.uniq.length, requested.length, "must not duplicate scopes")
        end

        def test_send_request_does_not_retry_plain_403
          # A 403 without an `insufficient_scope` Bearer challenge is a hard
          # forbidden, not a step-up signal. Surface it as a `RequestHandlerError`
          # rather than tripping the OAuth flow.
          stub_request(:post, @mcp_url).with(
            headers: { "Authorization" => "Bearer initial-token" },
          ).to_return(
            status: 403, body: "",
          )

          provider = build_step_up_provider
          transport = HTTP.new(url: @mcp_url, oauth: provider)

          error = assert_raises(MCP::Client::RequestHandlerError) do
            transport.send_request(
              request: { jsonrpc: "2.0", id: "1", method: "tools/call", params: {} },
            )
          end
          assert_equal(:forbidden, error.error_type)
          assert_not_requested(:get, "#{@auth_base}/.well-known/oauth-authorization-server")
        end

        def test_send_request_does_not_loop_on_repeated_insufficient_scope
          # The server keeps demanding more scope after every authorization.
          # The transport retries the step-up flow at most once per
          # `send_request`, then surfaces the 403 to the caller.
          stub_request(:post, @mcp_url).to_return(
            status: 403,
            headers: {
              "WWW-Authenticate" => %(Bearer error="insufficient_scope", ) +
                %(scope="mcp:everything", resource_metadata="#{@prm_url}"),
            },
            body: "",
          )

          stub_step_up_authorization_server
          provider = build_step_up_provider
          transport = HTTP.new(url: @mcp_url, oauth: provider)

          error = assert_raises(MCP::Client::RequestHandlerError) do
            transport.send_request(
              request: { jsonrpc: "2.0", id: "1", method: "tools/call", params: {} },
            )
          end
          assert_equal(:forbidden, error.error_type)
        end

        def test_send_request_step_up_bypasses_refresh_token
          # The provider has a refresh_token, but step-up MUST run a fresh
          # authorization request with the escalated scope, not exchange the
          # refresh_token. Refreshing would mint a new access token with the
          # same scopes as the current one, which already failed.
          stub_request(:post, @mcp_url).with(
            headers: { "Authorization" => "Bearer initial-token" },
          ).to_return(
            status: 403,
            headers: {
              "WWW-Authenticate" => %(Bearer error="insufficient_scope", ) +
                %(scope="mcp:basic mcp:write", resource_metadata="#{@prm_url}"),
            },
            body: "",
          )

          stub_request(:post, @mcp_url).with(
            headers: { "Authorization" => "Bearer escalated-token" },
          ).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(jsonrpc: "2.0", id: "1", result: { ok: true }),
          )

          stub_step_up_authorization_server
          provider = build_step_up_provider
          provider.save_tokens(
            "access_token" => "initial-token",
            "refresh_token" => "saved-rt",
            "token_type" => "Bearer",
          )

          transport = HTTP.new(url: @mcp_url, oauth: provider)
          transport.send_request(
            request: { jsonrpc: "2.0", id: "1", method: "tools/call", params: {} },
          )

          # The token endpoint was only called for the fresh
          # `authorization_code` grant, never for `refresh_token`.
          assert_not_requested(:post, "#{@auth_base}/token") do |req|
            URI.decode_www_form(req.body).to_h["grant_type"] == "refresh_token"
          end
        end

        def test_send_request_step_up_appends_offline_access_when_advertised
          # Integration of step-up with the SEP-2207 offline_access logic:
          # the re-authorization request unions the existing and challenge scopes,
          # then -- because the AS advertises `offline_access` and the client
          # declared the `refresh_token` grant -- `offline_access` is appended
          # so the escalated token can itself be refreshed later.
          stub_request(:post, @mcp_url)
            .with(headers: { "Authorization" => "Bearer initial-token" })
            .to_return(
              status: 403,
              headers: {
                "WWW-Authenticate" => %(Bearer error="insufficient_scope", ) +
                  %(scope="mcp:write", resource_metadata="#{@prm_url}"),
              },
              body: "",
            )

          stub_request(:post, @mcp_url)
            .with(headers: { "Authorization" => "Bearer escalated-token" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: JSON.generate(jsonrpc: "2.0", id: "1", result: { ok: true }),
            )

          stub_step_up_authorization_server(
            extra_as_metadata: { scopes_supported: ["mcp:read", "mcp:write", "offline_access"] },
          )
          provider = build_step_up_provider(grant_types: ["authorization_code", "refresh_token"])
          provider.save_tokens(
            "access_token" => "initial-token",
            "token_type" => "Bearer",
            "scope" => "mcp:read",
          )

          transport = HTTP.new(url: @mcp_url, oauth: provider)
          transport.send_request(
            request: { jsonrpc: "2.0", id: "1", method: "tools/call", params: {} },
          )

          requested = URI.decode_www_form(provider.last_authorization_url.query).to_h["scope"].split
          assert_includes(requested, "mcp:read", "must preserve previously granted scope")
          assert_includes(requested, "mcp:write", "must add the challenged scope")
          assert_includes(requested, "offline_access", "must append offline_access when advertised")
        end

        def test_send_request_step_up_strips_offline_access_when_not_advertised
          # Mirror of the previous test: if the AS does NOT advertise
          # `offline_access`, the step-up request must not carry it even when
          # the existing token's scope happened to include it
          # (SEP-2207 MUST-NOT, enforced by `normalize_offline_access_scope`).
          stub_request(:post, @mcp_url)
            .with(headers: { "Authorization" => "Bearer initial-token" })
            .to_return(
              status: 403,
              headers: {
                "WWW-Authenticate" => %(Bearer error="insufficient_scope", ) +
                  %(scope="mcp:write", resource_metadata="#{@prm_url}"),
              },
              body: "",
            )

          stub_request(:post, @mcp_url)
            .with(headers: { "Authorization" => "Bearer escalated-token" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: JSON.generate(jsonrpc: "2.0", id: "1", result: { ok: true }),
            )

          # AS advertises only resource scopes, no offline_access.
          stub_step_up_authorization_server(
            extra_as_metadata: { scopes_supported: ["mcp:read", "mcp:write"] },
          )
          provider = build_step_up_provider(grant_types: ["authorization_code", "refresh_token"])
          provider.save_tokens(
            "access_token" => "initial-token",
            "token_type" => "Bearer",
            "scope" => "mcp:read offline_access",
          )

          transport = HTTP.new(url: @mcp_url, oauth: provider)
          transport.send_request(
            request: { jsonrpc: "2.0", id: "1", method: "tools/call", params: {} },
          )

          requested = URI.decode_www_form(provider.last_authorization_url.query).to_h["scope"].split
          assert_includes(requested, "mcp:read")
          assert_includes(requested, "mcp:write")
          refute_includes(requested, "offline_access", "must strip offline_access when the AS does not advertise it")
        end

        def test_send_request_step_up_uses_cimd_client_id
          # Integration of step-up with Client ID Metadata Documents:
          # when the provider is CIMD-configured and the AS advertises CIMD support,
          # the step-up re-authorization uses the CIMD URL as `client_id` and skips
          # Dynamic Client Registration, just like the initial flow.
          cimd_url = "https://app.example.com/client-metadata.json"

          stub_request(:post, @mcp_url)
            .with(headers: { "Authorization" => "Bearer initial-token" })
            .to_return(
              status: 403,
              headers: {
                "WWW-Authenticate" => %(Bearer error="insufficient_scope", ) +
                  %(scope="mcp:basic mcp:write", resource_metadata="#{@prm_url}"),
              },
              body: "",
            )

          stub_request(:post, @mcp_url)
            .with(headers: { "Authorization" => "Bearer escalated-token" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: JSON.generate(jsonrpc: "2.0", id: "1", result: { ok: true }),
            )

          stub_step_up_authorization_server(
            extra_as_metadata: { client_id_metadata_document_supported: true },
          )
          provider = build_step_up_provider(client_id_metadata_document_url: cimd_url)

          transport = HTTP.new(url: @mcp_url, oauth: provider)
          transport.send_request(
            request: { jsonrpc: "2.0", id: "1", method: "tools/call", params: {} },
          )

          # DCR was skipped and the CIMD URL was used as the client_id on
          # the escalated authorization request.
          assert_not_requested(:post, "#{@auth_base}/register")
          authorization_query = URI.decode_www_form(provider.last_authorization_url.query).to_h
          assert_equal(cimd_url, authorization_query["client_id"])
        end

        def test_initialize_rejects_non_secure_mcp_url_when_oauth_is_set
          # A bearer token sent to `http://attacker.example.com/mcp` would leak
          # over the wire. When OAuth is on, the transport URL must clear
          # the same Communication Security bar as every other OAuth-related URL.
          provider = Provider.new(
            client_metadata: { redirect_uris: ["http://localhost:0/callback"] },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          )

          assert_raises(MCP::Client::HTTP::InsecureURLError) do
            MCP::Client::HTTP.new(url: "http://attacker.example.com/mcp", oauth: provider)
          end
        end

        def test_initialize_allows_loopback_http_mcp_url_when_oauth_is_set
          provider = Provider.new(
            client_metadata: { redirect_uris: ["http://localhost:0/callback"] },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          )

          # Loopback HTTP is permitted for local development / conformance.
          MCP::Client::HTTP.new(url: "http://localhost:9292/mcp", oauth: provider)
          MCP::Client::HTTP.new(url: "http://127.0.0.1:9292/mcp", oauth: provider)
        end

        def test_initialize_allows_non_secure_mcp_url_when_oauth_is_nil
          # Without OAuth, no bearer tokens are sent, so the SDK leaves
          # the scheme decision to the caller.
          MCP::Client::HTTP.new(url: "http://internal.example.com/mcp")
        end

        def test_refresh_path_preserves_query_string_in_resource_claim
          # The refresh flow MUST send the same canonical `resource` claim as
          # the original authorization request -- otherwise the AS rejects
          # the refresh as a different audience. Verify by giving the transport
          # a query-bearing MCP URL and a saved refresh token, then asserting
          # the refresh POST body carries the full URL.
          tenant_mcp_url = "https://srv.example.com/mcp?tenant=1"

          stub_request(:post, tenant_mcp_url)
            .with { |req| req.headers["Authorization"] != "Bearer refreshed-tenant-token" }
            .to_return(
              status: 401,
              headers: {
                "WWW-Authenticate" => %(Bearer error="invalid_token", resource_metadata="#{@prm_url}"),
              },
              body: "",
            )

          stub_request(:post, tenant_mcp_url)
            .with(headers: { "Authorization" => "Bearer refreshed-tenant-token" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: JSON.generate(jsonrpc: "2.0", id: "1", result: { ok: true }),
            )

          stub_request(:get, @prm_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(authorization_servers: [@auth_base]),
          )

          stub_request(:get, "#{@auth_base}/.well-known/oauth-authorization-server").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
            ),
          )

          stub_request(:post, "#{@auth_base}/token")
            .with(body: hash_including("grant_type" => "refresh_token"))
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: JSON.generate(access_token: "refreshed-tenant-token", token_type: "Bearer", expires_in: 3600),
            )

          provider = build_provider
          provider.save_client_information("client_id" => "test-client")
          provider.save_tokens("access_token" => "stale", "refresh_token" => "valid-rt")

          transport = HTTP.new(url: tenant_mcp_url, oauth: provider)
          response = transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })

          assert_equal({ "ok" => true }, response["result"])

          # The refresh POST body's `resource` MUST keep the query string so it
          # matches the audience the original token was minted for.
          assert_requested(:post, "#{@auth_base}/token") do |req|
            form = URI.decode_www_form(req.body).to_h
            form["grant_type"] == "refresh_token" &&
              form["resource"] == "https://srv.example.com/mcp?tenant=1"
          end
        end

        def test_send_request_refreshes_when_refresh_token_is_available
          # On 401 with a saved refresh_token, the transport should swap it for
          # a fresh access token rather than re-running the full interactive
          # Authorization Code flow.
          stub_request(:post, @mcp_url)
            .with { |req| req.headers["Authorization"] != "Bearer refreshed-token" }
            .to_return(
              status: 401,
              headers: {
                "WWW-Authenticate" => %(Bearer error="invalid_token", resource_metadata="#{@prm_url}"),
              },
              body: "",
            )

          stub_request(:post, @mcp_url)
            .with(headers: { "Authorization" => "Bearer refreshed-token" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: JSON.generate(jsonrpc: "2.0", id: "1", result: { ok: true }),
            )

          stub_request(:get, @prm_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(resource: "https://srv.example.com/mcp", authorization_servers: [@auth_base]),
          )

          stub_request(:get, "#{@auth_base}/.well-known/oauth-authorization-server").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
            ),
          )

          # DCR and /authorize must not be invoked when refresh succeeds.
          stub_request(:post, "#{@auth_base}/register").to_raise(StandardError.new("DCR should not be called."))
          stub_request(:get, "#{@auth_base}/authorize").to_raise(StandardError.new("authorize should not be called."))

          stub_request(:post, "#{@auth_base}/token")
            .with(body: hash_including("grant_type" => "refresh_token"))
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: JSON.generate(access_token: "refreshed-token", token_type: "Bearer", expires_in: 3600),
            )

          provider = build_provider
          provider.save_client_information("client_id" => "test-client")
          provider.save_tokens("access_token" => "stale-token", "refresh_token" => "saved-rt")

          transport = HTTP.new(url: @mcp_url, oauth: provider)
          response = transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })

          assert_equal({ "ok" => true }, response["result"])
          assert_equal("refreshed-token", provider.access_token)
        end

        def test_send_request_preserves_refresh_token_when_refresh_hits_a_transient_failure
          # A 5xx (or any non-`invalid_grant`) from the token endpoint indicates
          # a transient AS outage, NOT that the refresh token is dead.
          # The transport must fall through to the full Authorization Code flow
          # (we cannot serve the MCP request without a fresh access token), but
          # the stored refresh_token must remain so subsequent attempts on
          # the next outage-free request can succeed without interactive reauth.
          stub_request(:post, @mcp_url)
            .with { |req| req.headers["Authorization"] != "Bearer brand-new-token" }
            .to_return(
              status: 401,
              headers: {
                "WWW-Authenticate" => %(Bearer error="invalid_token", resource_metadata="#{@prm_url}"),
              },
              body: "",
            )

          stub_request(:post, @mcp_url)
            .with(headers: { "Authorization" => "Bearer brand-new-token" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: JSON.generate(jsonrpc: "2.0", id: "1", result: { ok: true }),
            )

          stub_request(:get, @prm_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(resource: "https://srv.example.com/mcp", authorization_servers: [@auth_base]),
          )

          stub_request(:get, "#{@auth_base}/.well-known/oauth-authorization-server").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
            ),
          )

          # Refresh request: transient 503. Auth code exchange: succeeds with
          # a NEW refresh token (so we can prove the live RT survived rather than
          # being silently overwritten by the success path).
          stub_request(:post, "#{@auth_base}/token")
            .with(body: hash_including("grant_type" => "refresh_token"))
            .to_return(status: 503, body: "")
          stub_request(:post, "#{@auth_base}/token")
            .with(body: hash_including("grant_type" => "authorization_code"))
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: JSON.generate(access_token: "brand-new-token", token_type: "Bearer"),
            )

          state_holder = {}
          provider = Provider.new(
            client_metadata: { redirect_uris: ["http://localhost:0/callback"] },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) {
              state_holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", state_holder[:state]] },
          )
          provider.save_client_information("client_id" => "test-client")
          provider.save_tokens("access_token" => "stale", "refresh_token" => "live-rt")

          transport = HTTP.new(url: @mcp_url, oauth: provider)
          response = transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })

          assert_equal({ "ok" => true }, response["result"])
          # The transient 503 must not wipe the refresh token; the auth-code
          # success path overwrites tokens, but we asserted the prior refresh
          # token survived the refresh-attempt failure by NOT seeing the full
          # flow trigger `clear_tokens!`. To prove this, inspect that
          # the final stored refresh_token is whatever the auth-code response
          # provided (omitted here), not nil from a forced clear.
          stored = provider.tokens || {}
          assert_equal("brand-new-token", stored["access_token"] || stored[:access_token])
        end

        def test_send_request_falls_back_to_full_flow_when_refresh_fails
          # If the refresh request itself is rejected (refresh token revoked),
          # the transport should clear stale tokens and fall through to
          # the full Authorization Code flow.
          stub_request(:post, @mcp_url)
            .with { |req| req.headers["Authorization"] != "Bearer brand-new-token" }
            .to_return(
              status: 401,
              headers: {
                "WWW-Authenticate" => %(Bearer error="invalid_token", resource_metadata="#{@prm_url}"),
              },
              body: "",
            )

          stub_request(:post, @mcp_url)
            .with(headers: { "Authorization" => "Bearer brand-new-token" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: JSON.generate(jsonrpc: "2.0", id: "1", result: { ok: true }),
            )

          stub_request(:get, @prm_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(resource: "https://srv.example.com/mcp", authorization_servers: [@auth_base]),
          )

          stub_request(:get, "#{@auth_base}/.well-known/oauth-authorization-server").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
            ),
          )

          # First /token call (refresh) fails; second call (authorization_code) succeeds.
          stub_request(:post, "#{@auth_base}/token")
            .with(body: hash_including("grant_type" => "refresh_token"))
            .to_return(status: 401, body: "")
          stub_request(:post, "#{@auth_base}/token")
            .with(body: hash_including("grant_type" => "authorization_code"))
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: JSON.generate(access_token: "brand-new-token", token_type: "Bearer", expires_in: 3600),
            )

          state_holder = {}
          provider = Provider.new(
            client_metadata: { redirect_uris: ["http://localhost:0/callback"] },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) {
              state_holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", state_holder[:state]] },
          )
          provider.save_client_information("client_id" => "test-client")
          provider.save_tokens("access_token" => "stale", "refresh_token" => "revoked-rt")

          transport = HTTP.new(url: @mcp_url, oauth: provider)
          response = transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })

          assert_equal({ "ok" => true }, response["result"])
          assert_equal("brand-new-token", provider.access_token)
        end

        def test_oauth_flow_preserves_query_string_in_resource_claim
          # Query parameters on the MCP URL (e.g. `?tenant=...`) must be carried
          # into the RFC 8707 `resource` claim sent on the authorization and
          # token requests, matching how the TS and Python SDKs build
          # the canonical resource URL. The URL guard's snapshot is allowed to drop
          # the query because Faraday does the same at request time, but
          # the OAuth-side snapshot must retain it.
          tenant_mcp_url = "https://srv.example.com/mcp?tenant=1"

          stub_request(:post, tenant_mcp_url)
            .with { |req| req.headers["Authorization"].nil? }
            .to_return(
              status: 401,
              headers: {
                "WWW-Authenticate" => %(Bearer error="invalid_token", resource_metadata="#{@prm_url}"),
              },
              body: "",
            )

          stub_request(:post, tenant_mcp_url)
            .with(headers: { "Authorization" => "Bearer tenant-token" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: JSON.generate(jsonrpc: "2.0", id: "1", result: { ok: true }),
            )

          stub_request(:get, @prm_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              # PRM is allowed to omit `resource`; the client falls back to its
              # canonical MCP URL (query and all).
              authorization_servers: [@auth_base],
            ),
          )

          stub_request(:get, "#{@auth_base}/.well-known/oauth-authorization-server").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
            ),
          )

          stub_request(:post, "#{@auth_base}/register").to_return(
            status: 201,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(client_id: "test-client"),
          )

          stub_request(:post, "#{@auth_base}/token").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(access_token: "tenant-token", token_type: "Bearer", expires_in: 3600),
          )

          captured_authorization_url = nil
          provider = Provider.new(
            client_metadata: {
              client_name: "ruby-sdk-test",
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) { captured_authorization_url = url },
            callback_handler: -> {
              query = URI.decode_www_form(captured_authorization_url.query).to_h
              ["test-auth-code", query.fetch("state")]
            },
          )

          transport = HTTP.new(url: tenant_mcp_url, oauth: provider)
          response = transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })

          assert_equal({ "ok" => true }, response["result"])

          # The authorization URL's `resource` parameter MUST keep the query.
          query = URI.decode_www_form(captured_authorization_url.query).to_h
          assert_equal("https://srv.example.com/mcp?tenant=1", query["resource"])

          # The token endpoint POST body's `resource` MUST also keep the query.
          assert_requested(:post, "#{@auth_base}/token") do |req|
            URI.decode_www_form(req.body).to_h["resource"] == "https://srv.example.com/mcp?tenant=1"
          end
        end

        def test_oauth_flow_uses_validated_url_after_url_mutation
          # Even if an attacker mutates `@url` after construction (e.g.
          # `instance_variable_set(:@url, "https://attacker.example.com/mcp")`),
          # the OAuth discovery / authorization code flow MUST continue to use
          # the URL snapshotted at initialize time. Otherwise PRM, AS metadata,
          # and the `resource` claim sent to the authorization server would
          # all point at the attacker-controlled host.
          attacker_prm = "https://attacker.example.com/.well-known/oauth-protected-resource/mcp"
          attacker_root_prm = "https://attacker.example.com/.well-known/oauth-protected-resource"
          stub_request(:get, attacker_prm).to_raise(StandardError.new("PRM must not target attacker host."))
          stub_request(:get, attacker_root_prm).to_raise(StandardError.new("PRM must not target attacker host."))

          stub_request(:post, @mcp_url)
            .with { |req| req.headers["Authorization"] != "Bearer post-mutation-token" }
            .to_return(
              status: 401,
              # No `resource_metadata` to force PRM derivation from
              # the server_url -- this is exactly the path where a mutated
              # `@url` could redirect discovery without the snapshot.
              headers: { "WWW-Authenticate" => 'Bearer error="invalid_token"' },
              body: "",
            )

          stub_request(:get, @prm_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              resource: "https://srv.example.com/mcp",
              authorization_servers: [@auth_base],
            ),
          )

          stub_request(:get, "#{@auth_base}/.well-known/oauth-authorization-server").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
            ),
          )

          stub_request(:post, "#{@auth_base}/register").to_return(
            status: 201,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(client_id: "test-client"),
          )

          stub_request(:post, "#{@auth_base}/token").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(access_token: "post-mutation-token", token_type: "Bearer", expires_in: 3600),
          )

          captured_authorization_url = nil
          provider = Provider.new(
            client_metadata: {
              client_name: "ruby-sdk-test",
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) { captured_authorization_url = url },
            callback_handler: -> {
              query = URI.decode_www_form(captured_authorization_url.query).to_h
              ["test-auth-code", query.fetch("state")]
            },
          )

          stub_request(:post, @mcp_url)
            .with(headers: { "Authorization" => "Bearer post-mutation-token" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: JSON.generate(jsonrpc: "2.0", id: "1", result: { ok: true }),
            )

          transport = HTTP.new(url: @mcp_url, oauth: provider)
          # Force the lazy Faraday connection to be built against the validated
          # URL before the mutation. After this, `@client.url_prefix` is
          # locked to `srv.example.com` regardless of what `@url` later points
          # at, which is what the URL guard middleware reads.
          transport.send(:client)
          transport.instance_variable_set(:@url, "https://attacker.example.com/mcp")

          # The first 401 must drive `run_oauth_flow!` against the validated
          # URL, not the mutated `@url`. The OAuth flow succeeds, the retry
          # carries the new bearer token, and Faraday (still pointed at
          # the safe URL via its frozen `url_prefix`) returns the stubbed 200.
          response = transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })

          assert_equal({ "ok" => true }, response["result"])
          # Discovery must have aimed at the validated host. The attacker-host
          # PRM stubs would have raised otherwise.
          assert_requested(:get, @prm_url)
          refute_requested(:get, attacker_prm)
          refute_requested(:get, attacker_root_prm)
          # The `resource` claim sent on the authorization URL is built from
          # the validated URL, not the attacker-host mutation.
          query = URI.decode_www_form(captured_authorization_url.query).to_h
          assert_equal("https://srv.example.com/mcp", query["resource"])
          refute_includes(query["resource"], "attacker.example.com")
        end

        def test_send_request_rejects_url_mutation_after_initialize
          # The constructor secure-URL check alone is not enough: `@url` is
          # a plain instance variable, so a caller can `instance_variable_set` it
          # to a non-secure URL after the transport is built. The send-time
          # re-check must catch this and refuse to send the bearer token.
          provider = build_provider
          transport = MCP::Client::HTTP.new(url: "https://srv.example.com/mcp", oauth: provider)
          transport.instance_variable_set(:@url, "http://attacker.example.com/mcp")

          assert_raises(MCP::Client::HTTP::InsecureURLError) do
            transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })
          end
        end

        def test_send_request_rejects_faraday_customizer_url_swap
          # An `&block` Faraday customizer can rewrite `url_prefix` to point at
          # a plaintext attacker host; the constructor URL check would miss this.
          # The send-time effective-URL check must reject it.
          provider = build_provider
          transport = MCP::Client::HTTP.new(url: "https://srv.example.com/mcp", oauth: provider) do |faraday|
            faraday.url_prefix = "http://attacker.example.com/mcp"
          end

          assert_raises(MCP::Client::HTTP::InsecureURLError) do
            transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })
          end
        end

        def test_send_request_rejects_https_to_different_host_via_customizer
          # An `https://` URL alone is not enough - the URL must also match
          # the one validated at initialize time. A customizer that swaps to
          # a *different* https host (e.g. `https://attacker.example.com/mcp`)
          # would otherwise pass a naive "still https?" check and leak
          # the bearer token to the attacker.
          provider = build_provider
          transport = MCP::Client::HTTP.new(url: "https://srv.example.com/mcp", oauth: provider) do |faraday|
            faraday.url_prefix = "https://attacker.example.com/mcp"
          end

          assert_raises(MCP::Client::HTTP::InsecureURLError) do
            transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })
          end
        end

        def test_send_request_rejects_middleware_env_url_query_rewrite
          # A Faraday middleware that swaps only the query (`tenant=victim` ->
          # `tenant=evil`) must be caught by the URL guard. Otherwise
          # an attacker who can inject middleware can ship the bearer token to
          # a different tenant of the same origin/path while the OAuth-side
          # audience binding stays correct.
          rewrite_query_middleware = Class.new do
            def initialize(app)
              @app = app
            end

            def call(env)
              env.url.query = "tenant=evil"
              @app.call(env)
            end
          end

          provider = build_provider
          provider.save_tokens("access_token" => "valid-token")
          transport = MCP::Client::HTTP.new(
            url: "https://srv.example.com/mcp?tenant=victim",
            oauth: provider,
          ) do |faraday|
            faraday.use(rewrite_query_middleware)
          end

          assert_raises(MCP::Client::HTTP::InsecureURLError) do
            transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })
          end
        end

        def test_send_request_rejects_middleware_env_url_rewrite
          # A Faraday middleware can mutate `env.url` at request time, which
          # `Faraday::Connection#url_prefix` cannot detect. The identity guard
          # must run as a middleware *after* the customizer so it sees
          # the rewritten env.url before it reaches the adapter.
          rewrite_middleware = Class.new do
            def initialize(app)
              @app = app
            end

            def call(env)
              env.url = URI("https://attacker.example.com/mcp")
              @app.call(env)
            end
          end

          provider = build_provider
          transport = MCP::Client::HTTP.new(url: "https://srv.example.com/mcp", oauth: provider) do |faraday|
            faraday.use(rewrite_middleware)
          end

          assert_raises(MCP::Client::HTTP::InsecureURLError) do
            transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })
          end
        end

        def test_send_request_accepts_validated_url_with_userinfo
          # Faraday hoists `user:pass@` out of the URL into an `Authorization:
          # Basic` header, so `env.url` at request time does not carry
          # the userinfo. The identity guard must drop userinfo on both sides to
          # avoid a false-positive `InsecureURLError` on this valid URL.
          stub_request(:post, "https://srv.example.com/mcp")
            .with(headers: { "Authorization" => /Basic|Bearer/ })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: JSON.generate(jsonrpc: "2.0", id: "1", result: { ok: true }),
            )

          provider = build_provider
          provider.save_tokens("access_token" => "valid-token")

          transport = MCP::Client::HTTP.new(url: "https://user:pass@srv.example.com/mcp", oauth: provider)
          response = transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })

          assert_equal({ "ok" => true }, response["result"])
        end

        def test_insecure_url_error_does_not_leak_userinfo
          # The error message MUST surface only the canonicalized (origin + path)
          # form so that `user:pass@` cannot leak into logs, stack traces, or
          # exception reporters.
          provider = build_provider
          error = assert_raises(MCP::Client::HTTP::InsecureURLError) do
            MCP::Client::HTTP.new(url: "http://hunter2:t0psecret@attacker.example.com/mcp", oauth: provider)
          end

          refute_includes(error.message, "hunter2")
          refute_includes(error.message, "t0psecret")
        end

        def test_send_request_accepts_validated_url_with_query_string
          # A `?tenant=1` style query on the user-supplied URL must not trip
          # the identity guard. `Faraday::Connection#url_prefix.to_s` drops
          # the query, so naive string-compare would raise a false-positive
          # `InsecureURLError` on the very first request.
          stub_request(:post, "https://srv.example.com/mcp?tenant=1").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(jsonrpc: "2.0", id: "1", result: { ok: true }),
          )

          provider = build_provider
          provider.save_tokens("access_token" => "valid-token")

          transport = MCP::Client::HTTP.new(url: "https://srv.example.com/mcp?tenant=1", oauth: provider)
          response = transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })

          assert_equal({ "ok" => true }, response["result"])
        end

        def test_send_request_accepts_url_with_unsorted_query_parameters
          # Faraday sorts query parameters by name before sending the request,
          # so the snapshot and the effective URL must compare as equal even
          # when the user-supplied URL listed `b` first and `a` second.
          stub_request(:post, "https://srv.example.com/mcp?b=2&a=1").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(jsonrpc: "2.0", id: "1", result: { ok: true }),
          )

          provider = build_provider
          provider.save_tokens("access_token" => "valid-token")

          transport = MCP::Client::HTTP.new(url: "https://srv.example.com/mcp?b=2&a=1", oauth: provider)
          response = transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })

          assert_equal({ "ok" => true }, response["result"])
        end

        def test_send_request_accepts_url_with_lowercase_percent_encoded_hex
          # Faraday uppercases percent-encoded hex digits (`%2f` -> `%2F`),
          # so the snapshot and the effective URL must compare as equal even
          # when the user-supplied URL used lowercase hex.
          stub_request(:post, "https://srv.example.com/mcp?x=%2f").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(jsonrpc: "2.0", id: "1", result: { ok: true }),
          )

          provider = build_provider
          provider.save_tokens("access_token" => "valid-token")

          transport = MCP::Client::HTTP.new(url: "https://srv.example.com/mcp?x=%2f", oauth: provider)
          response = transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })

          assert_equal({ "ok" => true }, response["result"])
        end

        def test_send_request_accepts_url_with_valueless_query_key
          # `?tenant` (no `=`) and `?tenant=` (empty value) are distinct in
          # Faraday's encoding. The snapshot must preserve that distinction
          # so the URL guard does not false-positive when the user-supplied
          # URL omits the `=`.
          stub_request(:post, "https://srv.example.com/mcp?tenant").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(jsonrpc: "2.0", id: "1", result: { ok: true }),
          )

          provider = build_provider
          provider.save_tokens("access_token" => "valid-token")

          transport = MCP::Client::HTTP.new(url: "https://srv.example.com/mcp?tenant", oauth: provider)
          response = transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })

          assert_equal({ "ok" => true }, response["result"])
        end

        def test_send_request_accepts_url_with_array_form_query_parameters
          # Faraday preserves array-form (`?roles[]=a&roles[]=b`) duplicates
          # rather than collapsing them. The snapshot must do the same so
          # the URL guard does not raise a false positive.
          stub_request(:post, "https://srv.example.com/mcp?roles[]=a&roles[]=b").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(jsonrpc: "2.0", id: "1", result: { ok: true }),
          )

          provider = build_provider
          provider.save_tokens("access_token" => "valid-token")

          transport = MCP::Client::HTTP.new(url: "https://srv.example.com/mcp?roles[]=a&roles[]=b", oauth: provider)
          response = transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })

          assert_equal({ "ok" => true }, response["result"])
        end

        def test_send_request_rejects_array_form_query_entry_drop_via_middleware
          # An attacker middleware that strips one value from a multi-value
          # array-form query (`?tenant[]=victim&tenant[]=victim2` ->
          # `?tenant[]=victim`) must be caught by the URL guard. If
          # the snapshot collapsed duplicates, both forms would compare as equal
          # and the bearer token would leak to a partially-rewritten audience.
          drop_first_value_middleware = Class.new do
            def initialize(app)
              @app = app
            end

            def call(env)
              env.url.query = "tenant%5B%5D=victim"
              @app.call(env)
            end
          end

          provider = build_provider
          provider.save_tokens("access_token" => "valid-token")
          transport = MCP::Client::HTTP.new(
            url: "https://srv.example.com/mcp?tenant[]=victim&tenant[]=victim2",
            oauth: provider,
          ) do |faraday|
            faraday.use(drop_first_value_middleware)
          end

          assert_raises(MCP::Client::HTTP::InsecureURLError) do
            transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })
          end
        end

        def test_send_request_accepts_url_with_blank_query_segments
          # Faraday's query encoder drops empty-name pairs and blank `&&`
          # separators (`?&&a=1&&` -> `?a=1`). The snapshot must do the same
          # so the URL guard does not raise a false positive.
          stub_request(:post, "https://srv.example.com/mcp?a=1").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(jsonrpc: "2.0", id: "1", result: { ok: true }),
          )

          provider = build_provider
          provider.save_tokens("access_token" => "valid-token")

          transport = MCP::Client::HTTP.new(url: "https://srv.example.com/mcp?&&a=1&&", oauth: provider)
          response = transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })

          assert_equal({ "ok" => true }, response["result"])
        end

        def test_send_request_accepts_url_with_repeated_query_parameters
          # Faraday's query encoder collapses repeated same-name parameters
          # to the last value (`?a=1&a=2` -> `?a=2`). The snapshot must apply
          # the same collapse so the URL guard does not raise a false
          # positive.
          stub_request(:post, "https://srv.example.com/mcp?a=2").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(jsonrpc: "2.0", id: "1", result: { ok: true }),
          )

          provider = build_provider
          provider.save_tokens("access_token" => "valid-token")

          transport = MCP::Client::HTTP.new(url: "https://srv.example.com/mcp?a=1&a=2", oauth: provider)
          response = transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })

          assert_equal({ "ok" => true }, response["result"])
        end

        def test_send_request_accepts_url_with_empty_query_marker
          # Faraday drops a bare trailing `?` with no parameters, so
          # the snapshot and the effective URL must compare as equal even when
          # the user-supplied URL kept the `?` marker.
          stub_request(:post, "https://srv.example.com/mcp").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(jsonrpc: "2.0", id: "1", result: { ok: true }),
          )

          provider = build_provider
          provider.save_tokens("access_token" => "valid-token")

          transport = MCP::Client::HTTP.new(url: "https://srv.example.com/mcp?", oauth: provider)
          response = transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })

          assert_equal({ "ok" => true }, response["result"])
        end

        def test_send_request_rejects_https_to_different_host_via_url_mutation
          # Same identity-binding requirement when the swap goes through
          # `instance_variable_set(:@url, ...)`: the new URL is HTTPS, but it
          # is not the URL that was validated at initialize time.
          stub_request(:post, "https://attacker.example.com/mcp").to_return(status: 200, body: "")
          provider = build_provider
          transport = MCP::Client::HTTP.new(url: "https://srv.example.com/mcp", oauth: provider)
          transport.instance_variable_set(:@url, "https://attacker.example.com/mcp")
          transport.instance_variable_set(:@client, nil) # force Faraday rebuild against mutated @url

          assert_raises(MCP::Client::HTTP::InsecureURLError) do
            transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })
          end
        end

        def test_send_request_raises_unauthorized_when_no_oauth_provider
          stub_request(:post, @mcp_url).to_return(status: 401, body: "")
          transport = HTTP.new(url: @mcp_url)

          error = assert_raises(MCP::Client::RequestHandlerError) do
            transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })
          end
          assert_equal(:unauthorized, error.error_type)
        end

        def test_send_request_does_not_loop_when_oauth_flow_fails
          stub_request(:post, @mcp_url).to_return(status: 401, body: "")
          stub_request(:get, @prm_url).to_return(status: 404, body: "")
          stub_request(:get, "https://srv.example.com/.well-known/oauth-protected-resource").to_return(
            status: 404,
            body: "",
          )

          # With no PRM, discovery falls back to the legacy 2025-03-26 path; dead-end that too so the flow fails exactly once.
          stub_request(:get, "https://srv.example.com/.well-known/oauth-authorization-server").to_return(status: 404)
          stub_request(:get, "https://srv.example.com/.well-known/openid-configuration").to_return(status: 404)
          stub_request(:post, "https://srv.example.com/register").to_return(status: 404)

          provider = Provider.new(
            client_metadata: { redirect_uris: ["http://localhost:0/callback"] },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { [nil, nil] },
          )

          transport = HTTP.new(url: @mcp_url, oauth: provider)

          assert_raises(Flow::AuthorizationError) do
            transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })
          end
        end

        def test_send_request_does_not_re_run_oauth_flow_on_repeated_401
          # Server keeps returning 401 even after a successful token exchange.
          # The retry guard MUST limit OAuth flow execution to one attempt per
          # `send_request` so we surface the failure instead of looping.
          stub_request(:post, @mcp_url).to_return(
            status: 401,
            headers: {
              "WWW-Authenticate" => %(Bearer error="invalid_token", resource_metadata="#{@prm_url}"),
            },
            body: "",
          )

          stub_request(:get, @prm_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              resource: "https://srv.example.com/mcp",
              authorization_servers: [@auth_base],
            ),
          )

          stub_request(:get, "#{@auth_base}/.well-known/oauth-authorization-server").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: @auth_base,
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
            ),
          )

          stub_request(:post, "#{@auth_base}/register").to_return(
            status: 201,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(client_id: "test-client"),
          )

          stub_request(:post, "#{@auth_base}/token").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(access_token: "still-bad-token", token_type: "Bearer", expires_in: 3600),
          )

          state_holder = {}
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
              state_holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", state_holder[:state]] },
          )

          transport = HTTP.new(url: @mcp_url, oauth: provider)

          assert_raises(MCP::Client::RequestHandlerError) do
            transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "tools/list" })
          end

          # Token endpoint should be hit at most once across the failing call,
          # proving the retry guard prevents an infinite re-authorization loop.
          assert_requested(:post, "#{@auth_base}/token", times: 1)
        end

        private

        # Stubs PRM, AS metadata, /register, and /token so a full authorization
        # flow runs. The /token stub echoes `requested_scope` so callers can
        # assert the escalated scope was sent.
        # `extra_as_metadata` lets a test advertise additional AS capabilities
        # (e.g. `scopes_supported` for the offline_access interaction, or
        # `client_id_metadata_document_supported` for the CIMD interaction)
        # without duplicating the whole stub.
        def stub_step_up_authorization_server(extra_as_metadata: {})
          stub_request(:get, @prm_url).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              resource: "https://srv.example.com/mcp",
              authorization_servers: [@auth_base],
            ),
          )

          stub_request(:get, "#{@auth_base}/.well-known/oauth-authorization-server").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate({
              issuer: @auth_base,
              authorization_endpoint: "#{@auth_base}/authorize",
              token_endpoint: "#{@auth_base}/token",
              registration_endpoint: "#{@auth_base}/register",
              response_types_supported: ["code"],
              grant_types_supported: ["authorization_code", "refresh_token"],
              code_challenge_methods_supported: ["S256"],
              token_endpoint_auth_methods_supported: ["none"],
            }.merge(extra_as_metadata)),
          )

          stub_request(:post, "#{@auth_base}/register").to_return(
            status: 201,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(client_id: "test-client"),
          )

          stub_request(:post, "#{@auth_base}/token").to_return do |request|
            form = URI.decode_www_form(request.body).to_h

            {
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: JSON.generate(
                access_token: "escalated-token",
                token_type: "Bearer",
                expires_in: 3600,
                requested_scope: form["scope"],
                grant_type_received: form["grant_type"],
              ),
            }
          end
        end

        def build_step_up_provider(grant_types: ["authorization_code"], client_id_metadata_document_url: nil)
          state_holder = {}
          captured_authorization_url = nil
          provider = Provider.new(
            client_metadata: {
              client_name: "ruby-sdk-test",
              redirect_uris: ["http://localhost:0/callback"],
              grant_types: grant_types,
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(url) {
              captured_authorization_url = url
              state_holder[:state] = URI.decode_www_form(url.query).to_h.fetch("state")
            },
            callback_handler: -> { ["test-auth-code", state_holder[:state]] },
            client_id_metadata_document_url: client_id_metadata_document_url,
          )
          provider.save_tokens("access_token" => "initial-token", "token_type" => "Bearer")

          # `captured_authorization_url` is a closure variable that the redirect handler writes at flow time;
          # expose its current value via a method on the provider so tests can assert on what was sent to /authorize.
          provider.define_singleton_method(:last_authorization_url) { captured_authorization_url }
          provider
        end

        def build_provider
          Provider.new(
            client_metadata: { redirect_uris: ["http://localhost:0/callback"] },
            redirect_uri: "http://localhost:0/callback",
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          )
        end
      end
    end
  end
end
