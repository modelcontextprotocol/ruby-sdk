# frozen_string_literal: true

require_relative "authenticator"
require_relative "challenge"
require_relative "errors"

module MCP
  class Server
    module OAuth
      # Rack middleware that enforces bearer authentication for everything it wraps, per RFC 6750 and the MCP authorization specification:
      #
      #   use MCP::Server::OAuth::Middleware,
      #     token_verifier: verifier,
      #     required_scopes: ["mcp:tools"],
      #     resource_metadata: metadata
      #   run transport
      #
      # See `Authenticator` for the option semantics; this class only adapts it to the Rack middleware calling convention.
      # The streamable HTTP transport embeds the same authenticator via its `token_verifier:` option, so use this middleware when composition
      # at the Rack layer is preferable (for example to share one authenticator across several apps).
      #
      # Tokens are accepted from the `Authorization` header only, never from a query string. On success the verified `AccessToken` is stored in
      # `env[MCP::Server::OAuth::ENV_KEY]`, where the streamable HTTP transport picks it up and exposes it to handlers as `server_context.auth_info`.
      #
      # Because the middleware wraps the whole app, POST, GET (SSE), and DELETE requests are protected uniformly. Mount the metadata document outside
      # the protected scope: it is how unauthenticated clients bootstrap. When a browser-based client is involved, run the CORS middleware before
      # this one; otherwise its preflight OPTIONS request dies here with a 401 that the browser will not let the client see.
      class Middleware
        def initialize(app, token_verifier:, required_scopes: [], resource_metadata: nil, resource_metadata_url: nil, scope_matcher: nil)
          @app = app
          @authenticator = Authenticator.new(
            token_verifier: token_verifier,
            required_scopes: required_scopes,
            resource_metadata: resource_metadata,
            resource_metadata_url: resource_metadata_url,
            scope_matcher: scope_matcher,
          )
        end

        def call(env)
          begin
            env[ENV_KEY] = @authenticator.authenticate(env)
          rescue Error => e
            return @authenticator.challenge_response(e)
          rescue => e
            # A misbehaving verifier (e.g. an unreachable JWKS or introspection endpoint) is an internal failure: report it
            # and answer 500 without a challenge, so the client does not discard a perfectly good token.
            MCP.configuration.exception_reporter.call(e, { middleware: self.class.name })

            return [500, { "content-type" => "application/json" }, [{ error: "server_error" }.to_json]]
          end

          # Outside the rescue on purpose: only verification is this middleware's business, and a failure in the wrapped app
          # must reach whatever handles that app's errors, as it does with the Python SDK's bearer middleware.
          @app.call(env)
        end
      end
    end
  end
end
