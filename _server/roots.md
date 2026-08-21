---
layout: default
title: Roots
nav_order: 7
---

# Roots

The Model Context Protocol allows servers to request filesystem roots from clients through the `roots/list` method.
Roots define the boundaries of where a server can operate, providing a list of directories and files the client has made available.

{: .warning }
> MCP Roots (`roots/list` and `notifications/roots/list_changed`) is deprecated as of protocol version `2026-07-28` (SEP-2577),
> while remaining fully supported under `2025-11-25`. Prefer tool parameters, resource URIs, server configuration, or environment
> variables for new servers. A client declaring the `roots` capability on a modern connection emits a deprecation warning.

{: .important }
> Per SEP-2260, server-to-client requests (`roots/list`, `sampling/createMessage`, `elicitation/create`) must be associated with
> an originating client request (`ping` is exempt). Use the `server_context` passed to your handler, which stamps the association
> automatically and routes the request onto the originating POST stream on the Streamable HTTP transport. Calling the corresponding
> `ServerSession` methods without `related_request_id:` still works but emits a deprecation warning.

Server-to-client requests are bounded by a timeout on the Streamable HTTP transport; see [Timeouts](/server/elicitation/#timeouts).

## Key Concepts

- **Server-to-Client Request**: Like [sampling](/server/sampling/), roots listing is initiated by the server
- **Client Capability**: Clients must declare `roots` capability during initialization
- **Change Notifications**: Clients that support `roots.listChanged` send `notifications/roots/list_changed` when roots change

## Using Roots in Tools

Tools that accept a [`server_context:`](/server/server-context/) parameter can call `list_roots` on it.
The request is automatically routed to the correct client session:

```ruby
class FileSearchTool < MCP::Tool
  description "Search files within the client's project roots"
  input_schema(
    properties: {
      query: { type: "string" }
    },
    required: ["query"]
  )

  def self.call(query:, server_context:)
    roots = server_context.list_roots
    root_uris = roots[:roots].map { |root| root[:uri] }

    MCP::Tool::Response.new([{
      type: "text",
      text: "Searching in roots: #{root_uris.join(", ")}"
    }])
  end
end
```

Result contains an array of root objects:

```ruby
{
  roots: [
    { uri: "file:///home/user/projects/myproject", name: "My Project" },
    { uri: "file:///home/user/repos/backend", name: "Backend Repository" }
  ]
}
```

## Handling Root Changes

Register a callback to be notified when the client's roots change:

```ruby
server.roots_list_changed_handler do
  puts "Client's roots have changed, tools will see updated roots on next call."
end
```

## Error Handling

- Raises `RuntimeError` if client does not support `roots` capability
- Raises `StandardError` if client returns an error response
