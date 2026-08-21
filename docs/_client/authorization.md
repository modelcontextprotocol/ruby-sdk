---
layout: default
title: Authorization
nav_order: 8
---

# Authorization

Authorization is handled by the transport layer. This page covers authenticating the HTTP transport,
from custom headers such as bearer tokens to the OAuth 2.1 flows the SDK implements
(PKCE with dynamic client registration, the client credentials grant, and cross-app access).

## HTTP Authorization

By default, the HTTP transport layer provides no authentication to the server, but you can provide custom headers if you need authentication. For example, to use Bearer token authentication:

```ruby
http_transport = MCP::Client::HTTP.new(
  url: "https://api.example.com/mcp",
  headers: {
    "Authorization" => "Bearer my_token"
  }
)

client = MCP::Client.new(transport: http_transport)
client.tools # will make the call using Bearer auth
```

You can add any custom headers needed for your authentication scheme, or for any other purpose. The client will include these headers on every request.

## OAuth 2.1 Authorization

When an MCP server enforces the [MCP Authorization spec](https://modelcontextprotocol.io/specification/latest/basic/authorization),
pass an `MCP::Client::OAuth::Provider` to the transport instead of a static `Authorization` header. The transport will:

- Send `Authorization: Bearer <access_token>` on every request when a token is available.
- On a `401 Unauthorized`, parse the `WWW-Authenticate` header, discover the authorization server (Protected Resource Metadata + RFC 8414 Authorization Server Metadata),
  perform Dynamic Client Registration if needed, run the OAuth 2.1 Authorization Code flow with PKCE (S256), and retry the failed request with the acquired token.
- Fall back to the legacy 2025-03-26 discovery when the server publishes no Protected Resource Metadata, matching the TypeScript and Python SDKs: the MCP server's origin acts
  as the authorization base URL, its metadata is fetched from `<origin>/.well-known/oauth-authorization-server` without the RFC 8414 issuer byte-match (which the legacy spec predates),
  and when even that is absent the spec's default endpoints `/authorize`, `/token`, and `/register` at the origin are used with PKCE S256 assumed.
- On subsequent 401s with a saved `refresh_token`, exchange it at the token endpoint before falling back to the full interactive flow (RFC 6749 Section 6).
- On a `403 Forbidden` whose `WWW-Authenticate` header carries `error="insufficient_scope"` (OAuth 2.0 step-up, RFC 6750 Section 3.1 and the MCP scope-selection-strategy),
  run a fresh authorization request for the union of the currently granted scope and the scope named in the challenge, then retry the failed request once.
  The refresh path is bypassed because refreshing would re-issue the same scope set the server just rejected. A `403` without that challenge is surfaced unchanged.
- Request the `offline_access` scope when `client_metadata[:grant_types]` includes `refresh_token` and the authorization server advertises `offline_access` in its metadata
  `scopes_supported` (SEP-2207). This is what lets the server issue the `refresh_token` used above. As an SDK-level safeguard, when the authorization server does not advertise
  `offline_access` the scope is also stripped from any other source (challenge, PRM, or provider-supplied scope) so a server that does not support it never receives it.

```ruby
require "mcp"

provider = MCP::Client::OAuth::Provider.new(
  client_metadata: {
    client_name: "My MCP App",
    redirect_uris: ["http://localhost:3030/callback"],
    grant_types: ["authorization_code", "refresh_token"],
    response_types: ["code"],
    token_endpoint_auth_method: "none",
  },
  redirect_uri: "http://localhost:3030/callback",
  redirect_handler: ->(authorization_url) {
    # Send the user to the authorization URL - typically `Launchy.open(authorization_url)`
    # or a manual `puts authorization_url` in CLI tools.
  },
  callback_handler: -> {
    # Capture the redirect (for example, by running a small HTTP listener on
    # `redirect_uri`) and return [code, state] from the query string.
  },
)

transport = MCP::Client::HTTP.new(
  url: "https://api.example.com/mcp",
  oauth: provider,
)
client = MCP::Client.new(transport: transport)
client.connect # `initialize` is sent here; if the server replies 401 the OAuth flow runs and the handshake is retried with the acquired token
client.tools
```

Required keyword arguments to `Provider.new`:

- `client_metadata`: Hash sent to the authorization server's Dynamic Client Registration endpoint. Must include `redirect_uris`, `grant_types`, `response_types`,
  `token_endpoint_auth_method`. `redirect_uri` (below) must appear in this list, otherwise the constructor raises `Provider::UnregisteredRedirectURIError`.
  When `application_type` is omitted, the SDK infers `"native"` or `"web"` from `redirect_uris` per SEP-837 before registering (loopback or custom-scheme URIs are native);
  an explicit value always wins.
- `redirect_uri`: String. Must use HTTPS or be a loopback URL (`localhost`, `127.0.0.0/8`, `::1`); other values raise `Provider::InsecureRedirectURIError`.
- `redirect_handler`: Callable invoked with the fully-built authorization `URI`. Typically opens the user's browser.
- `callback_handler`: Callable that returns `[code, state]` or `[code, state, iss]` after the user is redirected back to `redirect_uri`. Returning the 3-element form
  (with `iss` set to the RFC 9207 `iss` parameter from the redirect, or `nil` when absent) opts into SEP-2468 issuer validation: a present `iss` must match
  the authorization server's issuer, and a missing one is rejected when the server advertises `authorization_response_iss_parameter_supported`.

Optional keyword arguments:

- `scope`: Space-separated scopes to request when the server's `WWW-Authenticate` does not specify one.
- `storage`: Object responding to `tokens`, `save_tokens(t)`, `client_information`, `save_client_information(info)`. Defaults to `MCP::Client::OAuth::InMemoryStorage`,
  which keeps credentials in process memory only. Persisted `client_information` is stamped with an `"issuer"` member binding it to the authorization server that
  issued it (SEP-2352): when the server's authorization server changes, the SDK discards the stale registration and its tokens and re-registers automatically
  (portable CIMD `client_id`s are kept). Treat the hash as opaque and persist it as-is.
- `client_id_metadata_document_url`: URL where you publish a Client ID Metadata Document
  (`draft-ietf-oauth-client-id-metadata-document` and the MCP authorization specification).
  When the authorization server advertises `client_id_metadata_document_supported: true`,
  the SDK uses this URL as the OAuth `client_id` and skips Dynamic Client Registration.
  Spec-required: the URL MUST be `https://` with a non-root path and MUST NOT include a fragment,
  userinfo, or `.`/`..` segments. The SDK additionally rejects query strings (the draft only marks
  them SHOULD NOT include, but the SDK refuses to send any) for `client_id` stability.
  Any of these failures raise `Provider::InvalidClientIDMetadataDocumentURLError`. The CIMD document
  served at the URL is a separate JSON artifact from the `client_metadata` keyword above:
  the DCR `client_metadata` MUST NOT include `client_id`, while the CIMD document MUST include
  `client_id` set to the document URL, `client_name`, and `redirect_uris` covering `redirect_uri`.

{: .warning }
> The OAuth 2.0 Dynamic Client Registration Protocol (RFC 7591) is deprecated as a client registration mechanism as of MCP 2026-07-28 in favor of Client ID Metadata Documents,
> while remaining available for authorization servers that do not support them. Publish a CIMD document and set `client_id_metadata_document_url`; the SDK then prefers it
> automatically wherever the authorization server advertises support.

To persist credentials across restarts, supply your own storage:

```ruby
class FileTokenStorage
  def initialize(path)
    @path = path
  end

  def tokens
    read["tokens"]
  end

  def save_tokens(value)
    write("tokens" => value)
  end

  def client_information
    read["client"]
  end

  def save_client_information(value)
    write("client" => value)
  end

  private

  def read
    File.exist?(@path) ? JSON.parse(File.read(@path)) : {}
  end

  def write(updates)
    File.write(@path, JSON.dump(read.merge(updates)))
  end
end

provider = MCP::Client::OAuth::Provider.new(
  # ... required keywords ...
  storage: FileTokenStorage.new(File.expand_path("~/.config/my-app/oauth.json")),
)
```

### Client Credentials Grant

For a confidential machine-to-machine client (no user, no browser redirect), use `MCP::Client::OAuth::ClientCredentialsProvider` instead of `Provider`.
The transport discovers the authorization server the same way, then exchanges the OAuth 2.1 `client_credentials` grant (RFC 6749 Section 4.4) at
the token endpoint. There is no authorization request, PKCE, or `offline_access`, because the grant does not issue a refresh token.

```ruby
provider = MCP::Client::OAuth::ClientCredentialsProvider.new(
  client_id: "my-service",
  client_secret: ENV.fetch("MCP_CLIENT_SECRET"),
  # token_endpoint_auth_method: "client_secret_basic" (default), "client_secret_post", or "private_key_jwt"
  # scope: "mcp:read mcp:write" (optional; used when the server does not advertise scopes)
)

transport = MCP::Client::HTTP.new(url: "https://api.example.com/mcp", oauth: provider)
```

Keyword arguments:

- `client_id`: Required. `client_secret`: Required with the secret-based methods; the grant is
  for confidential clients, so a credential is mandatory.
- `token_endpoint_auth_method`: `"client_secret_basic"` (default), `"client_secret_post"`,
  or `"private_key_jwt"` (RFC 7523 JWT client assertion per SEP-1046). `"none"` is rejected
  with `ClientCredentialsProvider::InvalidCredentialsError`.
- `private_key`, `signing_algorithm`: Required with `private_key_jwt` - the key (a PEM string
  or `OpenSSL::PKey::PKey`, never written to `storage`) signs the client assertion with `"ES256"`
  or `"RS256"`; `client_secret` must not be set, because the private key is the credential.
- `scope`, `storage`: Optional, same meaning as on `Provider`.

### Cross-App Access (JWT Bearer) Grant

For enterprise MCP deployments where an identity provider (IdP) governs authorization (SEP-990), use `MCP::Client::OAuth::CrossAppAccessProvider` instead of `Provider`.
The client exchanges an IdP-issued ID token for an Identity Assertion Authorization Grant (ID-JAG) at the IdP via RFC 8693 token exchange, then presents the ID-JAG
to the MCP authorization server with the RFC 7523 `jwt-bearer` grant, authenticating with `client_secret_basic`. There is no authorization request, PKCE, DCR, or `offline_access`.
Mirrors `CrossAppAccessProvider` and `requestJwtAuthorizationGrant` in the TypeScript SDK.

`MCP::Client::OAuth::IDJAGTokenExchange.request` performs the RFC 8693 exchange at the IdP token endpoint. Wrap it in a callable so the same provider can plug into
an enterprise secret store or a test double without changing the transport wiring.

```ruby
provider = MCP::Client::OAuth::CrossAppAccessProvider.new(
  client_id: "my-mcp-client",
  client_secret: ENV.fetch("MCP_CLIENT_SECRET"),
  assertion_provider: ->(audience:, resource:) {
    MCP::Client::OAuth::IDJAGTokenExchange.request(
      token_endpoint: "https://idp.example.com/token",
      id_token: ENV.fetch("IDP_ID_TOKEN"),
      client_id: "my-idp-client",
      audience: audience,
      resource: resource,
    )
  },
  # scope: "mcp:read mcp:write" (optional; used when neither WWW-Authenticate nor PRM specify one)
)

transport = MCP::Client::HTTP.new(url: "https://api.example.com/mcp", oauth: provider)
```

Keyword arguments:

- `client_id`, `client_secret`: Required. The `jwt-bearer` grant authenticates with `client_secret_basic` at the MCP authorization server.
- `assertion_provider`: Required. Callable invoked as `call(audience:, resource:)` and returning the ID-JAG assertion.
  `audience` is the MCP authorization server's validated issuer identifier; `resource` is the canonical MCP server URL (RFC 8707).
  Passing both through to `IDJAGTokenExchange.request` covers the common case.
- `scope`, `storage`: Optional, same meaning as on `Provider`.

### Communication Security

When `oauth:` is set, the MCP transport URL and every OAuth-facing URL (PRM, Authorization Server metadata, `authorization_endpoint`, `token_endpoint`, `registration_endpoint`,
`redirect_uri`) must use HTTPS or a loopback host. Non-loopback `http://` URLs are rejected at the SDK boundary so a bearer token is never sent over plain HTTP to a remote host.

The transport also snapshots the canonicalized origin, path, and query string of the MCP URL at `initialize` time and re-checks them on every outgoing request through
a Faraday middleware that runs after any user-supplied customizer. That means any URL swap raises `MCP::Client::HTTP::InsecureURLError` before the request reaches the adapter,
whether the swap was triggered by
`instance_variable_set(:@url, ...)`, by a Faraday customizer rewriting `url_prefix`, or by a custom middleware rewriting `env.url` (including just `env.url.query`) at request time,
and whether the new URL is `http://` *or* `https://` to a different host or tenant.

### Discovery URL Destinations

The scheme rules above say how a URL is contacted, not where it points. Discovery URLs arrive from the network, so the SDK also constrains their destinations.
Both checks run before the request is sent, and neither is configurable.

- The `resource_metadata` URL in a `WWW-Authenticate` challenge must be on the MCP server's own origin. Protected Resource Metadata describes that server,
  so a real deployment publishes it there; requiring it means a `401` cannot aim the first request of the flow at an unrelated host. This is stricter than RFC 9728,
  which does not require it.
- The PRM `authorization_servers` entry and the `authorization_endpoint`, `token_endpoint`, and `registration_endpoint` from Authorization Server metadata must not be
  IP literals in a private, loopback, link-local, or unique-local range, per the SSRF precaution in [RFC 9728 Section 7.7](https://www.rfc-editor.org/rfc/rfc9728#section-7.7).
  The blocked ranges are `0.0.0.0/8`, `10.0.0.0/8`, `100.64.0.0/10`, `127.0.0.0/8`, `169.254.0.0/16`, `172.16.0.0/12`, `192.168.0.0/16`, `::/96`, `fc00::/7`,
  and `fe80::/10`, along with the IPv4-mapped IPv6 spellings of each and the `localhost` name.
- That range check is skipped when the MCP server URL you configured is itself on such an address. Pointing the client at a private network is a deliberate act,
  and the authorization server for it usually lives on the same network, so `http://localhost` development and deployments that never leave a corporate network keep working.

The range check compares IP literals and does not resolve hostnames, so it cannot recognize an internal service that is named rather than addressed,
such as `https://vault.corp.internal/`. Resolving names here would not close that gap either, because the address the SDK looked up need not be the one
the HTTP client connects to a moment later. The same-origin rule is what protects the `resource_metadata` URL, which is the only one of these a server supplies directly.

If you replace the OAuth HTTP client through `MCP::Client::OAuth::Flow.new(http_client_factory:)`, do not add redirect-following middleware. Every check above runs against
the URL as written, so a connection that follows a `3xx` on its own would reach hosts these rules just refused.

The SDK also bounds what those endpoints may return. A discovery, dynamic client registration, token, or token exchange response is refused once it passes 4 MiB,
measured as the body arrives rather than after it has been buffered, so a compressed body that expands past the limit is refused partway through the expansion.
Unlike the transport's `max_message_bytes:`, this limit is not configurable: these documents run to kilobytes in normal operation, and a connection supplied through
`http_client_factory:` is bounded as well, so there is no way to opt out of it.
