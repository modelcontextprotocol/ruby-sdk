# frozen_string_literal: true

require "base64"
require "json"
require "openssl"
require "securerandom"

module MCP
  class Client
    module OAuth
      # Builds RFC 7523 Section 2.2 JWT client assertions for the `private_key_jwt`
      # client authentication method used by the `client_credentials` grant
      # (MCP extension `io.modelcontextprotocol/oauth-client-credentials`, SEP-1046).
      #
      # The JWS is assembled with openssl so the SDK stays free of a JWT gem dependency
      # (the TypeScript and Python SDKs use jose and PyJWT for the same assertion).
      # Claims follow SEP-1046 and RFC 7523: `iss` and `sub` carry the client_id,
      # `aud` carries the authorization server's issuer identifier, plus `exp`, `iat`,
      # and a unique `jti`.
      #
      # - https://github.com/modelcontextprotocol/modelcontextprotocol/issues/1046
      # - https://www.rfc-editor.org/rfc/rfc7523#section-2.2
      module JWTClientAssertion
        # Raised when `signing_algorithm` is not supported.
        class UnsupportedAlgorithmError < ArgumentError; end

        # Raised when the private key cannot be parsed or does not match
        # the requested signing algorithm (e.g. an RSA key with ES256).
        class InvalidKeyError < ArgumentError; end

        # RFC 7523 Section 2.2 `client_assertion_type` value.
        ASSERTION_TYPE = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

        # Assertion lifetime in seconds; matches the TypeScript SDK's `jwtLifetimeSeconds`
        # and the Python SDK's `lifetime_seconds` default.
        DEFAULT_LIFETIME = 300

        # ES256 produces a raw `r || s` JWS signature of two 32-byte integers.
        ES256_COMPONENT_BYTES = 32
        private_constant :ES256_COMPONENT_BYTES

        SUPPORTED_ALGORITHMS = ["ES256", "RS256"].freeze

        class << self
          # Returns a signed compact-serialization JWT (`header.payload.signature`).
          #
          # @param client_id [String] The pre-registered OAuth client identifier.
          # @param audience [String] The authorization server's issuer identifier.
          # @param private_key [String, OpenSSL::PKey::PKey] PEM string (PKCS#8 or
          #   traditional encoding) or an already-parsed key.
          # @param signing_algorithm [String] `"ES256"` (prime256v1 EC key) or
          #   `"RS256"` (RSA key).
          # @param lifetime [Integer] Seconds until the `exp` claim expires.
          def generate(client_id:, audience:, private_key:, signing_algorithm:, lifetime: DEFAULT_LIFETIME)
            unless SUPPORTED_ALGORITHMS.include?(signing_algorithm)
              raise UnsupportedAlgorithmError,
                "signing_algorithm must be one of #{SUPPORTED_ALGORITHMS.inspect} (got #{signing_algorithm.inspect})."
            end

            key = parse_key(private_key)
            validate_key!(key, signing_algorithm)

            now = Time.now.to_i
            header = { alg: signing_algorithm, typ: "JWT" }
            claims = {
              iss: client_id,
              sub: client_id,
              aud: audience,
              exp: now + lifetime,
              iat: now,
              jti: SecureRandom.uuid,
            }

            signing_input = "#{base64url(JSON.generate(header))}.#{base64url(JSON.generate(claims))}"
            "#{signing_input}.#{base64url(sign(key, signing_algorithm, signing_input))}"
          end

          private

          def parse_key(private_key)
            return private_key if private_key.is_a?(OpenSSL::PKey::PKey)

            OpenSSL::PKey.read(private_key.to_s)
          rescue OpenSSL::PKey::PKeyError => e
            raise InvalidKeyError, "private_key could not be parsed as a PEM-encoded key: #{e.message}."
          end

          def validate_key!(key, signing_algorithm)
            case signing_algorithm
            when "ES256"
              unless key.is_a?(OpenSSL::PKey::EC) && key.group.curve_name == "prime256v1"
                raise InvalidKeyError, "ES256 requires an EC private key on the prime256v1 (P-256) curve."
              end
            when "RS256"
              unless key.is_a?(OpenSSL::PKey::RSA)
                raise InvalidKeyError, "RS256 requires an RSA private key."
              end
            end

            return if key.private?

            raise InvalidKeyError, "private_key must contain the private component to sign assertions."
          end

          def sign(key, signing_algorithm, signing_input)
            der = key.sign(OpenSSL::Digest.new("SHA256"), signing_input)
            return der unless signing_algorithm == "ES256"

            ecdsa_der_to_raw(der)
          end

          # `OpenSSL::PKey::EC#sign` returns an ASN.1 DER `SEQUENCE { r, s }`,
          # while JWS ES256 (RFC 7518 Section 3.4) requires the raw 64-byte
          # `r || s` concatenation with each integer left-padded to 32 bytes.
          def ecdsa_der_to_raw(der)
            OpenSSL::ASN1.decode(der).value.map do |integer|
              integer.value.to_s(16).rjust(ES256_COMPONENT_BYTES * 2, "0")
            end.join.then { |hex| [hex].pack("H*") }
          end

          def base64url(data)
            Base64.urlsafe_encode64(data, padding: false)
          end
        end
      end
    end
  end
end
