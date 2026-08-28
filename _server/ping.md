---
layout: default
title: Ping
nav_order: 15
---

# Ping

The MCP Ruby SDK supports
the [MCP `ping` utility](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/ping),
which allows either side of the connection to verify that the peer is still responsive.
A `ping` request has no parameters, and the receiver MUST respond promptly with an empty result.

{: .note }
> `ping` belongs to the handshake lifecycle: MCP 2026-07-28 removes the method altogether (SEP-2575),
> since requests of the [modern lifecycle](/server/discover/#the-stateless-modern-lifecycle) are single POST exchanges whose connection
> itself signals liveness, leaving nothing to probe between requests. The server answers `ping` on
> the handshake lifecycle only - a modern request naming it is rejected with `-32601` Method not found -
> and calling `ping` on a `server_context` while serving a modern request raises an error. The long-lived
> [`subscriptions/listen`](/server/subscriptions/) stream is kept alive by SSE keepalive
> frames instead.

Servers respond to incoming `ping` requests automatically - no setup is required.
Any `MCP::Server` instance replies with an empty result.

Servers can also send `ping` requests to the client via `ServerSession#ping`.
`ping` is exempt from the SEP-2260 association requirement, so it may also be sent outside a handler.
Inside a tool handler that receives [`server_context:`](/server/server-context/), call `ping` on it:

```ruby
class HealthCheckTool < MCP::Tool
  description "Verifies the client is still responsive"

  def self.call(server_context:)
    server_context.ping # => {} on success

    MCP::Tool::Response.new([{ type: "text", text: "client is alive" }])
  end
end
```

`#ping` raises `MCP::Server::ValidationError` when the client returns a `result`
that is not a Hash. Transport-level errors (e.g., the client returning a JSON-RPC error)
propagate as exceptions raised by the transport layer.

Server-to-client requests are bounded by a timeout on the Streamable HTTP transport; see [Timeouts](/server/elicitation/#timeouts).

## Client Side

Pinging the server with `MCP::Client#ping` is documented on the client [Ping](/client/ping/) page.
