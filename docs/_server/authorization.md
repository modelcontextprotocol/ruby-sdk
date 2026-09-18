---
layout: default
title: Authorization
nav_order: 19
---

# Authorization

Per the [MCP authorization specification](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization),
an HTTP-based MCP server acts as an OAuth 2.1 resource server: it validates bearer tokens and never issues them.
Token issuance belongs to an external authorization server (Auth0, Keycloak, Doorkeeper, etc.).
`MCP::Server::OAuth` provides the pieces the spec requires:

1. A token verifier (`JWTVerifier`, `IntrospectionVerifier`, or your own `verify(token)` object)
2. Bearer enforcement with RFC 6750 challenges (401 `invalid_token`, 403 `insufficient_scope` for scope step-up),
   built into the streamable HTTP transport via `token_verifier:`
3. A Protected Resource Metadata document (RFC 9728) that tells clients which authorization server protects this resource

Wired together in a `config.ru`, the three look like this: the metadata document is served outside the protected scope,
and the transport on the MCP endpoint enforces the verifier and the required scopes:

```ruby
# config.ru
require "mcp"

metadata = MCP::Server::OAuth::ProtectedResourceMetadata.new(
  resource: "https://mcp.example.com/mcp", # the URL clients connect to
  authorization_servers: ["https://as.example.com"], # the issuer URL
  scopes_supported: ["mcp:tools"],
)

# The metadata document is how unauthenticated clients bootstrap, so it is served at the top of the stack,
# outside the bearer-protected scope, at the well-known path derived from `resource`.
use(MCP::Server::OAuth::ProtectedResourceMetadataMiddleware, metadata)

verifier = MCP::Server::OAuth::JWTVerifier.new(
  resource_metadata: metadata, # accepts only tokens its authorization server issued for this resource
  jwks_uri: "https://as.example.com/.well-known/jwks.json",
)
server = MCP::Server.new(name: "my_server", tools: [SomeTool])

map("/mcp") do
  run(MCP::Server::Transports::StreamableHTTPTransport.new(
    server,
    token_verifier: verifier,
    required_scopes: ["mcp:tools"],
    resource_metadata: metadata,
  ))
end
```

`ProtectedResourceMetadata` also takes `resource_name:` and `resource_documentation:` for the human-readable members of the document,
`bearer_methods_supported:` (`["header"]` by default, the only method the transport accepts), and `extra:` for further RFC 9728 members
such as `jwks_uri`; the members shown above are validated at construction and cannot be overridden through `extra:`.
`scopes_supported:` must be an Array; `offline_access` is dropped from it, since the specification tells a protected resource not to advertise it,
and the member is omitted when nothing is left.
`resource:` is published exactly as given, so pass the canonical URL without a trailing slash, the form the specification prefers for interoperability,
unless the slash is significant for your resource; the verifiers check `aud` against that same value.

