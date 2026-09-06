# frozen_string_literal: true

module MCP
  class Server
    module OAuth
      # The result of a successful token verification: the resource-server-side view of an access token.
      # Instances are produced by a `TokenVerifier` and reach tool/prompt/resource handlers as `server_context.auth_info`.
      #
      # The field set is the union of what the official SDKs converged on (Python `AccessToken` and TypeScript `AuthInfo`):
      #
      # - `token` - the raw bearer token as presented by the client
      # - `client_id` - the OAuth client the token was issued to
      # - `scopes` - granted scopes as an array of strings
      # - `expires_at` - expiry as an Integer unix timestamp, or nil when the token does not expire
      # - `subject` - the end user (`sub` claim), when known
      # - `issuer` - the authorization server that issued the token (`iss` claim)
      # - `audience` - the raw `aud` value (String or Array), when known
      # - `resource` - the canonical RFC 8707 resource identifier the verifier matched the token against,
      #   useful for tenancy checks inside handlers
      # - `claims` - the full claim/introspection-response Hash for anything not covered by the named fields
      class AccessToken
        attr_reader :token, :client_id, :scopes, :expires_at, :subject, :issuer, :audience, :resource, :claims

        def initialize(token:, client_id: nil, scopes: [], expires_at: nil, subject: nil, issuer: nil, audience: nil, resource: nil, claims: {})
          @token = token
          @client_id = client_id
          @scopes = scopes
          @expires_at = expires_at
          @subject = subject
          @issuer = issuer
          @audience = audience
          @resource = resource
          @claims = claims
          @scope_matcher = nil
        end

        # Per RFC 7519 Section 4.1.4, a token must not be accepted on or after its expiry time.
        # Tokens without an expiry never count as expired here; verifiers that require an expiry must enforce that themselves
        # (`JWTVerifier` does, the TypeScript SDK rejects such tokens outright, and Python accepts them like this class —
        # the divergence is deliberate: opaque-token verifiers may have no expiry to report even though the authorization server enforces one).
        def expired?(now: Time.now.to_i)
          return false if expires_at.nil?

          expires_at <= now
        end

        # Whether the token grants `scope`: exact membership by default. When the authenticator attached its `scope_matcher:`
        # (see `with_scope_matcher`), that callable decides instead, so a hierarchical scope scheme is honored the same way
        # at the endpoint gate and inside handlers via `require_scopes!`.
        def scope?(scope)
          return scopes.include?(scope.to_s) if @scope_matcher.nil?

          !!@scope_matcher.call(scope.to_s, scopes)
        end

        # A copy of this token whose `scope?` consults `matcher`, a `(required_scope, granted_scopes) -> Boolean` callable.
        # The receiver is left untouched; a nil matcher returns the receiver itself.
        def with_scope_matcher(matcher)
          return self if matcher.nil?

          dup.tap { |copy| copy.scope_matcher = matcher }
        end

        # Mirrors `to_h`: the default `inspect` would print `@token`, leaking the credential into exception reports and debug output.
        def inspect
          "#<#{self.class.name} #{to_h.inspect}>"
        end

        # Omits `token` so the result is safe to log without leaking the credential.
        def to_h
          {
            client_id: client_id,
            scopes: scopes,
            expires_at: expires_at,
            subject: subject,
            issuer: issuer,
            audience: audience,
            resource: resource,
            claims: claims,
          }.compact
        end

        protected

        attr_writer :scope_matcher
      end
    end
  end
end
