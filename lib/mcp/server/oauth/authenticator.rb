# frozen_string_literal: true

require_relative "access_token"
require_relative "challenge"
require_relative "errors"

module MCP
  class Server
    module OAuth
      # The verification core shared by `Middleware` and the streamable HTTP transport's built-in enforcement:
      # extracts the bearer token from a Rack env, runs it through the verifier, checks scopes, and maps each failure
      # to the RFC 6750 challenge response it deserves.
      #
      # - `token_verifier` - anything responding to `verify(token)`; see `TokenVerifier` for the contract.
      #   Built-ins: `JWTVerifier`, `IntrospectionVerifier`.
      # - `required_scopes` - scopes the token must include, all of them; a shortfall produces 403 `insufficient_scope` (step-up).
      # - `resource_metadata` - a `ProtectedResourceMetadata`; its well-known URL and `scopes_supported` feed the challenges.
      #   Pass `resource_metadata_url:` instead to point at a document served elsewhere.
      # - `scope_matcher` - optional callable `(required_scope, granted_scopes) -> Boolean` for deployments
      #   whose scopes form a hierarchy; the MCP authorization specification requires a broader scope to satisfy
      #   the narrower scopes it implies, which exact membership (the default) cannot express. The matcher also rides
      #   on the returned `AccessToken`, so `require_scopes!` and `scope?` inside handlers apply the same semantics.
      class Authenticator
        BEARER_PATTERN = /\ABearer\s+(?<token>\S+)\z/i.freeze
        private_constant :BEARER_PATTERN

        # Upper bound on the presented token, applied before any verification so oversized garbage neither reaches
        # cryptographic parsing nor gets forwarded to an introspection endpoint. Real-world access tokens stay far below this;
        # web servers cap the whole header section around 16 KiB.
        MAX_TOKEN_BYTES = 8192

        def initialize(token_verifier:, required_scopes: [], resource_metadata: nil, resource_metadata_url: nil, scope_matcher: nil)
          @verifier = token_verifier
          @required_scopes = Array(required_scopes)
          @resource_metadata = resource_metadata
          @resource_metadata_url = resource_metadata_url || resource_metadata&.well_known_url
          @scope_matcher = scope_matcher
        end

        # @param env [Hash] the Rack env
        # @return [AccessToken]
        # @raise [MissingTokenError, InvalidRequestError, InvalidTokenError, InsufficientScopeError]
        def authenticate(env)
          token = extract_bearer_token(env)

          access_token = @verifier.verify(token)
          raise InvalidTokenError if access_token.nil?

          access_token = attach_scope_matcher(access_token)
          check_scopes!(access_token)
          access_token
        end

        # Maps an `OAuth::Error` raised by `authenticate` (or by a handler's `require_scopes!`) to the Rack response carrying
        # the matching challenge. An `Error` outside the four built-in classes, such as one a custom verifier defines,
        # is a token rejection and answers 401 like an invalid token; anything else is a programming error.
        def challenge_response(error)
          case error
          when MissingTokenError
            Challenge.missing_token_response(scope: scope_hint, resource_metadata: @resource_metadata_url)
          when InvalidRequestError
            Challenge.invalid_request_response(error_description: error.message, resource_metadata: @resource_metadata_url)
          when InsufficientScopeError
            Challenge.insufficient_scope_response(
              error_description: error.message,
              scope: scope_hint(error.required_scopes),
              resource_metadata: @resource_metadata_url,
            )
          when Error
            Challenge.invalid_token_response(
              error_description: error.message,
              scope: scope_hint,
              resource_metadata: @resource_metadata_url,
            )
          else
            raise ArgumentError, "unexpected error class: #{error.class}"
          end
        end

        private

        def extract_bearer_token(env)
          header = env["HTTP_AUTHORIZATION"]
          raise MissingTokenError if header.nil? || header.empty?

          # Matched as bytes: a Rack server hands the header over as ASCII-8BIT, but a test request or a framework can tag it UTF-8,
          # and a regexp raises on an invalid byte sequence in a UTF-8 string. As bytes, such a token simply fails verification.
          match = BEARER_PATTERN.match(header.b)
          raise InvalidRequestError, "Authorization header must carry a single Bearer token" if match.nil?

          token = match[:token]
          raise InvalidTokenError, "Token exceeds the maximum accepted length" if token.bytesize > MAX_TOKEN_BYTES

          token
        end

        def check_scopes!(access_token)
          missing_scopes = @required_scopes.reject { |scope| scope_satisfied?(scope, access_token) }
          return if missing_scopes.empty?

          raise InsufficientScopeError.new(
            "Token is missing required scopes: #{missing_scopes.join(", ")}",
            required_scopes: @required_scopes,
          )
        end

        # A verifier result that is not an `AccessToken` (a duck-typed object from a custom verifier) keeps its own `scope?`;
        # the endpoint gate below still applies the matcher to it directly.
        def attach_scope_matcher(access_token)
          return access_token if @scope_matcher.nil? || !access_token.respond_to?(:with_scope_matcher)

          access_token.with_scope_matcher(@scope_matcher)
        end

        # A verifier result without a `scopes` reader (a duck-typed object offering only `scope?`) keeps its own judgement,
        # since the matcher needs the granted list to reason about a hierarchy.
        def scope_satisfied?(scope, access_token)
          return access_token.scope?(scope) if @scope_matcher.nil? || !access_token.respond_to?(:scopes)

          @scope_matcher.call(scope, access_token.scopes)
        end

        # The scope hint the spec recommends including in challenges: the scopes of the failing operation when known,
        # the scopes this authenticator enforces otherwise, or the resource's advertised scopes as a fallback.
        # `offline_access` is never advertised: refresh token issuance is not a resource requirement per
        # the MCP authorization specification.
        def scope_hint(operation_scopes = [])
          scopes = operation_scopes
          scopes = @required_scopes if scopes.empty?
          scopes = Array(@resource_metadata&.scopes_supported) if scopes.empty?
          scopes -= ["offline_access"]

          scopes.empty? ? nil : scopes.join(" ")
        end
      end
    end
  end
end