Every `POST`, `GET` (SSE), and `DELETE` request is verified, per HTTP request; SSE streams are verified when opened,
and a stream whose token expires while open is closed at its next keepalive tick (every 30 seconds on the legacy `GET` stream,
every `listen_keepalive_interval:` on a `subscriptions/listen` stream, so disabling that keepalive disables the re-check as well).
Revocation is not re-checked on an open stream; a deployment that must cut streams on revocation needs short-lived tokens.
An authenticated stream is also closed after `max_stream_lifetime:` seconds, whichever comes first; the default matches `session_idle_timeout:` at 30 minutes.
That cap is what bounds a stream whose token reports no expiry at all, since `exp` is optional in an RFC 7662 introspection response and
a token without it never counts as expired. Pass `max_stream_lifetime: nil` to remove the cap, and understand that a stream opened with
an expiry-less token then runs until either side closes the connection. A stream opened without a token (no `token_verifier:`) is never capped.
Tokens are accepted from the `Authorization` header only, never from a query string, and a token longer than 8192 bytes
is rejected as `invalid_token` before any verification. A session is additionally bound to the token identity that initialized it,
so a stolen session ID cannot be driven with a different principal's token; the mismatch is answered exactly like an unknown session (404),
so a guessed session ID is not confirmed to exist.
The binding compares the token's `iss`, `sub`, and `client_id`; a token that carries neither `sub` nor `client_id`
(both are optional in an RFC 7662 introspection response) records no identity, so a session it initializes is not bound.
An RFC 9068 JWT access token carries both, so in practice the gap concerns the introspection path.
Have the authorization server emit at least one of them, or bind sessions by other means with a `session_request_validator`;
see [Session Ownership](/server/transports/#session-ownership).

For composition at the Rack layer instead (e.g. sharing one authenticator across apps), wrap a plain transport with
`MCP::Server::OAuth::Middleware` - the transport picks the verified token up from the Rack env either way.
When a browser-based client is involved, run the CORS middleware before bearer enforcement so preflight `OPTIONS` requests
are not answered with 401, and expose the `WWW-Authenticate` response header, or the browser withholds the challenge that points
the client at the metadata document.
`Mcp-Session-Id` in the snippet below is unrelated to authorization: a handshake-lifecycle client running in a browser cannot keep its session without it,
while the modern lifecycle carries no session. `ProtectedResourceMetadataMiddleware` answers preflights and sets `Access-Control-Allow-Origin: *` on its own,
since the document is meant to be fetched cross-origin:

```ruby
use Rack::Cors do
  allow do
    origins "*" # restrict in production
    resource "*", headers: :any, methods: [:get, :post, :delete, :options], expose: ["Mcp-Session-Id", "WWW-Authenticate"]
  end
end
```

The middleware takes the same options as the transport:

```ruby
use MCP::Server::OAuth::Middleware, token_verifier: verifier, required_scopes: ["mcp:tools"], resource_metadata: metadata
run MCP::Server::Transports::StreamableHTTPTransport.new(server)
```

Either way these keywords shape the enforcement:

- `token_verifier:` - the verifier; the keywords below require it
- `required_scopes:` - scopes every request must carry; a token lacking one is answered with 403 `insufficient_scope`
- `resource_metadata:` - the `ProtectedResourceMetadata` whose `well_known_url` the challenges point at, or `resource_metadata_url:`
  when the document is served elsewhere (the URL wins over the document)
- `scope_matcher:` - a callable receiving a required scope and the token's granted scopes, for scope hierarchies,
  which the 2026-07-28 revision requires servers to honor; by default a required scope must appear in the token verbatim
- `max_stream_lifetime:` - seconds an authenticated SSE stream may stay open before the client must present its token again,
  30 minutes by default; `nil` removes the cap. Transport-only: the Rack middleware wraps requests, not streams

```ruby
scope_matcher: ->(required_scope, granted_scopes) { granted_scopes.include?("mcp:all") || granted_scopes.include?(required_scope) }
```

Bearer enforcement applies to the handshake lifecycle and the modern lifecycle alike, and in `stateless: true` mode as well,
where there is no session to bind and every request stands on its own token.

## Rails

With the [mount approach](/server/transports/#rails-mount), mount the transport in `config/routes.rb` and add the metadata middleware to the stack,
as the initializer below does; it serves the RFC 9728 path derived from the resource URL (`/.well-known/oauth-protected-resource/mcp` for
a resource at `/mcp`) ahead of the routes:

```ruby
# config/routes.rb
Rails.application.routes.draw do
  mount transport => "/mcp"
end
```

The [controller approach](/server/transports/#rails-controller) takes the same keywords on its per-request transport: `handle_request` verifies the bearer token
before reading the body, exactly as the mounted transport does, and the verified `AccessToken` reaches the tools of the per-request `MCP::Server`
as `server_context.auth_info`. The metadata document is served by the middleware either way.

Build the verifier and the metadata once and share them across requests. A `JWTVerifier` caches the JWKS on the instance,
so one built per request would fetch the keys on every call, and a document assembled per request from what the request says,
the `Host` header for instance, would hand the sender the `aud` and `iss` the verifier checks against:

```ruby
# config/initializers/mcp_oauth.rb
MCP_METADATA = MCP::Server::OAuth::ProtectedResourceMetadata.new(
  resource: "https://mcp.example.com/mcp",
  authorization_servers: ["https://as.example.com"],
  scopes_supported: ["mcp:tools"],
)
MCP_VERIFIER = MCP::Server::OAuth::JWTVerifier.new(
  resource_metadata: MCP_METADATA,
  jwks_uri: "https://as.example.com/.well-known/jwks.json",
)
Rails.application.config.middleware.use(MCP::Server::OAuth::ProtectedResourceMetadataMiddleware, MCP_METADATA)

# app/controllers/mcp_controller.rb
class McpController < ActionController::API
  def create
    server = MCP::Server.new(name: "my_server", tools: [SomeTool])
    transport = MCP::Server::Transports::StreamableHTTPTransport.new(
      server,
      stateless: true,
      serve_subscriptions_listen: false,
      token_verifier: MCP_VERIFIER,
      required_scopes: ["mcp:tools"],
      resource_metadata: MCP_METADATA,
    )
    status, headers, body = transport.handle_request(request)

    render(json: body.first, status: status, headers: headers)
  end
end
```

## Setting Up the Authorization Server

The SDK covers the resource-server half only, as the specification has since its 2025-06-18 revision and as the reference SDKs do.
Token issuance belongs to an authorization server you already run or subscribe to (Auth0, Keycloak, Okta, Microsoft Entra ID,
Doorkeeper, and the like), and before a verifier can accept anything, that server must be able to issue tokens for this MCP server:

- Register the MCP server's canonical URL (the `resource` of its Protected Resource Metadata, such as `https://mcp.example.com/mcp`)
  as an API or resource at the authorization server. MCP clients request tokens with that URL as the RFC 8707 `resource` parameter;
  an authorization server that does not honor the parameter usually offers an equivalent setting (an API identifier or audience).
  Either way, the issued token must name the canonical URL, because the verifiers reject any other audience.
- Define the scopes the server requires (`required_scopes:` here, `scopes_supported:` in the metadata) so that clients can request them
  and the authorization server can grant them.
- Collect what the verifier validates against: the JWKS URL for `JWTVerifier`, or the introspection endpoint plus client credentials issued to
  this MCP server for `IntrospectionVerifier`.

The authorization server's issuer URL goes into `authorization_servers:` of the metadata, which is what `JWTVerifier` checks `iss` against;
the built-in verifiers serve one authorization server, so the list holds one entry.

## Choosing a Verifier

The verifier decides how a presented token is checked, and the choice follows what the authorization server issues:
JWTs can be validated locally, opaque tokens only by asking the authorization server, and anything else fits behind the custom contract.

| Verifier                                    | Token type    | Dependencies              | Notes                                                                                                                                                                                                                              |
|---------------------------------------------|---------------|---------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `MCP::Server::OAuth::JWTVerifier`           | JWT           | `jwt` gem (lazy-required) | Local validation of signature (JWKS endpoint, static JWKS, or single key), `iss`, `aud`, `exp`, and `nbf`. The default algorithm allowlist is asymmetric-only; HMAC requires explicit opt-in.                                      |
| `MCP::Server::OAuth::IntrospectionVerifier` | Opaque or JWT | None (stdlib `Net::HTTP`) | Asks the authorization server via RFC 7662 Token Introspection on every request, so revocation takes effect immediately.                                                                                                           |
| Custom object                               | Any           | None                      | Anything responding to `verify(token)` that returns an `MCP::Server::OAuth::AccessToken` or raises `MCP::Server::OAuth::InvalidTokenError`. Another `MCP::Server::OAuth::Error` or a returned `nil` is treated as a rejection too. |

Both verifiers take the document as `resource_metadata:` and check `aud` against its `resource`, the canonical resource URL;
`JWTVerifier` checks `iss` against its authorization server as well. This is the RFC 8707 audience check that keeps a token issued
for another service from being replayed against your MCP server, and it cannot drift from the document, since the verifiers have
no audience setting of their own. Each built-in verifier serves one authorization server: `JWTVerifier` holds one key set and refuses
a document naming several, and `IntrospectionVerifier` asks one server's endpoint, which reports the tokens of any other server
the document names as inactive. A resource trusting several authorization servers needs a custom verifier.

`JWTVerifier` takes its key material as exactly one of `jwks_uri:` (fetched over https, or http on loopback,
cached for `jwks_cache_ttl:` seconds, 300 by default, and rejected when the document exceeds 4 MiB), `jwks:` (a static JWKS Hash),
or `key:` (a single verification key: an `OpenSSL::PKey` for asymmetric algorithms, a String only as an HMAC secret; a `JWT::JWK` belongs in `jwks:`).
`algorithms:` is the allowlist of signature algorithms, asymmetric only by default (`RS*`, `PS*`, `ES*`, and `EdDSA`);
`none` is never accepted, HMAC (`HS*`) cannot share an allowlist with asymmetric algorithms, and `EdDSA` additionally needs the `jwt-eddsa` gem.
`leeway:` (0 by default) tolerates clock skew when checking `exp` and `nbf`; `open_timeout:` / `read_timeout:` bound the JWKS fetch (5 seconds each).
When a refresh fails, whether the endpoint errors or cannot be reached, the cached keys keep serving for `jwks_max_stale:` seconds past
the TTL (3600 by default; 0 disables the fallback), after which verification fails until the endpoint recovers. HMAC is an explicit opt-in because
a shared secret lets any holder mint tokens:

```ruby
MCP::Server::OAuth::JWTVerifier.new(
  resource_metadata: metadata,
  key: ENV.fetch("HMAC_SECRET"),
  algorithms: ["HS256"],
)
```

Opaque tokens, and any deployment that must see revocation immediately, go through RFC 7662 introspection instead.
The MCP server authenticates to the introspection endpoint with client credentials of its own, which the authorization server issues to it as a client:

```ruby
verifier = MCP::Server::OAuth::IntrospectionVerifier.new(
  resource_metadata: metadata,
  introspection_endpoint: "https://as.example.com/oauth/introspect",
  client_id: "mcp-resource-server", # credentials issued to this MCP server
  client_secret: ENV.fetch("INTROSPECTION_CLIENT_SECRET"),
)
```

`client_auth_method:` selects how those credentials are sent (`:client_secret_basic` by default, `:client_secret_post`, or `:none` for an endpoint that
does not authenticate callers), and `open_timeout:` / `read_timeout:` bound each call (5 seconds each by default), and a response over 4 MiB is rejected.
The endpoint must use https except on loopback.

`IntrospectionVerifier` costs one round-trip to the authorization server per request, and a request that fails to authenticate costs the same:
every syntactically valid token reaches the introspection endpoint, known or not, each request holding a server thread for the length of that
round-trip (the bearer syntax and token length checks that run first bound the cost of a request, not the number of requests).
Any introspection-based verifier behaves this way, the reference SDKs included. Prefer `JWTVerifier`, which validates locally,
for public or high-traffic endpoints; where introspection is required, rate-limit ahead of the transport (at a proxy or as Rack middleware),
and note that the authorization server can throttle its introspection endpoint per resource server, since every call carries the resource server's client credentials.

## Accessing the Token in Handlers

On success the verified `MCP::Server::OAuth::AccessToken` is threaded through to every handler as `server_context.auth_info`
(when the underlying `server_context` is a Hash, `server_context[:auth_info]` also works):

```ruby
class WhoamiTool < MCP::Tool
  description "Reports the authenticated user"

  class << self
    def call(server_context:)
      auth_info = server_context.auth_info

      MCP::Tool::Response.new([{
        type: "text",
        text: "You are #{auth_info.subject} (scopes: #{auth_info.scopes.join(", ")})",
      }])
    end
  end
end
```

`AccessToken` exposes `subject`, `client_id`, `scopes`, `expires_at`, `issuer`, `audience`, `resource`, and the full `claims` Hash.
For per-operation checks beyond the transport-level `required_scopes`, `server_context.require_scopes!("admin")` rejects the request with
a JSON-RPC error naming the missing scopes, and `auth_info.scope?("admin")` supports custom handling; both honor the transport's `scope_matcher:`,
so a hierarchical scope scheme is applied the same way at the endpoint gate and inside handlers
(a custom verifier that returns its own object instead of an `AccessToken` is matched at the endpoint gate only). Authentication is per HTTP request
and never cached on the MCP session, so token expiry takes effect mid-session; revocation does too when the verifier can observe it,
which `IntrospectionVerifier` does on every request, while a locally validated JWT stays accepted until it expires.

`require_scopes!` raises `MCP::Server::OAuth::InsufficientScopeError`, which the server turns into a JSON-RPC invalid-request error (`-32600`)
whose `data` names the missing scopes; the HTTP status stays 200 and no `WWW-Authenticate` challenge is sent,
because step-up challenges (403 `insufficient_scope`) are the job of the transport-level `required_scopes:` gate.
The Python and TypeScript SDKs split endpoint-level challenges from in-handler authorization the same way.
Without bearer authentication `auth_info` is `nil` and `require_scopes!` fails closed.
Use it where one operation needs more than the endpoint as a whole:

```ruby
class DeleteRecordTool < MCP::Tool
  description "Deletes a record"

  class << self
    def call(id:, server_context:)
      server_context.require_scopes!("records:write")

      MCP::Tool::Response.new([{ type: "text", text: "deleted #{id}" }])
    end
  end
end
```

The challenges the transport emits parse cleanly with this SDK's own client ([Authorization](/client/authorization/)),
which discovers the Protected Resource Metadata from the `WWW-Authenticate` challenge and runs the full authorization flow automatically.
See `examples/streamable_http_server_oauth.rb` for a runnable server; its `DEV_MODE=1` switch stands in for an authorization server
in local experiments only, signing demo tokens itself with a secret generated at boot, and `ISSUER` with `JWKS_URI` points it at a real one.

Custom transports (or non-Rack stacks) can verify tokens themselves and pass the result via `Server#handle_json(request, auth_info: access_token)`,
or set `env[MCP::Server::OAuth::ENV_KEY]` upstream of the streamable HTTP transport.

## Response Reference

Each failure is answered with the status and challenge the specification assigns to it; this is what a client sees in each case.
A challenge carries `resource_metadata` when `resource_metadata:` or `resource_metadata_url:` is configured,
and `scope` when `required_scopes:` is set or the metadata document advertises `scopes_supported`:

| Situation                                                                                                          | Response                                                                                      |
|--------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------|
| No `Authorization` header                                                                                          | 401 with a bare `WWW-Authenticate: Bearer` challenge and no error code (RFC 6750 Section 3.1) |
| Token rejected by the verifier (expired, wrong audience, bad signature, `nil` returned, or another `OAuth::Error`) | 401 `error="invalid_token"`, the verifier's message, or a default one, as `error_description` |
| Valid token lacking a scope from `required_scopes:`                                                                | 403 `error="insufficient_scope"` with the required `scope` list and `resource_metadata`       |
| `Authorization` header with another scheme, or not carrying exactly one token                                      | 400 `error="invalid_request"`                                                                 |
| Valid token used against a session initialized by another principal                                                | 404 as for an unknown session                                                                 |
| Verifier raised anything outside the `OAuth::Error` hierarchy (JWKS or introspection endpoint down)                | 500 without a challenge, reported through the exception reporter                              |
| `require_scopes!` failure inside a handler                                                                         | JSON-RPC `-32600` in the normal 200 response, no HTTP challenge                               |

## Client Side

Running the authorization flow against a protected server, from the `WWW-Authenticate` challenge of a `401 Unauthorized` response through discovery,
PKCE, and token refresh, is documented on the client [Authorization](/client/authorization/) page.
