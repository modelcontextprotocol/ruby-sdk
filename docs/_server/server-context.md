---
layout: default
title: Server Context
nav_order: 19
---

# Server Context

The `server_context` is a user-defined hash that is passed into the server instance and made available to [tool](/server/tools/) and [prompt](/server/prompts/) calls.
It can be used to provide contextual information such as authentication state, user IDs, or request-specific data.

**Type:**

```ruby
server_context: { [String, Symbol] => Any }
```

**Example:**

```ruby
server = MCP::Server.new(
  name: "my_server",
  server_context: { user_id: current_user.id, request_id: request.uuid }
)
```

This hash is then passed as the `server_context` keyword argument to tool and prompt calls.
Note that the exception reporter does not receive this user-defined hash, and instrumentation
callbacks omit it unless you opt in with `instrument_server_context`.
See the [Configuration](/server/configuration/) page for the arguments they receive.

## Request-specific `_meta` Parameter

The MCP protocol supports a special [`_meta` parameter](https://modelcontextprotocol.io/specification/latest/basic#general-fields) in requests that allows clients to pass request-specific metadata. The server automatically extracts this parameter and makes it available to tools and prompts as a nested field within the `server_context`.

{: .note }
> `_meta` is only merged when `server_context` is a `Hash` (or `nil`, in which case a new `{ _meta: ... }` hash is synthesized).
> If you assign a non-`Hash` value to `server_context`, `_meta` is not merged and tools will not see it
> under `server_context[:_meta]`. Keep `server_context` as a `Hash` if your tools need access to `_meta`.

**Access Pattern:**

When a client includes `_meta` in the request params, it becomes available as `server_context[:_meta]`:

```ruby
class MyTool < MCP::Tool
  def self.call(message:, server_context:)
    # Access provider-specific metadata
    session_id = server_context.dig(:_meta, :session_id)
    request_id = server_context.dig(:_meta, :request_id)

    # Access server's original context
    user_id = server_context.dig(:user_id)

    MCP::Tool::Response.new([{
      type: "text",
      text: "Processing for user #{user_id} in session #{session_id}"
    }])
  end
end
```

**Client Request Example:**

A `tools/call` request carrying `_meta`, as read by the tool above:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "my_tool",
    "arguments": { "message": "Hello" },
    "_meta": {
      "session_id": "abc123",
      "request_id": "req_456"
    }
  }
}
```

### Distributed Tracing

Per SEP-414, the keys `traceparent`, `tracestate`, and `baggage` are reserved un-prefixed `_meta` keys for propagating
[W3C Trace Context](https://www.w3.org/TR/trace-context/) across MCP requests. The SDK guarantees these keys pass through
incoming request `_meta` untouched, and exposes their names as constants on `MCP::TraceContext` (`TRACEPARENT_META_KEY`,
`TRACESTATE_META_KEY`, `BAGGAGE_META_KEY`, and `META_KEYS`). The SDK does not depend on OpenTelemetry; bridge the values
to your tracing system yourself:

```ruby
class TracedTool < MCP::Tool
  def self.call(message:, server_context:)
    traceparent = server_context.dig(:_meta, :traceparent)
    # Hand traceparent/tracestate/baggage to your tracing library
    # (e.g. the opentelemetry-ruby gems) to continue the caller's trace.

    MCP::Tool::Response.new([{ type: "text", text: "ok" }])
  end
end
```

On the client side, every request method (`call_tool`, `read_resource`, `get_prompt`, `complete`, `ping`, and the `list_*` methods)
accepts a `meta:` keyword to inject these keys into the outgoing request, so trace context can flow on every request:

```ruby
meta = { MCP::TraceContext::TRACEPARENT_META_KEY => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" }

client.call_tool(tool: tool, arguments: { message: "Hello" }, meta: meta)
client.read_resource(uri: "file:///report.txt", meta: meta)
```
