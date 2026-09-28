# frozen_string_literal: true

require "test_helper"
require "mcp/client/oauth/discovery"

module MCP
  class Server
    module OAuth
      class MiddlewareTest < Minitest::Test
        RESOURCE_METADATA_URL = "https://mcp.example.com/.well-known/oauth-protected-resource/mcp"

        class StubVerifier
          def initialize(result)
            @result = result
          end

          def verify(_token)
            raise @result if @result.is_a?(Class) || @result.is_a?(StandardError)

            @result
          end
        end

        class RecordingApp
          attr_reader :last_env

          def call(env)
            @last_env = env

            [200, { "content-type" => "application/json" }, ["{}"]]
          end
        end

        def setup
          @app = RecordingApp.new
        end

        def test_missing_authorization_header_returns_401_challenge_without_error_code
          status, headers, body = middleware(token_verifier: StubVerifier.new(nil)).call({})

          assert_equal(401, status)
          assert_empty(body)

          params = MCP::Client::OAuth::Discovery.parse_www_authenticate(headers["www-authenticate"])

          # RFC 6750 Section 3.1: a challenge answering a request without any authentication information should not include an error code.
          refute(params.key?("error"))
          refute(params.key?("error_description"))
          assert_equal(RESOURCE_METADATA_URL, params["resource_metadata"])
          assert_nil(@app.last_env)
        end

        def test_non_bearer_scheme_returns_400
          env = { "HTTP_AUTHORIZATION" => "Basic dXNlcjpwYXNz" }

          status, headers, _body = middleware(token_verifier: StubVerifier.new(nil)).call(env)

          assert_equal(400, status)

          params = MCP::Client::OAuth::Discovery.parse_www_authenticate(headers["www-authenticate"])

          assert_equal("invalid_request", params["error"])
        end

        def test_verifier_raising_invalid_token_returns_401_with_description
          verifier = StubVerifier.new(InvalidTokenError.new("Token expired"))

          status, headers, _body = middleware(token_verifier: verifier).call(bearer_env)

          assert_equal(401, status)

          params = MCP::Client::OAuth::Discovery.parse_www_authenticate(headers["www-authenticate"])

          assert_equal("invalid_token", params["error"])
          assert_equal("Token expired", params["error_description"])
        end

        def test_verifier_message_with_invalid_bytes_still_returns_401
          verifier = StubVerifier.new(InvalidTokenError.new("bad \xFF byte"))

          status, headers, _body = middleware(token_verifier: verifier).call(bearer_env)

          assert_equal(401, status)
          assert_predicate(headers["www-authenticate"], :valid_encoding?)
          assert_includes(headers["www-authenticate"], 'error_description="bad ? byte"')
        end

        def test_verifier_message_in_binary_encoding_still_returns_401
          # A verifier that quotes `env["HTTP_AUTHORIZATION"]` fragments builds an ASCII-8BIT message,
          # on which `scrub` alone is a no-op; the JSON body must not raise on it either.
          verifier = StubVerifier.new(InvalidTokenError.new("bad \xFF byte".b))

          status, headers, body = middleware(token_verifier: verifier).call(bearer_env)

          assert_equal(401, status)
          assert_includes(headers["www-authenticate"], 'error_description="bad ? byte"')
          assert_equal("bad ? byte", JSON.parse(body.first)["error_description"])
        end

        def test_verifier_returning_nil_returns_generic_401
          status, headers, _body = middleware(token_verifier: StubVerifier.new(nil)).call(bearer_env)

          assert_equal(401, status)

          params = MCP::Client::OAuth::Discovery.parse_www_authenticate(headers["www-authenticate"])

          assert_equal("The access token is invalid", params["error_description"])
        end

        def test_expired_access_token_returned_by_verifier_is_trusted
          # Expiry enforcement is the verifier's contractual duty; re-checking it here would nullify the clock leeway
          # a verifier was configured with.
          expired = AccessToken.new(token: "abc", expires_at: Time.now.to_i - 60)

          status, _headers, _body = middleware(token_verifier: StubVerifier.new(expired)).call(bearer_env)

          assert_equal(200, status)
        end

        def test_missing_required_scope_returns_403_step_up_challenge
          access_token = AccessToken.new(token: "abc", scopes: ["mcp:tools"])
          verifier = StubVerifier.new(access_token)

          status, headers, _body = middleware(token_verifier: verifier, required_scopes: ["mcp:tools", "admin"]).call(bearer_env)

          assert_equal(403, status)

          params = MCP::Client::OAuth::Discovery.parse_www_authenticate(headers["www-authenticate"])

          assert_equal("insufficient_scope", params["error"])
          assert_equal("Token is missing required scopes: admin", params["error_description"])
          assert_equal("mcp:tools admin", params["scope"])
          assert_equal(RESOURCE_METADATA_URL, params["resource_metadata"])
        end

        def test_401_scope_hint_falls_back_to_metadata_scopes_supported
          metadata = ProtectedResourceMetadata.new(
            resource: "https://mcp.example.com/mcp",
            authorization_servers: ["https://as.example.com"],
            scopes_supported: ["mcp:tools", "mcp:resources"],
          )
          middleware = Middleware.new(@app, token_verifier: StubVerifier.new(nil), resource_metadata: metadata)

          _status, headers, _body = middleware.call({})

          params = MCP::Client::OAuth::Discovery.parse_www_authenticate(headers["www-authenticate"])

          assert_equal("mcp:tools mcp:resources", params["scope"])
          assert_equal(metadata.well_known_url, params["resource_metadata"])
        end

        def test_success_stores_access_token_in_env_and_calls_app
          access_token = AccessToken.new(token: "abc", scopes: ["mcp:tools"])
          verifier = StubVerifier.new(access_token)

          status, _headers, _body = middleware(token_verifier: verifier, required_scopes: ["mcp:tools"]).call(bearer_env)

          assert_equal(200, status)
          assert_same(access_token, @app.last_env[OAuth::ENV_KEY])
        end

        def test_bearer_scheme_is_case_insensitive
          access_token = AccessToken.new(token: "abc")

          status, _headers, _body = middleware(token_verifier: StubVerifier.new(access_token)).call({ "HTTP_AUTHORIZATION" => "bearer abc" })

          assert_equal(200, status)
        end

        def test_scope_matcher_can_satisfy_required_scopes_hierarchically
          access_token = AccessToken.new(token: "abc", scopes: ["mcp:all"])
          middleware = Middleware.new(
            @app,
            token_verifier: StubVerifier.new(access_token),
            required_scopes: ["mcp:tools"],
            resource_metadata_url: RESOURCE_METADATA_URL,
            scope_matcher: ->(required_scope, granted_scopes) {
              granted_scopes.include?("mcp:all") || granted_scopes.include?(required_scope)
            },
          )

          status, _headers, _body = middleware.call(bearer_env)

          assert_equal(200, status)
        end

        def test_custom_oauth_error_from_the_verifier_answers_401
          custom_error = Class.new(Error) do
            def initialize(message = "rejected by policy")
              super(message, error_code: "custom_rejection")
            end
          end

          status, headers, _body = middleware(token_verifier: StubVerifier.new(custom_error.new)).call(bearer_env)

          assert_equal(401, status)
          assert_includes(headers["www-authenticate"], 'error="invalid_token"')
          assert_nil(@app.last_env)
        end

        def test_invalid_utf8_bytes_in_the_authorization_header_answer_401
          header = "Bearer abc\xFFdef".dup.force_encoding(Encoding::UTF_8)

          status, headers, _body = middleware(token_verifier: StubVerifier.new(nil)).call({ "HTTP_AUTHORIZATION" => header })

          assert_equal(401, status)
          assert_includes(headers["www-authenticate"], 'error="invalid_token"')
        end

        def test_errors_from_the_wrapped_app_are_not_swallowed
          exploding_app = ->(_env) { raise "downstream failure" }
          middleware = Middleware.new(exploding_app, token_verifier: StubVerifier.new(AccessToken.new(token: "abc")), resource_metadata_url: RESOURCE_METADATA_URL)

          error = assert_raises(RuntimeError) { middleware.call(bearer_env) }

          # Only verification is this middleware's business; the wrapped app's failures reach the app's own error handling.
          assert_equal("downstream failure", error.message)
        end

        def test_verifier_infrastructure_error_returns_500_without_challenge
          verifier = StubVerifier.new(RuntimeError.new("JWKS endpoint down"))
          reported = []
          MCP.stubs(:configuration).returns(
            MCP::Configuration.new(exception_reporter: ->(exception, context) { reported << [exception, context] }),
          )

          status, headers, body = middleware(token_verifier: verifier).call(bearer_env)

          assert_equal(500, status)
          refute(headers.key?("www-authenticate"))
          assert_equal("server_error", JSON.parse(body.join)["error"])
          assert_equal(1, reported.size)
          assert_equal("JWKS endpoint down", reported.first.first.message)
        end

        private

        def middleware(token_verifier:, required_scopes: [])
          Middleware.new(@app, token_verifier: token_verifier, required_scopes: required_scopes, resource_metadata_url: RESOURCE_METADATA_URL)
        end

        def bearer_env
          { "HTTP_AUTHORIZATION" => "Bearer abc" }
        end
      end
    end
  end
end
