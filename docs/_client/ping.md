---
layout: default
title: Ping
nav_order: 6
---

# Ping

The [MCP `ping` utility](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/ping)
allows either side of the connection to verify that the peer is still responsive.

{: .note }
> MCP 2026-07-28 removes `ping` from the protocol (SEP-2575): requests of
> the [modern lifecycle](/client/lifecycle/) are single POST exchanges whose connection itself
> signals liveness. `#ping` sends the request regardless of the negotiated lifecycle,
> so on a modern connection a conforming server (the Ruby SDK server included) rejects it
> with `-32601` Method not found and `ServerError` is raised; ping is a handshake-lifecycle utility.

`MCP::Client` exposes `ping` to send a ping to the server:

```ruby
client = MCP::Client.new(transport: transport)
client.ping # => {} on success
```

`#ping` raises `MCP::Client::ServerError` when the server returns a JSON-RPC error.
It raises `MCP::Client::ValidationError` when the response `result` is missing or
is not a Hash (matching the spec requirement that `result` be an object).
Transport-level errors (for example, `MCP::Client::Stdio`'s `read_timeout:` firing)
propagate as exceptions raised by the transport layer.

## Answering Server Pings

On handshake-lifecycle connections a server may ping the client the same way, and the client answers automatically with
the empty result - no handler is needed. Registering `transport.on_server_request("ping")` on `MCP::Client::HTTP` replaces
the automatic answer.
Over stdio, a ping that arrives while a response is awaited is answered inline; between requests it is answered when
the next request starts reading. The answer is best effort: a pong that cannot be written (for example, over a broken pipe) is
dropped rather than failing the request whose response is being read. Independently of pings, consider setting `read_timeout:`
on `MCP::Client::Stdio`, since a server that never answers otherwise holds the read until the process exits.

## Server Side

How servers answer `ping` requests and ping the client themselves is documented on
the server [Ping](/server/ping/) page.
