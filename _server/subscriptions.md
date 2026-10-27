---
layout: default
title: Subscriptions
nav_order: 13
redirect_from:
  - /server/notification-subscriptions/
---

# Subscriptions

`subscriptions/listen` is the long-lived notification subscription stream of MCP 2026-07-28 (SEP-2575),
replacing the legacy HTTP GET listening stream.

## Subscribing

The client opts in via the `notifications` filter (`toolsListChanged` / `promptsListChanged` / `resourcesListChanged` / `resourceSubscriptions`),
the server acknowledges the honored subset with `notifications/subscriptions/acknowledged` as the first stream message,
and every delivered notification carries the correlating `io.modelcontextprotocol/subscriptionId` in `_meta`.
The honored subset follows the capabilities the server declares (`listChanged` and `subscribe` flags).

`subscriptions/listen` takes the place of `resources/subscribe` in this lifecycle, so the URIs in `resourceSubscriptions`
are passed to `Server#resources_subscribe_handler` one at a time, each as `{ uri: }`,
with the listen request's `_meta` added when it carries one, and, when the handler declares it, a `server_context` holding the request's `auth_info`.
A URI the handler raises for is left out of the acknowledgement, and the stream receives no `notifications/resources/updated` for it.
Only whether the handler raised counts: its return value, including `false`, `nil`, or a `{ _meta: ... }` Hash, is discarded and accepts the URI.
Unlike a `resources/subscribe` request, the `server_context` has no session, related request id, or cancellation,
so session-scoped helpers such as `notify_resources_updated` do nothing there.

The handler is consulted once, when the stream opens, and its decision is not re-evaluated while the stream stays open,
so a later change in its answer takes effect only on a new stream.
An authenticated stream ends under the stream expiry rules in [Authorization](/server/authorization/),
and any stream ends when either side closes the connection or the transport closes.

Each URI the handler raises for is reported to the exception reporter, one report per denied URI as for a denied `resources/subscribe` request,
so a listen request naming many denied URIs produces as many reports.

Whatever the handler records, such as a watcher or a counter, gets no paired cleanup.
`resources_unsubscribe_handler` is not called when the stream ends, since the subscription lasts as long as the stream,
and the handler may have run for a request that then opens no stream,
such as one refused when two listen requests race for the last slot under `max_listen_subscriptions:`.

```ruby
server.resources_subscribe_handler do |params, server_context:|
  unless readable?(server_context.auth_info, params[:uri])
    raise MCP::Server::RequestHandlerError.new("Forbidden", params, error_type: :invalid_params)
  end
end
```

The client opens the stream with a `subscriptions/listen` request:

```json
{
  "jsonrpc": "2.0",
  "id": "listen-1",
  "method": "subscriptions/listen",
  "params": {
    "notifications": { "toolsListChanged": true, "resourceSubscriptions": ["file:///a.txt"] },
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientInfo": { "name": "my_client", "version": "1.0.0" },
      "io.modelcontextprotocol/clientCapabilities": {}
    }
  }
}
```

The first SSE event on the stream is the acknowledgement:

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/subscriptions/acknowledged",
  "params": {
    "notifications": { "toolsListChanged": true, "resourceSubscriptions": ["file:///a.txt"] },
    "_meta": { "io.modelcontextprotocol/subscriptionId": "listen-1" }
  }
}
```

## Delivery Semantics

A stream delivers only the changes that happen after its acknowledgement; it is not a replay log.
Nothing is queued while no stream is connected, and a dropped stream is gone together with anything it missed.
Clients fetch the current state after subscribing and treat each notification as a cue to refetch,
rather than as a payload.

## Transport Support

The stream is served on the Streamable HTTP modern path; stdio answers `-32601`.
A host that cannot hold an SSE response open (such as the [Rails controller pattern](/server/transports/#rails-controller),
which buffers the body) declines the method with `serve_subscriptions_listen: false`, answering `-32601` and dropping
the `listChanged`/`subscribe` flags from discovery.

## Limits and Keepalives

Concurrent streams are capped by `max_listen_subscriptions:` (default 1000; pass `nil` to remove the cap), and each stream receives an SSE keepalive
comment frame every `listen_keepalive_interval:` seconds (default 15) so a dropped connection frees its slot; pass `listen_keepalive_interval: nil`
when an upstream proxy already keeps the stream alive.

The resource URIs one request names in `resourceSubscriptions` are held for the life of the stream, so the total byte length
of the distinct URIs is bounded by `max_resource_subscription_bytes:` (default 64 KiB, about a thousand ordinary URIs;
pass `nil` to remove the bound). The number of distinct URIs is bounded as well, at 1024, and that bound always applies,
since each retained URI carries a fixed cost however short it is. Duplicates are dropped before either bound is measured,
and the acknowledgement echoes the deduplicated list. A request over either bound is rejected with HTTP 400 and JSON-RPC `-32602`,
as is one whose `resourceSubscriptions` is not an array of strings.
Together with `max_listen_subscriptions`, these bound both the bytes and the number of URIs the listen streams can retain.

```ruby
transport = MCP::Server::Transports::StreamableHTTPTransport.new(
  server,
  max_listen_subscriptions: 500,
  max_resource_subscription_bytes: 16 * 1024,
  listen_keepalive_interval: 30,
)
```

A stream stays open until the client closes the connection; on graceful shutdown via `transport.close`,
each open stream receives its `subscriptions/listen` response before closing.
`close` waits at most 5 seconds in all for those responses to be written: a stream whose client stopped reading
is closed without one when that time is up, and the client re-sends its `subscriptions/listen` request.

See [Notifications](/server/notifications/) for the notification types themselves and their session scoping.
