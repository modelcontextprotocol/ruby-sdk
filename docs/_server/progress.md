---
layout: default
title: Progress
nav_order: 14
---

# Progress

The MCP Ruby SDK supports progress tracking for long-running tool operations,
following the [MCP Progress specification](https://modelcontextprotocol.io/specification/latest/server/utilities/progress).

## How Progress Works

1. **Client Request**: The client sends a `progressToken` in the `_meta` field when calling a tool
2. **Server Notification**: The server sends `notifications/progress` messages back to the client during tool execution
3. **Tool Integration**: Tools call `server_context.report_progress` to report incremental progress

## Reporting Progress from Tools

Tools that accept a [`server_context:`](/server/server-context/) parameter can call `report_progress` on it.
The server automatically wraps the context in an `MCP::ServerContext` instance that provides this method:

```ruby
class LongRunningTool < MCP::Tool
  description "A tool that reports progress during execution"
  input_schema(
    properties: {
      count: { type: "integer" },
    },
    required: ["count"]
  )

  def self.call(count:, server_context:)
    count.times do |i|
      # Do work here.
      server_context.report_progress(i + 1, total: count, message: "Processing item #{i + 1}")
    end

    MCP::Tool::Response.new([{ type: "text", text: "Done" }])
  end
end
```

The `server_context.report_progress` method accepts:

- `progress` (required) - current progress value (numeric)
- `total:` (optional) - total expected value, so clients can display a percentage
- `message:` (optional) - human-readable status message

`report_progress` is a no-op when the request carried no `progressToken`, and both numeric and
string tokens are supported.

{: .note }
> On the [modern lifecycle](/server/discover/#the-stateless-modern-lifecycle), progress notifications emitted during a request ride
> the request's own SSE response stream. The bundled transport buffers them and flushes after
> the handler returns, so they preserve order but arrive together with the final response rather
> than in real time.

## Client Side

Requesting progress is the client's side of the contract: pass `progress_token:` to `MCP::Client#call_tool`
and the token is sent as `_meta.progressToken`, as shown on the client [Transports](/client/transports/) page.
The bundled client transports do not currently expose a callback for observing the incoming `notifications/progress` messages;
the token's effect is visible on the server side only.
