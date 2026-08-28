---
layout: default
title: Cancellation
nav_order: 13
---

# Cancellation

The MCP Ruby SDK supports server-side handling of
the [MCP `notifications/cancelled` utility](https://modelcontextprotocol.io/specification/latest/basic/patterns/cancellation).
When a client sends `notifications/cancelled` for an in-flight request, the server stops
processing cooperatively and suppresses the JSON-RPC response for that request.

Cancellation is cooperative: the SDK does not forcibly terminate tool code. Instead,
a `MCP::Cancellation` token is threaded through [`server_context`](/server/server-context/), and long-running tools
poll it to exit early. When a tool returns after cancellation has been observed,
the server suppresses the JSON-RPC response, matching the spec. The `initialize` request
is never cancellable per the spec.

{: .note }
> Cancellation by notification belongs to the handshake lifecycle, where the session correlates
> `notifications/cancelled` with the in-flight request it targets. Requests of the
> [modern lifecycle](/server/discover/#the-stateless-modern-lifecycle) are sessionless single POST exchanges, so a separately
> POSTed cancel notification cannot reach them; a modern client abandons a request by closing
> the connection instead.

## Handlers that Check for Cancellation

Any handler that opts in to `server_context:` - tools (`Tool.call`), prompt templates,
`resources_read_handler`, `resources_list_handler`, `completion_handler`, `resources_subscribe_handler`,
`resources_unsubscribe_handler`, and [`define_custom_method`](/server/custom-methods/) blocks - receives
an `MCP::ServerContext` wired to the in-flight request's cancellation token.
Handlers check `cancelled?` in their work loop, or call `raise_if_cancelled!` to raise
`MCP::CancelledError` at a safe point:

```ruby
class LongRunningTool < MCP::Tool
  description "A tool that supports cancellation"
  input_schema(properties: { count: { type: "integer" } }, required: ["count"])

  def self.call(count:, server_context:)
    count.times do |i|
      # Exit early if the client has sent `notifications/cancelled`.
      break if server_context.cancelled?

      do_work(i)
    end

    MCP::Tool::Response.new([{ type: "text", text: "Done" }])
  end
end
```

Alternatively, raise at the next safe point with `raise_if_cancelled!`:

```ruby
def self.call(count:, server_context:)
  count.times do |i|
    server_context.raise_if_cancelled!

    do_work(i)
  end

  MCP::Tool::Response.new([{ type: "text", text: "Done" }])
end
```

When a handler observes cancellation (either by returning early with `cancelled?` or
by raising `MCP::CancelledError` via `raise_if_cancelled!`), the server drops the response and
no JSON-RPC result is sent to the client.

The same pattern works for other handler types:

```ruby
# resources/read
server.resources_read_handler do |params, server_context:|
  server_context.raise_if_cancelled!
  # read the resource
end

# completion/complete
server.completion_handler do |params, server_context:|
  server_context.raise_if_cancelled!
  # compute completions
end

# custom method
server.define_custom_method(method_name: "custom/slow") do |params, server_context:|
  server_context.raise_if_cancelled!
  # do work
end

# prompts (via Prompt subclass)
class SlowPrompt < MCP::Prompt
  prompt_name "slow_prompt"

  def self.template(args, server_context:)
    server_context.raise_if_cancelled!
    MCP::Prompt::Result.new(messages: [])
  end
end
```

Handlers that do not declare a `server_context:` keyword continue to work unchanged -
the opt-in detection only wraps the context when the block signature asks for it.

## Nested Server-to-Client Requests Are Cancelled Automatically

When a tool handler is waiting on a nested server-to-client request
(`server_context.create_sampling_message`, `create_form_elicitation`, or
`create_url_elicitation`), cancelling the parent tool call automatically raises
`MCP::CancelledError` from the nested call, so the tool does not need to wrap it
in its own `cancelled?` checks:

```ruby
def self.call(server_context:)
  result = server_context.create_sampling_message(messages: messages, max_tokens: 100)
  # If the parent tools/call is cancelled while waiting above, MCP::CancelledError
  # is raised here and the tool can let it propagate or clean up as needed.
  MCP::Tool::Response.new([{ type: "text", text: result[:content][:text] }])
rescue MCP::CancelledError
  # Optional: run cleanup. Re-raising (or letting it propagate) is fine; the server
  # will still suppress the JSON-RPC response per the MCP spec.
  raise
end
```

Nested cancellation propagation is supported on `StreamableHTTPTransport` only.
`StdioTransport` is single-threaded and blocks on `$stdin.gets`, so a nested
`server_context.create_sampling_message` inside a tool runs to completion even if
the parent `tools/call` is cancelled. The parent tool itself still observes cancellation
via `server_context.cancelled?` between nested calls.

## Client Side

Cancelling a request the client has issued (the `cancellation:` keyword, wire-order guarantees,
and custom transport requirements) is documented on the client [Cancellation](/client/cancellation/) page.
