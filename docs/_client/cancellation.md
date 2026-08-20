---
layout: default
title: Cancellation
nav_order: 5
---

# Cancellation

`MCP::Client` lets the caller cancel a request it has already issued,
per the [MCP `notifications/cancelled` utility](https://modelcontextprotocol.io/specification/latest/basic/patterns/cancellation).
The recommended pattern is to pass
an `MCP::Cancellation` token into the request method, run the request on a worker thread, and call
`cancellation.cancel(reason:)` from another thread. The cancelling thread sends `notifications/cancelled` to
the server, and the calling thread is woken up with `MCP::CancelledError`:

```ruby
client = MCP::Client.new(transport: transport)
cancellation = MCP::Cancellation.new

Thread.new do
  client.call_tool(name: "slow_tool", arguments: {}, cancellation: cancellation)
rescue MCP::CancelledError
  # cleanup
end

# Later, from another thread:
cancellation.cancel(reason: "user pressed cancel")
```

All request methods (`tools`, `list_tools`, `resources`, `list_resources`, `resource_templates`, `list_resource_templates`,
`prompts`, `list_prompts`, `call_tool`, `read_resource`, `get_prompt`, `complete`, `discover`, `ping`) accept the `cancellation:` keyword.
Request ids are managed internally, so the token is the only thing a caller needs to cancel a request.

{: .note }
> When a cancel wins the race, the SDK's worker thread that is blocked on the underlying I/O is *not* force-killed;
> it stays blocked until the transport actually returns (or the user closes the transport). This matches the server-side
> `StreamableHTTPTransport#send_request` trade-off. For `Client::HTTP`
> the leak resolves as soon as the server sends any response; for `Client::Stdio` you may need to call `client.transport.close`
> to free the thread if the server stops responding entirely. The cancel-dispatch thread waits for the worker's send-boundary signal
> (`&on_sent` from `send_request`) before issuing `notifications/cancelled`, so the cancel is held until the worker has at
> least committed to writing the request; while the worker is wedged the cancel notification is deferred along with it.

{: .note }
> On a [modern](/client/lifecycle/) connection the cancel notification cannot reach the in-flight
> request: correlating the two is a session mechanic of the handshake lifecycle, and modern requests
> are sessionless single POST exchanges. The local effect is unchanged - the calling thread still
> raises `MCP::CancelledError` - but the server runs the request to completion.

## Wire-order guarantees

`Client::Stdio` serializes the request write and any subsequent `notifications/cancelled` write through a single `@write_mutex`,
so the server is guaranteed to read the request line before the cancel line.

`Client::HTTP` cannot offer the same wire-arrival guarantee. Faraday's synchronous `post` does not expose a post-write / pre-response hook,
so the SDK yields just before the request POST is dispatched. After the yield, the cancel-dispatch thread issues a separate `notifications/cancelled` POST
on its own connection, and the two POSTs may overlap on the network. The spec is satisfied either way: the sender has already issued the request and
still believes it to be in-progress when issuing the cancel ([MCP cancellation spec](https://modelcontextprotocol.io/specification/latest/basic/patterns/cancellation)),
and on the receiver side, "receivers MAY ignore a cancellation notification whose `requestId` is unknown" covers the case where the cancel POST
happens to arrive first. The calling thread raises `MCP::CancelledError` regardless of network ordering.

## Custom transports

Custom transports that want to support `cancellation:` must implement `send_notification(notification:)` so `notifications/cancelled` can be delivered.
They should also accept the optional block passed to `send_request(request:, &on_sent)` and call it once the request bytes have been handed off to the wire
(under a write-side mutex for stdio-style transports, immediately before the synchronous round-trip for HTTP-style transports).
The cancel-dispatch thread waits on this signal before sending `notifications/cancelled`. Transports that do not invoke the block fall back to waiting for
the worker thread to terminate, which preserves wire-order at the cost of delaying the cancel notification until the request has fully completed.

## Server Side

How servers observe cancellation in their handlers is documented on the server [Cancellation](/server/cancellation/) page.
