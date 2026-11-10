# frozen_string_literal: true

require "test_helper"
require "jwt"
require "openssl"
require "base64"
require "webmock/minitest"

module MCP
  class Server
    module OAuth
      class JWTVerifierMiddlewareTest < Minitest::Test
        ISSUER = "https://as.example.com"
        AUDIENCE = "https://mcp.example.com/mcp"
        JWKS_URI = "https://as.example.com/.well-known/jwks.json"
        METADATA = ProtectedResourceMetadata.new(resource: AUDIENCE, authorization_servers: [ISSUER])

        def setup
          @key = OpenSSL::PKey::EC.generate("prime256v1")
          @jwks = { keys: [JWT::JWK.new(@key, { kid: "ec-key", use: "sig", alg: "ES256" }).export] }
          @public_key = JWT::JWK.new(@jwks[:keys].first).verify_key
          @claims = { "iss" => ISSUER, "aud" => AUDIENCE, "exp" => Time.now.to_i + 300 }
        end

        def test_ps256_token_with_an_ec_key_returns_401
          assert_ps256_rejected(key: @public_key)
        end

        def test_ps256_token_with_a_static_ec_jwks_returns_401
          assert_ps256_rejected(jwks: @jwks)
        end

        def test_ps256_token_with_a_fetched_ec_jwks_returns_401
          stub_request(:get, JWKS_URI).to_return(body: JSON.generate(@jwks), headers: { "content-type" => "application/json" })

          assert_ps256_rejected(jwks_uri: JWKS_URI)
          assert_requested(:get, JWKS_URI, times: 1)
        end

        private

        def assert_ps256_rejected(**key_source)
          verifier = JWTVerifier.new(resource_metadata: METADATA, **key_source)
          app = mock
          app.expects(:call).once.returns([200, {}, ["authenticated"]])
          middleware = Middleware.new(app, token_verifier: verifier, resource_metadata: METADATA)
          reports = []
          MCP.configuration.stubs(:exception_reporter).returns(->(error, _context) { reports << error })
          valid_token = JWT.encode(@claims, @key, "ES256", { kid: "ec-key" })

          status, = middleware.call({ "HTTP_AUTHORIZATION" => "Bearer #{valid_token}" })

          assert_equal(200, status)

          header = Base64.urlsafe_encode64(JSON.generate(alg: "PS256", kid: "ec-key"), padding: false)
          payload = Base64.urlsafe_encode64(JSON.generate(@claims), padding: false)
          token = "#{header}.#{payload}.AAAA"

          status, headers, body = middleware.call({ "HTTP_AUTHORIZATION" => "Bearer #{token}" })

          assert_equal(401, status)
          assert_includes(headers.fetch("www-authenticate"), 'error="invalid_token"')
          assert_equal("invalid_token", JSON.parse(body.join).fetch("error"))
          assert_empty(reports)
        end
      end
    end
  end
end
