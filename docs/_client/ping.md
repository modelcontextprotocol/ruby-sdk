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

## Server Side

How servers answer `ping` requests and ping the client themselves is documented on
the server [Ping](/server/ping/) page.
