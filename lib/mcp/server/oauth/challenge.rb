# frozen_string_literal: true

require "json"

module MCP
  class Server
    module OAuth
      # Stateless builders for RFC 6750 Bearer challenges and the Rack error responses that carry them.
      # `Authenticator` uses these for every rejection; they are also public so custom integrations can emit
      # spec-shaped 401/403 responses without pulling in the middleware.
      #
      # The header output is the exact counterpart of `MCP::Client::OAuth::Discovery.parse_www_authenticate`:
      # everything built here parses back into the same parameters on the client side.
      # https://www.rfc-editor.org/rfc/rfc6750#section-3
      module Challenge
        CONTENT_TYPE_JSON = { "content-type" => "application/json" }.freeze
        private_constant :CONTENT_TYPE_JSON

        class << self
          # Returns a `WWW-Authenticate` header value such as
          # `Bearer error="invalid_token", error_description="...", scope="a b", resource_metadata="https://..."`.
          # Parameters are quoted-string encoded per RFC 7235; nil parameters are omitted.
          def build(error: nil, error_description: nil, scope: nil, resource_metadata: nil)
            parameters = []
            parameters << %(error="#{quote(error)}") if error
            parameters << %(error_description="#{quote(error_description)}") if error_description
            parameters << %(scope="#{quote(scope)}") if scope
            parameters << %(resource_metadata="#{quote(resource_metadata)}") if resource_metadata

            parameters.empty? ? "Bearer" : "Bearer #{parameters.join(", ")}"
          end

          # 401 with `error="invalid_token"`: the presented token is expired, revoked, or otherwise invalid.
          # https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization
          def invalid_token_response(error_description: nil, scope: nil, resource_metadata: nil)
            challenge_response(
              401,
              error: "invalid_token",
              error_description: error_description,
              scope: scope,
              resource_metadata: resource_metadata,
            )
          end

          # 401 without an error code: RFC 6750 Section 3.1 says the challenge answering a request that
          # carried no authentication information at all should not include an error code or other error information.
          def missing_token_response(scope: nil, resource_metadata: nil)
            challenge_response(401, scope: scope, resource_metadata: resource_metadata)
          end

          # 403 with `error="insufficient_scope"`: the token is valid but lacks a scope the current operation requires.
          # Clients treat this as a step-up signal and re-authorize with the scopes advertised in `scope`.
          def insufficient_scope_response(error_description: nil, scope: nil, resource_metadata: nil)
            challenge_response(
              403,
              error: "insufficient_scope",
              error_description: error_description,
              scope: scope,
              resource_metadata: resource_metadata,
            )
          end

          # 400 with `error="invalid_request"`: the request itself is malformed (e.g. an `Authorization` header with another scheme
          # or without exactly one token).
          def invalid_request_response(error_description: nil, resource_metadata: nil)
            challenge_response(
              400,
              error: "invalid_request",
              error_description: error_description,
              resource_metadata: resource_metadata,
            )
          end

          private

          def challenge_response(status, error: nil, error_description: nil, scope: nil, resource_metadata: nil)
            # The description reaches the header (quoted below) and the JSON body alike; normalized once here
            # so a custom verifier's message with invalid bytes cannot make `to_json` raise either.
            error_description = utf8(error_description) if error_description
            www_authenticate = build(
              error: error,
              error_description: error_description,
              scope: scope,
              resource_metadata: resource_metadata,
            )
            return [status, { "www-authenticate" => www_authenticate }, []] if error.nil?

            body = { error: error }
            body[:error_description] = error_description if error_description

            [status, CONTENT_TYPE_JSON.merge("www-authenticate" => www_authenticate), [body.to_json]]
          end

          # Encodes a parameter value as an RFC 7230 quoted-string interior: `\` and `"` become quoted-pairs.
          # Control characters are replaced with spaces because they cannot appear in a header value at all;
          # leaving CR/LF in would let attacker-influenced text (e.g. an error message quoting a bad token)
          # split the response header, and other control characters make strict servers reject the response outright.
          # Invalid byte sequences are replaced first: a custom verifier's message need not be valid UTF-8,
          # and `gsub` raising on it would escape the rescue that builds the challenge, turning the 401 into a 500.
          def quote(value)
            utf8(value).gsub(/[[:cntrl:]]/, " ").gsub(/[\\"]/) { |character| "\\#{character}" }
          end

          # Normalizes a value to valid UTF-8. `scrub` alone only repairs strings tagged UTF-8:
          # Rack hands header values to a custom verifier as ASCII-8BIT, where every byte counts as valid,
          # so a message assembled from them would still make `to_json` raise.
          def utf8(value)
            value.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?")
          end
        end
      end
    end
  end
end
