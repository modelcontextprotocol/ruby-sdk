# frozen_string_literal: true

require "test_helper"
require "mcp/client/oauth/discovery"

module MCP
  class Server
    module OAuth
      class AuthenticatorTest < Minitest::Test
        RESOURCE_METADATA_URL = "https://mcp.example.com/.well-known/oauth-protected-resource/mcp"

        class StubVerifier
          def initialize(result)
            @result = result
          end

          def verify(_token)
            @result
          end
        end

        def test_authenticate_returns_the_verified_access_token
          access_token = AccessToken.new(token: "abc", scopes: ["mcp:tools"])

          result = authenticator(token_verifier: StubVerifier.new(access_token)).authenticate(bearer_env)

          assert_same(access_token, result)
        end

        def test_authenticate_attaches_the_scope_matcher_to_the_token
          access_token = AccessToken.new(token: "abc", scopes: ["mcp:all"])
          matcher = ->(required, granted) { granted.include?("mcp:all") || granted.include?(required) }

          result = authenticator(token_verifier: StubVerifier.new(access_token), required_scopes: ["mcp:tools"], scope_matcher: matcher).authenticate(bearer_env)

          # The gate accepted `mcp:all` for `mcp:tools`; the token handed to handlers must judge scopes the same way.
          assert(result.scope?("mcp:tools"))
          refute(access_token.scope?("mcp:tools"))
        end

        def test_scope_matcher_leaves_a_duck_typed_result_to_its_own_scope_check
          duck = Object.new
          duck.define_singleton_method(:scope?) { |scope| scope == "mcp:tools" }
          matcher = ->(_required, _granted) { raise "the matcher must not be consulted without a scopes list" }

          result = authenticator(token_verifier: StubVerifier.new(duck), required_scopes: ["mcp:tools"], scope_matcher: matcher).authenticate(bearer_env)

          assert_same(duck, result)
        end

        def test_nil_required_scopes_means_no_scope_requirement
          access_token = AccessToken.new(token: "abc")

          result = authenticator(token_verifier: StubVerifier.new(access_token), required_scopes: nil).authenticate(bearer_env)

          assert_same(access_token, result)
        end

        def test_missing_authorization_header_raises_missing_token_error
          error = assert_raises(MissingTokenError) do
            authenticator(token_verifier: StubVerifier.new(nil)).authenticate({})
          end

          assert_equal("Missing Authorization header", error.message)
        end

        def test_token_over_the_maximum_length_is_rejected_before_verification
          verifier = mock
          verifier.expects(:verify).never
          oversized_token = "a" * (Authenticator::MAX_TOKEN_BYTES + 1)

          error = assert_raises(InvalidTokenError) do
            authenticator(token_verifier: verifier).authenticate({ "HTTP_AUTHORIZATION" => "Bearer #{oversized_token}" })
          end

          assert_equal("Token exceeds the maximum accepted length", error.message)
        end

        def test_token_at_the_maximum_length_is_verified
          access_token = AccessToken.new(token: "abc")
          token = "a" * Authenticator::MAX_TOKEN_BYTES

          result = authenticator(token_verifier: StubVerifier.new(access_token)).authenticate({ "HTTP_AUTHORIZATION" => "Bearer #{token}" })

          assert_same(access_token, result)
        end

        def test_insufficient_scope_challenge_uses_the_operation_scopes
          challenge = authenticator(
            token_verifier: StubVerifier.new(nil), required_scopes: ["mcp:base"]
          ).challenge_response(InsufficientScopeError.new(required_scopes: ["mcp:admin"]))

          status, headers, _body = challenge

          assert_equal(403, status)

          params = MCP::Client::OAuth::Discovery.parse_www_authenticate(headers["www-authenticate"])

          # The 2026-07-28 authorization spec scopes the challenge to the failing operation, not to everything the endpoint could ever require.
          assert_equal("mcp:admin", params["scope"])
        end

        def test_insufficient_scope_challenge_falls_back_to_required_scopes
          challenge = authenticator(token_verifier: StubVerifier.new(nil), required_scopes: ["mcp:base"]).challenge_response(InsufficientScopeError.new)

          _status, headers, _body = challenge
          params = MCP::Client::OAuth::Discovery.parse_www_authenticate(headers["www-authenticate"])

          assert_equal("mcp:base", params["scope"])
        end

        def test_scope_hint_never_advertises_offline_access
          challenge = authenticator(
            token_verifier: StubVerifier.new(nil), required_scopes: ["offline_access", "mcp:tools"]
          ).challenge_response(InvalidTokenError.new)

          _status, headers, _body = challenge
          params = MCP::Client::OAuth::Discovery.parse_www_authenticate(headers["www-authenticate"])

          assert_equal("mcp:tools", params["scope"])
        end

        def test_challenge_response_answers_other_oauth_errors_as_invalid_tokens
          custom_error = Class.new(Error) do
            def initialize(message = "rejected by policy")
              super(message, error_code: "custom_rejection")
            end
          end

          status, headers, _body = authenticator(token_verifier: StubVerifier.new(nil)).challenge_response(custom_error.new)

          assert_equal(401, status)

          params = MCP::Client::OAuth::Discovery.parse_www_authenticate(headers["www-authenticate"])

          assert_equal("invalid_token", params["error"])
          assert_equal("rejected by policy", params["error_description"])
        end

        def test_a_custom_error_subclass_needs_no_error_code_keyword
          # A verifier that subclasses `Error` without its own initializer must be raisable the ordinary way.
          # Without a default the missing keyword would raise `ArgumentError` inside `verify`, which the transport
          # reports as HTTP 500 instead of answering the challenge below.
          custom_error = Class.new(Error)
          raised = assert_raises(custom_error) { raise custom_error, "rejected by policy" }

          assert_equal("invalid_token", raised.error_code)

          status, headers, _body = authenticator(token_verifier: StubVerifier.new(nil)).challenge_response(raised)

          assert_equal(401, status)

          params = MCP::Client::OAuth::Discovery.parse_www_authenticate(headers["www-authenticate"])

          assert_equal("invalid_token", params["error"])
          assert_equal("rejected by policy", params["error_description"])
        end

        def test_invalid_utf8_bytes_in_the_header_reach_the_verifier_as_a_token
          verifier = mock
          verifier.expects(:verify).with { |token| token.b == "abc\xFFdef".b }.returns(nil)
          header = "Bearer abc\xFFdef".dup.force_encoding(Encoding::UTF_8)

          assert_raises(InvalidTokenError) do
            authenticator(token_verifier: verifier).authenticate({ "HTTP_AUTHORIZATION" => header })
          end
        end

        def test_challenge_response_rejects_unexpected_error_classes
          assert_raises(ArgumentError) do
            authenticator(token_verifier: StubVerifier.new(nil)).challenge_response(RuntimeError.new)
          end
        end

        private

        def authenticator(token_verifier:, required_scopes: [], scope_matcher: nil)
          Authenticator.new(token_verifier: token_verifier, required_scopes: required_scopes, resource_metadata_url: RESOURCE_METADATA_URL, scope_matcher: scope_matcher)
        end

        def bearer_env
          { "HTTP_AUTHORIZATION" => "Bearer abc" }
        end
      end
    end
  end
end
