---
layout: default
title: Lifecycle
nav_order: 3
---

# Lifecycle

Before sending requests, a client establishes its lifecycle with the server: the classic `initialize` handshake
on legacy protocol versions, or the sessionless modern lifecycle of MCP 2026-07-28.
This page covers `MCP::Client#connect` and how it negotiates between the two.

## Handshake

Call `MCP::Client#connect` to perform the MCP [initialization handshake](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle#initialization) before sending any other requests. The client sends an `initialize` request through the transport, followed by the required `notifications/initialized` notification, and caches the server's `InitializeResult` (protocol version, capabilities, server info, instructions):

```ruby
client.connect
# => { "protocolVersion" => "2025-11-25", "capabilities" => {...}, "serverInfo" => {...} }

client.connected?  # => true
client.server_info # => cached InitializeResult
```

`connect` accepts optional `client_info:`, `protocol_version:`, and `capabilities:` keyword arguments. It is idempotent: a second call returns the cached result without contacting the server. After `close`, state is cleared and `connect` will handshake again.

This applies to both the Stdio and HTTP transports described on the [Transports](/client/transports/) page.

By default `connect` [negotiates the lifecycle](#lifecycle-negotiation) first and performs this handshake
only when the server does not serve the modern lifecycle, or when `mode: :legacy` or a legacy `protocol_version:` forces it.

## Lifecycle Negotiation

`MCP::Client#connect` selects the protocol lifecycle automatically by default: on the bundled
`MCP::Client::HTTP` and `MCP::Client::Stdio` transports it probes [`server/discover`](/server/discover/) first and adopts
the stateless modern lifecycle (MCP 2026-07-28, SEP-2575) when the server serves it, falling back to
the classic `initialize` handshake otherwise. Custom transports whose `connect` does not declare
a `mode:` keyword always receive the classic call shape, unchanged.

```ruby
client.connect                                 # negotiate automatically (default)
client.connect(mode: :modern)                  # require the modern lifecycle; fails on legacy-only servers
client.connect(mode: :legacy)                  # force the classic initialize handshake
client.connect(protocol_version: "2025-11-25") # an explicit legacy version pins the handshake, no probe
```

Prefer `mode: :legacy` for spawn-per-invocation CLI tools (the probe adds a round trip per process)
and when using server-initiated requests (`on_elicitation` / `on_sampling`), which exist only on
the legacy lifecycle.

Because the raw `connect` return value and `MCP::Client#server_info` mirror the wire result,
their shape depends on the negotiated lifecycle: `InitializeResult` (`protocolVersion`,
top-level `serverInfo`) on legacy, `DiscoverResult` (`supportedVersions`, `ttlMs`/`cacheScope`)
on modern. Code that should work against both lifecycles can use the era-independent readers instead:

```ruby
client.protocol_version      # negotiated or adopted version, either lifecycle
client.server_capabilities   # capabilities Hash, either lifecycle
client.instructions          # instructions text, either lifecycle
client.server_implementation # server name/version; nil when a modern server does not identify itself
```

Troubleshooting: if `server_info["protocolVersion"]` starts returning `nil` after a server you connect to was upgraded,
the server now serves the modern lifecycle and the automatic negotiation adopted it.
Pass `mode: :legacy` for an immediate return to the previous behavior, or switch to the readers above for a permanent fix.

## Explicit Discovery

`MCP::Client#discover` sends `server/discover` directly: sessionless capability discovery
that works before (or instead of) `connect`. It returns an `MCP::Client::DiscoverResult` struct
exposing `supported_versions`, `capabilities`, `server_info`, `instructions`, and
the `ttl_ms` / `cache_scope` cache hints; see the server [Discovery](/server/discover/) page
for the wire shapes.

```ruby
result = client.discover
result.supported_versions # => ["2026-07-28"]
```
