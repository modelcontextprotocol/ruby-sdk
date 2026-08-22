---
layout: default
title: Subscriptions
nav_order: 12
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

## Transport Support

The stream is served on the Streamable HTTP modern path; stdio answers `-32601`.

## Limits and Keepalives

Concurrent streams are capped by `max_listen_subscriptions:` (default 1000; pass `nil` to remove the cap), and each stream receives an SSE keepalive
comment frame every `listen_keepalive_interval:` seconds (default 15) so a dropped connection frees its slot; pass `listen_keepalive_interval: nil`
when an upstream proxy already keeps the stream alive.

```ruby
transport = MCP::Server::Transports::StreamableHTTPTransport.new(
  server,
  max_listen_subscriptions: 500,
  listen_keepalive_interval: 30,
)
```

A stream stays open until the client closes the connection; on graceful shutdown via `transport.close`,
each open stream receives its `subscriptions/listen` response before closing.

See [Notifications](/server/notifications/) for the notification types themselves and their session scoping.
