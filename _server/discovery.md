---
layout: default
title: Discovery
nav_order: 3
---

# Discovery

`server/discover` is the sessionless capability discovery method of MCP 2026-07-28 (SEP-2575).
It responds before `initialize` and without an `Mcp-Session-Id`, so a client learns what a server
offers in a single exchange, without creating a session.

## The Discovery Result

The result carries the modern `supportedVersions`, `capabilities`, and `instructions`, together with
the required `ttlMs`/`cacheScope` cache hints, and the server identity as the optional
`io.modelcontextprotocol/serverInfo` stamp in the result `_meta`.

The request takes no parameters:

```json
{ "jsonrpc": "2.0", "id": 1, "method": "server/discover" }
```

The server answers with the full discovery result:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "supportedVersions": ["2026-07-28"],
    "capabilities": { "tools": { "listChanged": true } },
    "instructions": "Use the tools of this server as a last resort",
    "_meta": { "io.modelcontextprotocol/serverInfo": { "name": "my_server", "version": "1.0.0" } },
    "ttlMs": 0,
    "cacheScope": "private",
    "resultType": "complete"
  }
}
```

## The Stateless Modern Lifecycle

Beyond answering `server/discover`, the server serves the full stateless modern lifecycle: requests carrying the SEP-2575 `_meta` envelope
(`io.modelcontextprotocol/protocolVersion`, `clientInfo`, and `clientCapabilities`) are validated per request,
and the Streamable HTTP transport serves them on a sessionless single-exchange path.
Calling `server/discover` first is not required: the envelope alone selects the modern lifecycle for a request,
while a client performing the classic `initialize` handshake is served on the handshake lifecycle -
the lifecycle is a per-request property, not a server-wide mode.

The bundled transports serve `server/discover` and the per-request `_meta` envelope alongside the `initialize` handshake
with no configuration needed. The `protocol_version` pin scopes the handshake only
and does not affect the modern lifecycle; see [Configuration](/server/configuration/) for details.

## Client Side

On the client, `MCP::Client#connect` negotiates the lifecycle automatically by default
(probe `server/discover`, fall back to the `initialize` handshake), `connect(mode: :modern)` skips
the handshake entirely, `connect(mode: :legacy)` forces the classic handshake, and `MCP::Client#discover`
exposes the raw discovery result. See the client-side [Lifecycle](/client/lifecycle/) page for details.
