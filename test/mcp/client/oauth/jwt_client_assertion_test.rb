# frozen_string_literal: true

require "test_helper"
require "mcp/client/oauth"

module MCP
  class Client
    module OAuth
      class JWTClientAssertionTest < Minitest::Test
        ES256_COMPONENT_BYTES = 32

        # `OpenSSL::PKey::EC.generate` only exists from the openssl gem 2.2 (Ruby 3.0),
        # while `EC#generate_key` raises on openssl 3.0+ where PKey objects are immutable,
        # so branch on availability to keep CI green on every supported Ruby.
        def generate_ec_key(curve)
          if OpenSSL::PKey::EC.respond_to?(:generate)
            OpenSSL::PKey::EC.generate(curve)
          else
            OpenSSL::PKey::EC.new(curve).tap(&:generate_key)
          end
        end

        def es256_key
          @es256_key ||= generate_ec_key("prime256v1")
        end

        def rs256_key
          @rs256_key ||= OpenSSL::PKey::RSA.new(2048)
        end

        def generate(private_key: es256_key, signing_algorithm: "ES256", **kwargs)
          JWTClientAssertion.generate(
            client_id: "cc-client",
            audience: "https://auth.example.com",
            private_key: private_key,
            signing_algorithm: signing_algorithm,
            **kwargs,
          )
        end

        def decode_segment(segment)
          JSON.parse(Base64.urlsafe_decode64(segment + "=" * (-segment.length % 4)))
        end

        # JWS ES256 signatures are the raw 64-byte `r || s` concatenation;
        # OpenSSL verifies the ASN.1 DER form, so convert back for verification.
        def ecdsa_raw_to_der(raw)
          r = OpenSSL::BN.new(raw[0, ES256_COMPONENT_BYTES], 2)
          s = OpenSSL::BN.new(raw[ES256_COMPONENT_BYTES, ES256_COMPONENT_BYTES], 2)
          OpenSSL::ASN1::Sequence.new([OpenSSL::ASN1::Integer.new(r), OpenSSL::ASN1::Integer.new(s)]).to_der
        end

        def test_generate_builds_compact_jws_with_rfc7523_claims
          before = Time.now.to_i
          assertion = generate
          after = Time.now.to_i

          header_segment, payload_segment, _signature_segment = assertion.split(".")
          header = decode_segment(header_segment)
          claims = decode_segment(payload_segment)

          assert_equal({ "alg" => "ES256", "typ" => "JWT" }, header)
          assert_equal("cc-client", claims["iss"])
          assert_equal("cc-client", claims["sub"])
          assert_equal("https://auth.example.com", claims["aud"])
          assert_includes(before..after, claims["iat"])
          assert_equal(claims["iat"] + JWTClientAssertion::DEFAULT_LIFETIME, claims["exp"])
          refute_empty(claims["jti"])
        end

        def test_generate_uses_unpadded_base64url_segments
          assertion = generate

          segments = assertion.split(".")
          assert_equal(3, segments.size)
          segments.each do |segment|
            refute_match(%r{[+/=]}, segment, "JWS segments must be unpadded base64url")
          end
        end

        def test_generate_es256_signature_verifies_with_the_public_key
          assertion = generate

          header_segment, payload_segment, signature_segment = assertion.split(".")
          raw_signature = Base64.urlsafe_decode64(signature_segment + "=" * (-signature_segment.length % 4))

          assert_equal(ES256_COMPONENT_BYTES * 2, raw_signature.bytesize)
          assert(
            es256_key.verify(
              OpenSSL::Digest.new("SHA256"),
              ecdsa_raw_to_der(raw_signature),
              "#{header_segment}.#{payload_segment}",
            ),
            "ES256 signature must verify against the signing input",
          )
        end

        def test_generate_rs256_signature_verifies_with_the_public_key
          assertion = generate(private_key: rs256_key, signing_algorithm: "RS256")

          header_segment, payload_segment, signature_segment = assertion.split(".")
          signature = Base64.urlsafe_decode64(signature_segment + "=" * (-signature_segment.length % 4))

          assert_equal("RS256", decode_segment(header_segment)["alg"])
          assert(rs256_key.verify(OpenSSL::Digest.new("SHA256"), signature, "#{header_segment}.#{payload_segment}"))
        end

        def test_generate_accepts_pem_encoded_private_key
          assertion = generate(private_key: es256_key.to_pem)

          refute_empty(assertion)
        end

        def test_generate_honors_lifetime_override
          assertion = generate(lifetime: 60)

          claims = decode_segment(assertion.split(".")[1])
          assert_equal(claims["iat"] + 60, claims["exp"])
        end

        def test_generate_uses_a_unique_jti_per_assertion
          jtis = Array.new(2) { decode_segment(generate.split(".")[1])["jti"] }

          refute_equal(jtis[0], jtis[1])
        end

        def test_generate_rejects_unsupported_algorithm
          assert_raises(JWTClientAssertion::UnsupportedAlgorithmError) do
            generate(signing_algorithm: "HS256")
          end
        end

        def test_generate_rejects_key_algorithm_mismatch
          assert_raises(JWTClientAssertion::InvalidKeyError) do
            generate(private_key: rs256_key, signing_algorithm: "ES256")
          end

          assert_raises(JWTClientAssertion::InvalidKeyError) do
            generate(private_key: es256_key, signing_algorithm: "RS256")
          end
        end

        def test_generate_rejects_ec_key_on_the_wrong_curve
          assert_raises(JWTClientAssertion::InvalidKeyError) do
            generate(private_key: generate_ec_key("secp384r1"), signing_algorithm: "ES256")
          end
        end

        def test_generate_rejects_unparseable_pem
          assert_raises(JWTClientAssertion::InvalidKeyError) do
            generate(private_key: "not a pem")
          end
        end

        def test_generate_rejects_public_only_key
          # `RSA#public_key` is available on every supported openssl version,
          # unlike `public_to_pem` (openssl 3.0+), so the public-only check is
          # exercised with an RSA key.
          assert_raises(JWTClientAssertion::InvalidKeyError) do
            generate(private_key: rs256_key.public_key, signing_algorithm: "RS256")
          end
        end
      end
    end
  end
end
