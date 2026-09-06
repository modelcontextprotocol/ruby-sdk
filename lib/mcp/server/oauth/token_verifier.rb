# frozen_string_literal: true

require_relative "access_token"
require_relative "errors"

module MCP
  class Server
    module OAuth
      # The single integration point of the resource-server role: token in, `AccessToken` out. `Authenticator` accepts any object
      # that responds to `verify(token)`, so subclassing is optional; this base class documents the contract and shares the claim mapping
      # used by the built-in verifiers.
      #
      # Implementations MUST raise `InvalidTokenError` when the token is invalid, and that includes an expired token: expiry enforcement
      # is part of this contract, not something the caller re-checks (the built-in verifiers honor their configured clock leeway when doing so).
      # Returning nil is also treated as a rejection by `Authenticator`, with a generic message. Any other exception is treated as
      # an internal error (HTTP 500), not as a client failure.
      #
      # Error messages are echoed into the `WWW-Authenticate` response header, so they must never contain token material or other secrets.
      class TokenVerifier
        # Upper bound for response bodies read from authorization-server endpoints (JWKS, introspection). Matches the bound the client-side
        # OAuth support applies to authorization-server responses; the documents involved are orders of magnitude smaller.
        MAX_UPSTREAM_RESPONSE_BYTES = 4 * 1024 * 1024

        # @param token [String] the raw bearer token from the `Authorization` header
        # @return [AccessToken]
        # @raise [InvalidTokenError] when the token is invalid, expired, or not meant for this resource
        def verify(token)
          raise NotImplementedError, "#{self.class.name}#verify is not implemented"
        end

        private

        # Guards an expected `iss` or `aud` value at construction. The built-in verifiers compare tokens against these values,
        # and a nil or empty expectation would silently turn the comparison off (the jwt gem skips a check whose expected value is nil),
        # so a misconfiguration such as an unset environment variable fails loudly instead.
        def require_expected_claim!(name, value)
          return if value.is_a?(String) && !value.empty?

          claim = name == :issuer ? "iss" : "aud"

          raise ArgumentError, "#{name} must be a non-empty String (got #{value.inspect}); without it the #{claim} check would be skipped"
        end

        # The expected `aud` is the RFC 9728 document's `resource`: the canonical URL tokens are issued for, and the one this server publishes,
        # so the verifier cannot drift from it.
        def resource_from(resource_metadata)
          metadata_member(resource_metadata, :resource)
        end

        # The expected `iss` comes from the document as well: its authorization servers are issuer identifiers (RFC 9728),
        # and a JWT verifier holds one key set, so it verifies the tokens of exactly one of them. A document naming several
        # would advertise an authorization server whose tokens this verifier rejects, so it is refused outright.
        def issuer_from(resource_metadata)
          servers = metadata_member(resource_metadata, :authorization_servers)
          return servers.first if servers.one?

          raise ArgumentError, <<~MESSAGE
            JWTVerifier verifies the tokens of one authorization server, and resource_metadata names \
            #{servers.size}; publish one, or verify with a custom verifier that holds each issuer's keys
          MESSAGE
        end

        # A document standing in for `ProtectedResourceMetadata` must still hand over the shapes that class guarantees,
        # so a wrong one fails here with a named member rather than deeper in with a `NoMethodError`.
        def metadata_member(resource_metadata, name)
          unless resource_metadata.respond_to?(name)
            raise ArgumentError, "resource_metadata must be a ProtectedResourceMetadata (got #{resource_metadata.class})"
          end

          value = resource_metadata.public_send(name)
          shape = name == :resource ? "a String" : "an Array of Strings"
          valid = name == :resource ? value.is_a?(String) : value.is_a?(Array) && value.all?(String)
          raise ArgumentError, "resource_metadata.#{name} must be #{shape} (got #{value.inspect})" unless valid

          value
        end

        # Maps a string-keyed claims Hash (JWT payload or RFC 7662 introspection response; the relevant claim names are identical) to an `AccessToken`.
        def access_token_from_claims(token, claims, resource: nil)
          AccessToken.new(
            token: token,
            client_id: claims["client_id"] || claims["azp"],
            scopes: scopes_from_claims(claims),
            expires_at: expiry_from_claims(claims),
            subject: claims["sub"],
            issuer: claims["iss"],
            audience: claims["aud"],
            resource: resource,
            claims: claims,
          )
        end

        # RFC 8693 style `scope` is a space-delimited string, but some authorization servers emit an array of scope strings instead.
        def scopes_from_claims(claims)
          scope = claims["scope"]

          scope.is_a?(Array) ? scope.map(&:to_s) : scope.to_s.split
        end

        # `exp` is a numeric timestamp in a JWT payload and in an introspection response alike, but a lenient authorization server may emit it as
        # a numeric string. Any other shape is rejected as an invalid token: passed through, it would make `AccessToken#expired?` raise on comparison
        # and turn a malformed upstream response into an internal error.
        def expiry_from_claims(claims)
          exp = claims["exp"]

          case exp
          when nil
            nil
          when Numeric
            # JSON parses `1e1000` to Infinity, whose `to_i` raises.
            raise InvalidTokenError, "Malformed exp claim" unless exp.finite?

            exp.to_i
          when /\A\d+\z/
            exp.to_i
          else
            raise InvalidTokenError, "Malformed exp claim"
          end
        end

        def require_non_negative_number!(name, value)
          return if value.is_a?(Numeric) && value.finite? && value >= 0

          raise ArgumentError, "#{name} must be a non-negative finite number (got #{value.inspect})"
        end

        def require_positive_number!(name, value)
          return if value.is_a?(Numeric) && value.finite? && value.positive?

          raise ArgumentError, "#{name} must be a positive finite number (got #{value.inspect})"
        end
      end
    end
  end
end
