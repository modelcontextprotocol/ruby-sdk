---
layout: default
title: Capability Extensions
nav_order: 2
---

# Capability Extensions

Per SEP-2133, both clients and servers can declare protocol extensions under the `extensions` member of their capabilities.
Keys are extension identifiers using the reverse-DNS prefix convention (e.g. `"io.modelcontextprotocol/tasks"`, `"com.example/feature"`);
values are extension-defined configuration objects, with `{}` meaning "supported with no settings".

On the server, declare extensions through the `capabilities` keyword, either as a plain hash or via the `MCP::Server::Capabilities` builder:

```ruby
capabilities = MCP::Server::Capabilities.new
capabilities.support_tools
capabilities.support_extensions("com.example/feature" => { enabled: true })

server = MCP::Server.new(name: "my_server", capabilities: capabilities)
```

The declared extensions appear in the `initialize` result's `capabilities.extensions`. Extensions the client declared during `initialize` are
readable via `server.client_capabilities[:extensions]` (or `session.client_capabilities[:extensions]` for per-session transports).

On the [modern lifecycle](/server/discovery/#the-stateless-modern-lifecycle), the same declarations appear in the `server/discover` result,
and the client's extensions ride each request's `_meta` envelope instead of an `initialize` handshake.
Inside a handler, `server_context.client_capabilities[:extensions]` reads the current request's declarations
with envelope-first resolution, on either lifecycle.

On the client, pass extensions through `connect`:

```ruby
client.connect(capabilities: { extensions: { "com.example/feature" => {} } })
```
