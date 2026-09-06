# frozen_string_literal: true

require_relative "oauth/errors"

module MCP
  class Server
    # OAuth 2.1 resource-server support per the MCP authorization specification: bearer token verification,
    # Protected Resource Metadata (RFC 9728) serving, and RFC 6750 `WWW-Authenticate` challenges.
    # The MCP server never acts as an authorization server; token issuance belongs to an external provider.
    # https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization
    module OAuth
      # The Rack env key under which the transport's built-in enforcement and `Middleware` store
      # the verified `AccessToken`. The streamable HTTP transport reads this key and threads the value through
      # to handlers as `server_context.auth_info`. Custom integrations that verify tokens themselves can set
      # the same key to opt in to that propagation.
      ENV_KEY = "mcp.auth_info"

      autoload :AccessToken, "mcp/server/oauth/access_token"
      autoload :Authenticator, "mcp/server/oauth/authenticator"
      autoload :Challenge, "mcp/server/oauth/challenge"
      autoload :IntrospectionVerifier, "mcp/server/oauth/introspection_verifier"
      autoload :JWTVerifier, "mcp/server/oauth/jwt_verifier"
      autoload :Middleware, "mcp/server/oauth/middleware"
      autoload :ProtectedResourceMetadata, "mcp/server/oauth/protected_resource_metadata"
      autoload :ProtectedResourceMetadataMiddleware, "mcp/server/oauth/protected_resource_metadata_middleware"
      autoload :TokenVerifier, "mcp/server/oauth/token_verifier"
    end
  end
end
