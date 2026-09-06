# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

module MCP
  class Server
    module OAuth
      class IntrospectionVerifierTest < Minitest::Test
        ENDPOINT = "https://as.example.com/oauth/introspect"
        AUDIENCE = "https://mcp.example.com/mcp"
        METADATA = ProtectedResourceMetadata.new(resource: AUDIENCE, authorization_servers: ["https://as.example.com"])

        def test_verifies_an_active_token_and_maps_fields
          stub_introspection(
            "active" => true,
            "client_id" => "client-1",
            "scope" => "mcp:tools mcp:resources",
            "exp" => Time.now.to_i + 3600,
            "sub" => "user-1",
            "iss" => "https://as.example.com",
            "aud" => AUDIENCE,
          )

          access_token = verifier.verify("opaque-token")

          assert_equal("opaque-token", access_token.token)
          assert_equal("client-1", access_token.client_id)
          assert_equal(["mcp:tools", "mcp:resources"], access_token.scopes)
          assert_equal("user-1", access_token.subject)
          assert_equal("https://as.example.com", access_token.issuer)
          assert_equal(AUDIENCE, access_token.audience)
          assert_equal(AUDIENCE, access_token.resource)
        end

        def test_maps_an_array_valued_scope_claim
          stub_introspection("active" => true, "aud" => AUDIENCE, "scope" => ["mcp:tools", "mcp:resources"])

          assert_equal(["mcp:tools", "mcp:resources"], verifier.verify("opaque-token").scopes)
        end

        def test_sends_token_with_basic_client_authentication
          stub_introspection("active" => true, "aud" => AUDIENCE)

          verifier.verify("opaque-token")

          assert_requested(:post, ENDPOINT) do |request|
            credentials = Base64.strict_encode64("rs-client:rs-secret")

            request.headers["Authorization"] == "Basic #{credentials}" && URI.decode_www_form(request.body).to_h == { "token" => "opaque-token" }
          end
        end

        def test_sends_client_credentials_in_body_with_post_authentication
          stub_introspection("active" => true, "aud" => AUDIENCE)

          verifier(client_auth_method: :client_secret_post).verify("opaque-token")

          assert_requested(:post, ENDPOINT) do |request|
            form = URI.decode_www_form(request.body).to_h

            request.headers["Authorization"].nil? && form == { "token" => "opaque-token", "client_id" => "rs-client", "client_secret" => "rs-secret" }
          end
        end

        def test_basic_client_authentication_form_encodes_the_credentials
          stub_introspection("active" => true, "aud" => AUDIENCE)

          verifier(client_id: "rs:client/1", client_secret: "s e%cret").verify("opaque-token")

          assert_requested(:post, ENDPOINT) do |request|
            # RFC 6749 Section 2.3.1: each half is form-urlencoded before the pair is base64-encoded, so the `:` in the id survives.
            credentials = ["rs%3Aclient%2F1:s+e%25cret"].pack("m0")

            request.headers["Authorization"] == "Basic #{credentials}"
          end
        end

        def test_none_authentication_sends_only_the_token
          stub_introspection("active" => true, "aud" => AUDIENCE)

          verifier(client_auth_method: :none, client_id: nil, client_secret: nil).verify("opaque-token")

          assert_requested(:post, ENDPOINT) do |request|
            request.headers["Authorization"].nil? && URI.decode_www_form(request.body).to_h == { "token" => "opaque-token" }
          end
        end

        def test_rejects_inactive_token
          stub_introspection("active" => false)

          error = assert_raises(InvalidTokenError) { verifier.verify("opaque-token") }

          assert_equal("Token is not active", error.message)
        end

        def test_rejects_response_without_active_field
          stub_introspection("client_id" => "client-1")

          assert_raises(InvalidTokenError) { verifier.verify("opaque-token") }
        end

        def test_rejects_audience_mismatch
          stub_introspection("active" => true, "aud" => "https://other.example.com")

          error = assert_raises(InvalidTokenError) { verifier.verify("opaque-token") }

          assert_equal("Invalid audience", error.message)
        end

        def test_accepts_audience_in_aud_array
          stub_introspection("active" => true, "aud" => ["https://other.example.com", AUDIENCE])

          assert_equal(["https://other.example.com", AUDIENCE], verifier.verify("opaque-token").audience)
        end

        def test_accepts_audience_in_resource_member
          stub_introspection("active" => true, "resource" => AUDIENCE)

          assert_equal(AUDIENCE, verifier.verify("opaque-token").resource)
        end

        def test_rejects_active_response_without_audience_when_audience_configured
          stub_introspection("active" => true)

          error = assert_raises(InvalidTokenError) { verifier.verify("opaque-token") }

          assert_equal("Invalid audience", error.message)
        end

        def test_requires_the_resource_metadata_document
          [nil, "", :metadata, 42, { resource: AUDIENCE }].each do |metadata|
            error = assert_raises(ArgumentError, metadata.inspect) do
              IntrospectionVerifier.new(introspection_endpoint: ENDPOINT, client_id: "c", resource_metadata: metadata)
            end

            assert_includes(error.message, "resource_metadata must be a ProtectedResourceMetadata")
          end
        end

        def test_takes_the_audience_from_the_resource_metadata
          stub_introspection("active" => true, "aud" => AUDIENCE)

          assert_equal(AUDIENCE, verifier.verify("opaque-token").resource)
        end

        def test_rejects_expired_token_by_exp
          stub_introspection("active" => true, "aud" => AUDIENCE, "exp" => Time.now.to_i - 60)

          error = assert_raises(InvalidTokenError) { verifier.verify("opaque-token") }

          assert_equal("Token expired", error.message)
        end

        def test_rejects_a_malformed_exp_member_as_an_invalid_token
          stub_introspection("active" => true, "aud" => AUDIENCE, "exp" => "next week")

          error = assert_raises(InvalidTokenError) { verifier.verify("opaque-token") }

          assert_equal("Malformed exp claim", error.message)
        end

        def test_rejects_a_non_finite_exp_member_as_an_invalid_token
          # JSON parses `1e1000` to Infinity, whose `to_i` would raise instead of failing the token.
          stub_request(:post, ENDPOINT).to_return(
            status: 200,
            body: %({"active":true,"aud":"#{AUDIENCE}","exp":1e1000}),
            headers: { "Content-Type" => "application/json" },
          )

          error = assert_raises(InvalidTokenError) { verifier.verify("opaque-token") }

          assert_equal("Malformed exp claim", error.message)
        end

        def test_requires_positive_finite_timeouts
          [{ open_timeout: 0 }, { read_timeout: Float::INFINITY }].each do |option|
            assert_raises(ArgumentError, option.inspect) do
              IntrospectionVerifier.new(introspection_endpoint: ENDPOINT, client_id: "c", resource_metadata: METADATA, **option)
            end
          end
        end

        def test_accepts_a_numeric_string_exp_member
          stub_introspection("active" => true, "aud" => AUDIENCE, "exp" => (Time.now.to_i + 3600).to_s)

          access_token = verifier.verify("opaque-token")

          assert_kind_of(Integer, access_token.expires_at)
          refute_predicate(access_token, :expired?)
        end

        def test_endpoint_error_is_not_an_invalid_token_error
          stub_request(:post, ENDPOINT).to_return(status: 503)

          error = assert_raises(IntrospectionVerifier::IntrospectionError) { verifier.verify("opaque-token") }

          assert_equal("Introspection endpoint responded with status 503", error.message)
        end

        def test_invalid_json_is_not_an_invalid_token_error
          stub_request(:post, ENDPOINT).to_return(status: 200, body: "not json")

          assert_raises(IntrospectionVerifier::IntrospectionError) { verifier.verify("opaque-token") }
        end

        def test_rejects_non_object_json_response
          stub_request(:post, ENDPOINT).to_return(status: 200, body: "[]")

          error = assert_raises(IntrospectionVerifier::IntrospectionError) { verifier.verify("opaque-token") }

          assert_equal("Introspection endpoint returned a non-object JSON document", error.message)
        end

        def test_rejects_oversized_response_body
          stub_request(:post, ENDPOINT).to_return(
            status: 200,
            body: "a" * (TokenVerifier::MAX_UPSTREAM_RESPONSE_BYTES + 1),
          )

          error = assert_raises(IntrospectionVerifier::IntrospectionError) { verifier.verify("opaque-token") }

          assert_includes(error.message, "Introspection response exceeded")
        end

        def test_timeout_propagates_as_infrastructure_error
          stub_request(:post, ENDPOINT).to_timeout

          assert_raises(Errno::ETIMEDOUT, Net::OpenTimeout) { verifier.verify("opaque-token") }
        end

        def test_rejects_non_loopback_http_endpoint
          error = assert_raises(ArgumentError) do
            IntrospectionVerifier.new(
              introspection_endpoint: "http://as.example.com/introspect",
              client_id: "c",
              resource_metadata: METADATA,
            )
          end

          assert_includes(error.message, "introspection_endpoint must use https")
        end

        def test_allows_loopback_http_endpoint
          verifier = IntrospectionVerifier.new(
            introspection_endpoint: "http://localhost:9000/introspect",
            client_auth_method: :none,
            resource_metadata: METADATA,
          )

          stub_request(:post, "http://localhost:9000/introspect").to_return(
            status: 200,
            body: JSON.generate("active" => true, "aud" => AUDIENCE),
            headers: { "Content-Type" => "application/json" },
          )

          assert_equal("opaque-token", verifier.verify("opaque-token").token)
        end

        def test_rejects_unknown_client_auth_method
          error = assert_raises(ArgumentError) do
            IntrospectionVerifier.new(introspection_endpoint: ENDPOINT, client_id: "c", client_auth_method: :jwt, resource_metadata: METADATA)
          end

          assert_includes(error.message, "client_auth_method must be one of")
        end

        def test_requires_client_id_unless_none
          error = assert_raises(ArgumentError) do
            IntrospectionVerifier.new(introspection_endpoint: ENDPOINT, resource_metadata: METADATA)
          end

          assert_includes(error.message, "client_id is required")
        end

        private

        def verifier(client_auth_method: :client_secret_basic, client_id: "rs-client", client_secret: "rs-secret", resource_metadata: METADATA)
          IntrospectionVerifier.new(
            introspection_endpoint: ENDPOINT,
            client_id: client_id,
            client_secret: client_secret,
            client_auth_method: client_auth_method,
            resource_metadata: resource_metadata,
          )
        end

        def stub_introspection(response_body)
          stub_request(:post, ENDPOINT).to_return(
            status: 200,
            body: JSON.generate(response_body),
            headers: { "Content-Type" => "application/json" },
          )
        end
      end
    end
  end
end
