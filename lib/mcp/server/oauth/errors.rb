# frozen_string_literal: true

module MCP
  class Server
    module OAuth
      # Error hierarchy for the OAuth 2.1 resource-server role. Each error carries the RFC 6750 Section 3.1
      # registered error code that `Challenge` places in the `WWW-Authenticate` response header.
      # https://www.rfc-editor.org/rfc/rfc6750#section-3.1
      class Error < StandardError
        attr_reader :error_code

        # `error_code` defaults to the code a token rejection carries, so a custom verifier can subclass this
        # and `raise MyError, "..."` without knowing about the keyword. `Authenticator#challenge_response`
        # answers any such error with 401 `invalid_token`, which is what the default names; without a default,
        # the missing keyword would raise `ArgumentError` inside `verify` and surface as HTTP 500 instead.
        def initialize(message = nil, error_code: "invalid_token")
          super(message)
          @error_code = error_code
        end
      end

      # The request is malformed (e.g. an `Authorization` header that does not carry a Bearer token). Maps to HTTP 400.
      class InvalidRequestError < Error
        def initialize(message = "The request is malformed")
          super(message, error_code: "invalid_request")
        end
      end

      # The access token is missing, expired, revoked, or otherwise invalid.
      # Maps to HTTP 401. `TokenVerifier` implementations raise this to reject a token.
      class InvalidTokenError < Error
        def initialize(message = "The access token is invalid")
          super(message, error_code: "invalid_token")
        end
      end

      # The request carried no credentials at all. A subclass of `InvalidTokenError` so existing rescue clauses keep working,
      # but distinguished because RFC 6750 Section 3.1 says the challenge answering a credential-less request should not include
      # an error code.
      class MissingTokenError < InvalidTokenError
        def initialize(message = "Missing Authorization header")
          super
        end
      end

      # The token is valid but lacks a scope the resource requires. Maps to HTTP 403, whose `WWW-Authenticate` challenge signals
      # step-up authorization (the scope challenge handling of the MCP authorization specification) to the client.
      class InsufficientScopeError < Error
        attr_reader :required_scopes

        def initialize(message = "The request requires higher privileges", required_scopes: [])
          super(message, error_code: "insufficient_scope")
          @required_scopes = required_scopes
        end
      end
    end
  end
end
