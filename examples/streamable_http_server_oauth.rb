# frozen_string_literal: true

# An MCP server protected as an OAuth 2.1 resource server per the MCP authorization specification:
#
# - Bearer tokens are required on every MCP request; missing/invalid tokens answer 401 with a `WWW-Authenticate` challenge
#   pointing at the Protected Resource Metadata document.
# - The Protected Resource Metadata (RFC 9728) is served at /.well-known/oauth-protected-resource so clients can discover
#   the authorization server.
# - Tools read the verified token as `server_context.auth_info`.
#
# The MCP server itself never issues tokens: bring your own authorization server (Auth0, Keycloak, doorkeeper, etc.)
# and point the verifier at its JWKS endpoint:
#
#   ISSUER=https://as.example.com \
#   JWKS_URI=https://as.example.com/.well-known/jwks.json \
#   ruby examples/streamable_http_server_oauth.rb
#
# Without an authorization server at hand, opt in to development mode. It verifies HS256 JWTs with a secret generated at boot
# (or `DEV_SECRET` when set) and prints a matching demo token. The example refuses to start when neither `JWKS_URI` nor
# `DEV_MODE=1` is given, so the shared-secret path can never be reached by accident, and when both are given:
#
#   DEV_MODE=1 ruby examples/streamable_http_server_oauth.rb
#
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "mcp"
require "rack/cors"
require "rackup"
require "json"
require "jwt"
require "logger"
require "securerandom"

RESOURCE_URL = ENV.fetch("RESOURCE_URL", "http://localhost:9393")
ISSUER = ENV.fetch("ISSUER", "http://localhost:9000")
JWKS_URI = ENV["JWKS_URI"]
DEV_MODE = ENV["DEV_MODE"] == "1"

unless JWKS_URI || DEV_MODE
  warn(<<~MESSAGE)
    Refusing to start: no token verifier is configured.

    Point the example at your authorization server's JWKS endpoint:
      ISSUER=https://as.example.com JWKS_URI=https://as.example.com/.well-known/jwks.json ruby #{$PROGRAM_NAME}

    Or opt in to development mode, which signs demo tokens with a secret generated at boot:
      DEV_MODE=1 ruby #{$PROGRAM_NAME}
  MESSAGE

  exit(1)
end

# The two modes are mutually exclusive: the demo token printed in development mode is signed with the boot-time secret,
# which a JWKS-backed verifier would reject, so combining them would print a token that never works.
if JWKS_URI && DEV_MODE
  warn("Refusing to start: JWKS_URI and DEV_MODE=1 are mutually exclusive; pick one.")

  exit(1)
end

# Development mode only. The secret is generated per boot unless DEV_SECRET is set, so no shared secret ships with the example.
DEV_SECRET = DEV_MODE ? ENV.fetch("DEV_SECRET") { SecureRandom.hex(32) } : nil

# Tool that reports who the authenticated caller is.
class WhoamiTool < MCP::Tool
  tool_name "whoami"
  description "Reports the authenticated subject, client, and scopes"

  class << self
    def call(server_context:)
      auth_info = server_context.auth_info

      MCP::Tool::Response.new([{
        type: "text",
        text: JSON.pretty_generate(
          subject: auth_info.subject,
          client_id: auth_info.client_id,
          scopes: auth_info.scopes,
          issuer: auth_info.issuer,
        ),
      }])
    end
  end
end

server = MCP::Server.new(name: "oauth_example_server", tools: [WhoamiTool])

# RFC 9728 Protected Resource Metadata: tells clients which authorization server issues tokens for
# this resource and which scopes exist.
metadata = MCP::Server::OAuth::ProtectedResourceMetadata.new(
  resource: RESOURCE_URL,
  authorization_servers: [ISSUER],
  scopes_supported: ["mcp:tools"],
  resource_name: "MCP OAuth Example Server",
)

