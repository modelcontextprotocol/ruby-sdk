---
layout: default
title: Protocol Versions
nav_order: 4
permalink: /protocol-versions/
---

# Protocol Versions

The SDK supports the following MCP protocol versions:

| Version      | Era       | Notes                                                                                           |
|--------------|-----------|-------------------------------------------------------------------------------------------------|
| `2026-07-28` | Modern    | Stateless lifecycle: no handshake, version carried on every request (SEP-2575)                  |
| `2025-11-25` | Handshake | The default handshake version; adds URL mode elicitation, enum schemas, and sampling tools      |
| `2025-06-18` | Handshake | Adds elicitation, structured tool output, and OAuth resource servers; removes JSON-RPC batching |
| `2025-03-26` | Handshake | Adds Streamable HTTP, OAuth 2.1 authorization, tool annotations, and audio content              |
| `2024-11-05` | Handshake | Initial protocol revision                                                                       |

## The Era Model

Per the SEP-2575 era model, an era is a property of the protocol version itself:

- **The modern version** (`2026-07-28`) has no handshake at all: clients discover the server through
  [`server/discover`](/server/discovery/), and every request carries its version in the `_meta` envelope,
  validated per request.
- **Handshake versions** (`2025-11-25` and earlier) establish a session through the `initialize` handshake.
  The server offers `2025-11-25` by default, and the version can be pinned with `MCP::Configuration.new(protocol_version:)`;
  see [Server Protocol Version](/server/configuration/#server-protocol-version).

Pinning the server's handshake version:

```ruby
configuration = MCP::Configuration.new(protocol_version: "2025-06-18")
MCP::Server.new(name: "my_server", configuration: configuration)
```

The handshake never negotiates a modern version: a client asking `initialize` for `2026-07-28` is counter-offered
the latest handshake version, matching the TypeScript and Python SDKs. The bundled transports serve both eras
side by side with no configuration needed.

## Client Negotiation

`MCP::Client#connect` negotiates the lifecycle automatically by default: it probes `server/discover` and adopts
the modern lifecycle when the server serves it, falling back to the `initialize` handshake otherwise.
`connect(mode: :modern)`, `connect(mode: :legacy)`, and an explicit `protocol_version:` pin select a lifecycle
directly; see [Lifecycle](/client/lifecycle/).

```ruby
client.connect                                 # negotiate automatically (default)
client.connect(mode: :modern)                  # require the modern lifecycle
client.connect(mode: :legacy)                  # force the classic initialize handshake
client.connect(protocol_version: "2025-11-25") # pin the handshake version, no probe
```

## Deprecations

The `2026-07-28` revision deprecates [Roots](/server/roots/), [Sampling](/server/sampling/), and
[Logging](/server/logging/) per SEP-2577; all three remain fully supported on the handshake versions.

Check the [MCP specification](https://modelcontextprotocol.io/specification/versioning) to understand what each
protocol version includes.
