# frozen_string_literal: true

require "test_helper"
require "jwt"
require "openssl"
require "base64"
require "open3"
require "webmock/minitest"

module MCP
  class Server
    module OAuth
      class JWTVerifierKeyCompatibilityTest < Minitest::Test
        ISSUER = "https://as.example.com"
        AUDIENCE = "https://mcp.example.com/mcp"
        JWKS_URI = "https://as.example.com/.well-known/jwks.json"
        METADATA = ProtectedResourceMetadata.new(resource: AUDIENCE, authorization_servers: [ISSUER])

        def setup
          @claims = { "iss" => ISSUER, "aud" => AUDIENCE, "exp" => Time.now.to_i + 300 }
        end

        def test_valid_rsa_algorithms_are_accepted
          key = OpenSSL::PKey::RSA.new(2048)
          ["RS256", "RS384", "RS512", "PS256", "PS384", "PS512"].each do |algorithm|
            assert_valid_pair(algorithm, key)
          end
        end

        def test_valid_ec_algorithms_and_curves_are_accepted
          { "ES256" => "prime256v1", "ES384" => "secp384r1", "ES512" => "secp521r1" }.each do |algorithm, curve|
            assert_valid_pair(algorithm, OpenSSL::PKey::EC.generate(curve))
          end
        end

        def test_ec_curve_algorithm_matches_and_mismatches
          { "prime256v1" => "ES256", "secp256r1" => "ES256", "secp384r1" => "ES384", "secp521r1" => "ES512" }.each do |curve, algorithm|
            assert_curve_algorithm(curve, algorithm)
          end
        end

        def test_valid_es256k_pair_is_accepted
          skip "secp256k1 is not available" unless OpenSSL::PKey::EC.builtin_curves.any? { |name, _comment| name == "secp256k1" }

          assert_curve_algorithm("secp256k1", "ES256K")
          assert_valid_pair("ES256K", OpenSSL::PKey::EC.generate("secp256k1"))
        end

        def test_valid_hmac_algorithms_are_accepted
          ["HS256", "HS384", "HS512"].each do |algorithm|
            assert_valid_pair(algorithm, "shared-key" * 8)
          end
        end

        def test_valid_eddsa_key_is_accepted
          require_eddsa
          assert_valid_pair("EdDSA", Ed25519::SigningKey.generate)
        end

        def test_builtin_eddsa_key_is_accepted_without_the_plugin
          script = <<~'RUBY'
            gem "jwt", "= #{ARGV.fetch(0)}"
            require "jwt"
            exit 77 unless defined?(RbNaCl::Signatures::Ed25519::SigningKey)

            require "mcp"
            key = RbNaCl::Signatures::Ed25519::SigningKey.generate
            claims = { iss: "https://as.example.com", aud: "https://mcp.example.com/mcp", exp: Time.now.to_i + 300 }
            token = JWT.encode(claims, key, "EdDSA", { kid: "built-in" })
            jwk = JWT::JWK.new(key.verify_key, { kid: "built-in" }).export
            metadata = MCP::Server::OAuth::ProtectedResourceMetadata.new(
              resource: "https://mcp.example.com/mcp",
              authorization_servers: ["https://as.example.com"],
            )
            [{ key: key.verify_key }, { jwks: { keys: [jwk] } }].each do |source|
              verifier = MCP::Server::OAuth::JWTVerifier.new(resource_metadata: metadata, **source)
              raise "Valid built-in EdDSA token was not returned" unless verifier.verify(token).token == token
            end
            puts "accepted"
          RUBY
          env = { "RUBYOPT" => nil, "BUNDLER_SETUP" => nil, "GEM_PATH" => Gem.path.join(File::PATH_SEPARATOR) }
          lib = File.expand_path("../../../../lib", __dir__)
          version = Gem.loaded_specs.fetch("jwt").version.to_s
          stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-I", lib, "-e", script, version)
          skip "Built-in RbNaCl EdDSA is not available" if status.exitstatus == 77

          assert_predicate(status, :success?, stderr)
          assert_equal("accepted\n", stdout)
        end

        def test_valid_rsa_key_in_an_array_is_accepted
          first = OpenSSL::PKey::RSA.new(2048)
          second = OpenSSL::PKey::RSA.new(2048)
          token = JWT.encode(@claims, second, "RS256")
          verifier = JWTVerifier.new(resource_metadata: METADATA, key: [first.public_key, second.public_key])

          assert_equal(token, verifier.verify(token).token)
        end

        def test_es256_with_an_rsa_key_returns_401
          assert_algorithm_mismatch("ES256", OpenSSL::PKey::RSA.new(2048))
        end

        def test_rs256_with_an_ec_key_returns_401
          assert_algorithm_mismatch("RS256", OpenSSL::PKey::EC.generate("prime256v1"))
        end

        def test_eddsa_with_an_rsa_key_returns_401
          require_eddsa
          assert_algorithm_mismatch("EdDSA", OpenSSL::PKey::RSA.new(2048))
        end

        def test_ec_curve_mismatches_return_401
          { "ES256" => "secp384r1", "ES384" => "prime256v1", "ES512" => "prime256v1" }.each do |algorithm, curve|
            assert_algorithm_mismatch(algorithm, OpenSSL::PKey::EC.generate(curve))
          end
        end

        def test_hs256_with_an_rsa_key_returns_401
          assert_algorithm_mismatch("HS256", OpenSSL::PKey::RSA.new(2048))
        end

        def test_rs256_with_an_oct_jwks_returns_401
          assert_algorithm_mismatch("RS256", "shared-key" * 8, direct: false)
        end

        def test_es256_with_an_oct_jwks_returns_401
          assert_algorithm_mismatch("ES256", "shared-key" * 8, direct: false)
        end

        def test_disallowed_algorithm_does_not_fetch_a_key
          token = JWT.encode(@claims, OpenSSL::PKey::RSA.new(2048), "RS512", { kid: "compat-key" })
          verifier = JWTVerifier.new(resource_metadata: METADATA, jwks_uri: JWKS_URI, algorithms: ["RS256"])

          assert_raises(InvalidTokenError) { verifier.verify(token) }
          assert_not_requested(:get, JWKS_URI)
        end

        private

        def assert_curve_algorithm(curve, algorithm)
          key = OpenSSL::PKey::EC.generate(curve == "secp256r1" ? "prime256v1" : curve)
          if curve == "secp256r1"
            group = key.group
            group.stubs(:curve_name).returns(curve)
            key.stubs(:group).returns(group)
          end
          verifier = JWTVerifier.new(resource_metadata: METADATA, key: key, algorithms: [algorithm])

          assert(verifier.send(:algorithm_matches_key?, algorithm, key), curve)
          (["ES256", "ES384", "ES512", "ES256K"] - [algorithm]).each do |other|
            refute(verifier.send(:algorithm_matches_key?, other, key), "#{curve}: #{other}")
          end
        end

        def assert_valid_pair(algorithm, signing_key)
          jwk = JWT::JWK.new(signing_key, { kid: "compat-key" }).export(include_private: signing_key.is_a?(String))
          key = JWT::JWK.new(jwk).verify_key
          token = JWT.encode(@claims, signing_key, algorithm, { kid: "compat-key", typ: "at+jwt" })

          key_sources(key, jwk).each do |source|
            verifier = JWTVerifier.new(resource_metadata: METADATA, algorithms: [algorithm], **source)

            assert_equal(token, verifier.verify(token).token, "#{algorithm}: #{source.keys}")
          end
        end

        def assert_algorithm_mismatch(algorithm, key, direct: true)
          jwk = JWT::JWK.new(key, { kid: "compat-key" }).export(include_private: key.is_a?(String))
          header = Base64.urlsafe_encode64(JSON.generate(alg: algorithm, kid: "compat-key", typ: "at+jwt"), padding: false)
          payload = Base64.urlsafe_encode64(JSON.generate(@claims), padding: false)
          signature = Base64.urlsafe_encode64("\0" * 64, padding: false)
          token = "#{header}.#{payload}.#{signature}"
          sources = key_sources(key, jwk)
          sources.shift unless direct

          sources.each do |source|
            verifier = JWTVerifier.new(resource_metadata: METADATA, algorithms: [algorithm], **source)
            app = mock
            app.expects(:call).never
            middleware = Middleware.new(app, token_verifier: verifier, resource_metadata: METADATA)
            reports = []
            MCP.configuration.stubs(:exception_reporter).returns(->(error, _context) { reports << error })

            status, headers, body = middleware.call({ "HTTP_AUTHORIZATION" => "Bearer #{token}" })

            assert_equal(401, status, "#{algorithm}: #{source.keys}")
            assert_includes(headers.fetch("www-authenticate"), 'error="invalid_token"')
            assert_equal("invalid_token", JSON.parse(body.join).fetch("error"))
            assert_empty(reports)
          end
        end

        def key_sources(key, jwk)
          jwks = { keys: [jwk] }
          stub_request(:get, JWKS_URI).to_return(body: JSON.generate(jwks), headers: { "content-type" => "application/json" })
          [{ key: key }, { jwks: jwks }, { jwks_uri: JWKS_URI }]
        end

        def require_eddsa
          require "jwt/eddsa"
        rescue LoadError
          skip "jwt-eddsa is not available"
        end
      end
    end
  end
end