# The verifier takes its expected `iss` and `aud` from the metadata document.
verifier = if JWKS_URI
  MCP::Server::OAuth::JWTVerifier.new(
    resource_metadata: metadata,
    jwks_uri: JWKS_URI,
  )
else
  # Development mode: HS256 with the boot-time secret. Anyone holding the secret can mint tokens,
  # so this path is reachable only behind the explicit DEV_MODE=1 opt-in above.
  MCP::Server::OAuth::JWTVerifier.new(
    resource_metadata: metadata,
    key: DEV_SECRET,
    algorithms: ["HS256"],
  )
end

# The transport enforces bearer authentication itself. Alternatively, wrap a plain transport with
# `MCP::Server::OAuth::Middleware` to compose the same enforcement at the Rack layer.
transport = MCP::Server::Transports::StreamableHTTPTransport.new(
  server,
  token_verifier: verifier,
  required_scopes: ["mcp:tools"],
  resource_metadata: metadata,
)

rack_app = Rack::Builder.new do
  # Enable CORS to allow browser-based MCP clients (e.g., MCP Inspector).
  # CORS must run before bearer enforcement: the browser's preflight OPTIONS request carries no Authorization header,
  # and a 401 answered to the preflight would fail CORS closed before the client could authenticate.
  # WARNING: origins("*") allows all origins. Restrict this in production.
  use(Rack::Cors) do
    allow do
      origins("*")
      resource(
        "*",
        headers: :any,
        methods: [:get, :post, :delete, :options],
        expose: ["Mcp-Session-Id", "WWW-Authenticate"],
      )
    end
  end

  use(Rack::CommonLogger, Logger.new($stdout))

  # The metadata document is how unauthenticated clients bootstrap, so it is served above the bearer-protected transport,
  # at the well-known path derived from RESOURCE_URL.
  use(MCP::Server::OAuth::ProtectedResourceMetadataMiddleware, metadata)

  map("/") do
    run(transport)
  end
end

token_steps = if DEV_MODE
  demo_token = JWT.encode(
    {
      iss: ISSUER,
      aud: RESOURCE_URL,
      sub: "demo-user",
      client_id: "demo-client",
      scope: "mcp:tools",
      exp: Time.now.to_i + 3600,
    },
    DEV_SECRET,
    "HS256",
  )

  <<~STEPS
    3. Authenticated requests succeed (development token, valid for 1 hour):
       curl -i #{RESOURCE_URL} \\
         -H "Authorization: Bearer #{demo_token}" \\
         -H "Accept: application/json, text/event-stream" \\
         --json '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}'

    4. Call the whoami tool with the session ID from step 3:
       curl -i #{RESOURCE_URL} \\
         -H "Authorization: Bearer #{demo_token}" \\
         -H "Mcp-Session-Id: YOUR_SESSION_ID" \\
         -H "Accept: application/json, text/event-stream" \\
         --json '{"jsonrpc":"2.0","method":"tools/call","id":2,"params":{"name":"whoami","arguments":{}}}'
  STEPS
else
  <<~STEPS
    3. Obtain an access token for #{RESOURCE_URL} from #{ISSUER}, repeat step 1 with
       -H "Authorization: Bearer YOUR_TOKEN", and call the whoami tool with the session ID
       from that response.
  STEPS
end

puts <<~MESSAGE
  === MCP OAuth Resource Server Example ===

  Starting server on #{RESOURCE_URL}#{DEV_MODE ? " (development mode)" : ""}

  1. Unauthenticated requests get a 401 challenge:
     curl -i #{RESOURCE_URL} \\
       -H "Accept: application/json, text/event-stream" \\
       --json '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}'

  2. The challenge points at the Protected Resource Metadata:
     curl -i #{metadata.well_known_url}

  #{token_steps}
  Press Ctrl+C to stop the server
MESSAGE

Rackup::Handler.get("puma").run(rack_app, Port: 9393, Host: "localhost")
