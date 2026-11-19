---
layout: default
title: Transports
nav_order: 2
---

# Transports

The server ships two transports: [stdio](#stdio-transport) for command-line and desktop integrations,
and [Streamable HTTP](#streamable-http-transport) for web deployments.
This page covers starting each transport, mounting the HTTP transport in Rack and Rails applications,
and its deployment, session, and security settings.

## Stdio Transport

If you want to build a local command-line application, you can use the stdio transport:

```ruby
require "mcp"

# Create a simple tool
class ExampleTool < MCP::Tool
  description "A simple example tool that echoes back its arguments"
  input_schema(
    properties: {
      message: { type: "string" },
    },
    required: ["message"]
  )

  class << self
    def call(message:, server_context:)
      MCP::Tool::Response.new([{
        type: "text",
        text: "Hello from example tool! Message: #{message}",
      }])
    end
  end
end

# Set up the server
server = MCP::Server.new(
  name: "example_server",
  tools: [ExampleTool],
)

# Create and start the transport
transport = MCP::Server::Transports::StdioTransport.new(server)
transport.open
```

`StdioTransport.new` accepts an optional `max_line_bytes:` keyword that caps the byte length of a single newline-delimited request frame. A frame that reaches this limit without a newline is rejected and the connection is closed, preventing unbounded memory growth from a peer that never emits a newline. It defaults to `4 * 1024 * 1024` (4 MiB).

You can run this script and then type in requests to the server at the command line.

```console
$ ruby examples/stdio_server.rb
{"jsonrpc":"2.0","id":"1","method":"ping"}
{"jsonrpc":"2.0","id":"2","method":"tools/list"}
{"jsonrpc":"2.0","id":"3","method":"tools/call","params":{"name":"example_tool","arguments":{"message":"Hello"}}}
```

## Streamable HTTP Transport

`MCP::Server::Transports::StreamableHTTPTransport` is a standard Rack app, so it can be mounted in any Rack-compatible framework.
The following examples show two common integration styles in Rails.

{: .important }
> On the legacy handshake lifecycle, `MCP::Server::Transports::StreamableHTTPTransport` stores session and
> SSE stream state in memory, so it must run in a single process. Use a single-process server (e.g., Puma with
> `workers 0`). Multi-process configurations (Unicorn, or Puma with `workers > 0`) fork separate processes that
> do not share memory, which breaks session management and SSE connections.
>
> When running multiple server instances behind a load balancer, configure your load balancer to use
> sticky sessions (session affinity) so that requests with the same `Mcp-Session-Id` header are always
> routed to the same instance.
>
> Stateless mode (`stateless: true`) does not use sessions and works with any server configuration.
> Requests of the [modern lifecycle](/server/discover/#the-stateless-modern-lifecycle) (MCP 2026-07-28) are likewise sessionless single exchanges and work
> with any configuration, with two caveats: a [`subscriptions/listen`](/server/subscriptions/) stream
> is held in memory by the process that accepted it, so only notifications emitted in that process reach it,
> and the [multi round-trip](/server/mrtr/) `requestState` crosses workers only when they
> share a `RequestStateSecurity` key.

{: .important }
> Per MCP 2025-11-25, `StreamableHTTPTransport` validates the `Host` and `Origin` headers by default to
> prevent DNS rebinding attacks against locally bound servers, rejecting unauthorized values with HTTP 403.
> `Host` is allowed for the loopback defaults (`127.0.0.1`, `::1`, `localhost`), and an `Origin` header,
> when present, must be same-origin or explicitly allow-listed. Non-browser clients that send no `Origin`
> header are unaffected.
>
> Deployments behind a reverse proxy or bound to a non-loopback interface must widen the allow lists:
>
> ```ruby
> transport = MCP::Server::Transports::StreamableHTTPTransport.new(
>   server,
>   allowed_hosts: ["mcp.example.com"],
>   allowed_origins: ["https://app.example.com"],
> )
> ```
>
> An `allowed_hosts:` entry matches either the bare host name (any port) or the full `host:port` value,
> so both `"mcp.example.com"` and `"mcp.example.com:8443"` work. Pass `dns_rebinding_protection: false`
> to disable the check entirely (e.g., when an upstream proxy or middleware already validates `Host`/`Origin`).
> The check runs before any lifecycle dispatch, so it protects requests of
> the [modern lifecycle](/server/discover/#the-stateless-modern-lifecycle) as well.
>
> A server that browser-based clients on any origin may call passes `allowed_origins: :any`,
> which turns `Origin` validation off while `Host` validation stays on:
>
> ```ruby
> transport = MCP::Server::Transports::StreamableHTTPTransport.new(
>   server,
>   allowed_hosts: ["mcp.example.com"],
>   allowed_origins: :any,
>   token_verifier: verifier, # every request must carry a bearer token
> )
> ```
>
> Use it only when every request must carry a credential the browser does not attach on its own,
> such as a bearer token in the `Authorization` header. A cookie, HTTP Basic authentication and a client certificate
> are attached by the browser, and a server without authentication trusts whoever reaches it on localhost or an internal network:
> with any of those, a page on any site could send requests with the user's authority.
> The transport sends no CORS response headers and answers a preflight `OPTIONS` with 405,
> so browser-based clients also need a CORS middleware such as `rack-cors` in front of it;
> [Authorization](/server/authorization/) shows a setup.

### Rails (mount)

`StreamableHTTPTransport` is a Rack app that can be mounted directly in Rails routes:

```ruby
# config/routes.rb
server = MCP::Server.new(
  name: "my_server",
  title: "Example Server Display Name",
  version: "1.0.0",
  instructions: "Use the tools of this server as a last resort",
  tools: [SomeTool, AnotherTool],
  prompts: [MyPrompt],
)
transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)

Rails.application.routes.draw do
  mount transport => "/mcp"
end
```

`mount` directs all HTTP methods on `/mcp` to the transport. `StreamableHTTPTransport` internally dispatches
`POST` (client-to-server JSON-RPC messages, with responses optionally streamed via SSE),
`GET` (optional standalone SSE stream for server-to-client messages), and `DELETE` (session termination) per
the [MCP Streamable HTTP transport spec](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#streamable-http),
so no additional route configuration is needed.

A complete runnable application using this approach is available in [`examples/rails`](https://github.com/modelcontextprotocol/ruby-sdk/tree/main/examples/rails).

### Rails (controller)

While the mount approach creates a single server at boot time, the controller approach creates a new server per request.
This allows you to customize tools, prompts, or configuration based on the request (e.g., different tools per route).

`StreamableHTTPTransport#handle_request` returns proper HTTP status codes (e.g., 202 Accepted for notifications):

```ruby
class McpController < ActionController::API
  def create
    server = MCP::Server.new(
      name: "my_server",
      title: "Example Server Display Name",
      version: "1.0.0",
      instructions: "Use the tools of this server as a last resort",
      tools: [SomeTool, AnotherTool],
      prompts: [MyPrompt],
      server_context: { user_id: current_user.id },
    )
    # Since the `MCP-Session-Id` is not shared across requests, `stateless: true` is set,
    # and since `render` buffers the whole body, `subscriptions/listen` streams are declined.
    transport = MCP::Server::Transports::StreamableHTTPTransport.new(
      server,
      stateless: true,
      serve_subscriptions_listen: false,
    )
    status, headers, body = transport.handle_request(request)

    render(json: body.first, status: status, headers: headers)
  end
end
```

{: .important }
> The controller pattern builds a fresh transport per request and `render` buffers the whole body,
> so it cannot serve the open SSE stream that [`subscriptions/listen`](/server/subscriptions/) needs:
> without `serve_subscriptions_listen: false`, that request returns a streaming `Proc` body
> that `body.first` cannot render, and a modern client's notification stream fails with a 500.
> With the flag, the method answers 404 with JSON-RPC `-32601`, and `server/discover` stops
> advertising the `listChanged`/`subscribe` capability flags, so well-behaved clients do not ask.
> To actually serve listen streams, use the [mount approach](#rails-mount).

### Stateless Mode

You can use Stateless Streamable HTTP, where notifications are not supported and all calls are request/response interactions.
This mode allows for easy multi-node deployment.
Set `stateless: true` in `MCP::Server::Transports::StreamableHTTPTransport.new` (`stateless` defaults to `false`):

```ruby
# Stateless Streamable HTTP - session-less
transport = MCP::Server::Transports::StreamableHTTPTransport.new(server, stateless: true)
```

In stateless mode, each POST is fully self-contained per SEP-2567: no `Mcp-Session-Id` is issued or required,
handlers run against an ephemeral per-request session (so client identity never leaks across requests or onto the shared server),
and repeated `initialize` requests are permitted. Request-scoped notifications such as progress and log messages are skipped
(there is no stream to deliver them), while server-to-client requests (`sampling/createMessage`, `roots/list`, `elicitation/create`) raise an error.

{: .note }
> This transport option is distinct from the sessionless [modern lifecycle](/server/discover/#the-stateless-modern-lifecycle) of MCP 2026-07-28.
> The option governs how handshake-lifecycle clients are served; modern requests carry their own `_meta` envelope
> and are served as single exchanges whether or not `stateless: true` is set.

### JSON Response Mode

You can enable JSON response mode, where the server returns `application/json` instead of `text/event-stream`.
Set `enable_json_response: true` in `MCP::Server::Transports::StreamableHTTPTransport.new`:

```ruby
# JSON response mode
transport = MCP::Server::Transports::StreamableHTTPTransport.new(server, enable_json_response: true)
```

In JSON response mode, the POST response is a single JSON object, so server-to-client messages
that need to arrive during request processing are not supported:
request-scoped notifications (`progress`, `log`) are silently dropped, and all server-to-client requests
(`sampling/createMessage`, `roots/list`, `elicitation/create`) raise an error.
Session-scoped standalone notifications (`resources/updated`, `elicitation/complete`) and
broadcast notifications (`tools/list_changed`, etc.) still flow to clients connected to the GET SSE stream.
This mode is suitable for simple tool servers that do not need server-initiated requests.

{: .note }
> Like [stateless mode](#stateless-mode), this option applies to handshake-lifecycle clients only.
> Requests of the [modern lifecycle](/server/discover/#the-stateless-modern-lifecycle) of MCP 2026-07-28 ignore `enable_json_response:`
> and are served as SSE-framed single exchanges, so request-scoped notifications still reach the client.

### Resumable SSE Streams

Per MCP 2025-11-25 (SEP-1699), a client whose SSE stream is disconnected can reconnect with a GET carrying
the `Last-Event-ID` header, and the server replays the events the client missed and resumes the stream from that point.
`StreamableHTTPTransport` does this once it is given an event store, which keeps each stream's events under the ids it assigns.
The SDK defines the contract of a store, `MCP::Server::Transports::EventStore`, and ships no store of its own;
[`examples/in_memory_event_store.rb`](https://github.com/modelcontextprotocol/ruby-sdk/blob/main/examples/in_memory_event_store.rb)
is one to copy into an application:

```ruby
require_relative "in_memory_event_store" # copied from the SDK's examples

transport = MCP::Server::Transports::StreamableHTTPTransport.new(
  server,
  event_store: InMemoryEventStore.new,
  retry_interval: 1000,
)
```

With an event store, the SSE events the transport writes carry the `id:` the store assigned them, and each stream opens with a priming event:
an event with an id, the `retry` field when `retry_interval:` is set (the milliseconds the client waits before reconnecting), and empty data,
so the client has a cursor to resume from before anything else is sent. A client that negotiated a protocol version before 2025-11-25
receives no priming event, since it cannot parse an event with empty data; its other events still carry ids.
An event the store failed to take is written without an id and the failure is reported, so the client's cursor stays at the event before it,
and the events of the session's GET stream are stored from the moment the client opens that stream, the earliest point it can hold a cursor into them.
A GET with `Last-Event-ID` resumes the stream the event belongs to, whether the session's GET stream or the response stream of a POST:
the events after that id are replayed, and when the request is still running, the new connection takes the old one's place,
so the handler's remaining notifications and its response reach the client. A GET stream whose connection fails is detached from the session
rather than ending it, so the client resumes it the same way. A resume whose replay passes keep finding events, because events keep being stored
while each batch is written, is closed after its sixteenth batch instead, and the client reconnects from its new cursor after `retry`.
The id must name an event of the requesting session;
an id of another session, or one the store no longer holds, is answered with HTTP 400 and nothing is replayed.

The example `InMemoryEventStore` keeps events in the process, which suits the single-process deployments the session store needs anyway.
It is bounded: each stream keeps at most `max_events_per_stream:` events (default 1024), at most `max_streams:` streams are kept (default 1024),
and their messages take at most `max_bytes:` in all (default 64 MiB), apart from the stream written to last, which is never dropped;
the oldest events of a stream and the least recently written streams go first.
The store keeps what it holds, responses included, after the request completes and after the session ends, until the bounds drop it,
and the bounds are shared by every session of the transport, so the traffic of one session can evict the events another would resume from.
A deployment whose reconnects may reach another process implements `MCP::Server::Transports::EventStore` against a shared backend;
the class documents the two methods a store provides.

A handler can also close its own connection on purpose, so a long-running operation does not hold one open:

```ruby
class SlowTool < MCP::Tool
  class << self
    def call(server_context:)
      server_context.close_sse_stream # the client reconnects after `retry_interval`
      result = compute_for_a_while
      MCP::Tool::Response.new([{ type: "text", text: result }])
    end
  end
end
```

`close_sse_stream` returns `true` when it closed the connection of the current request's stream and `false` when there was nothing to close:
no event store, a client older than 2025-11-25, a request answered as JSON, or a connection whose priming event the store failed to take.
The request keeps running either way,
and its remaining messages are stored for the reconnect. `close_standalone_sse_stream` does the same for the session's GET stream.

{: .note }
> Requests of the [modern lifecycle](/server/discover/#the-stateless-modern-lifecycle) (MCP 2026-07-28) are single exchanges
> whose streams are not resumable, as that revision specifies, so a `Last-Event-ID` header on them is ignored.
> Stateless mode (`stateless: true`) has no sessions to resume, so it does not accept `event_store:`.

### Session Limits

By default, stateful sessions are bounded in three ways: they expire after `session_idle_timeout` seconds of inactivity
(default 1800, i.e. 30 minutes), the concurrent session count is capped at `max_sessions` (default 10000),
and the `initialize` request whose `clientInfo` and `capabilities` a session keeps may be at most `max_initialize_request_bytes` (default 64 KiB),
with at most 1024 JSON values in its `params`; a larger one is rejected with HTTP 413 before any session is created.
The byte bound can be raised or removed with `nil`, in which case `max_request_bytes` still caps the body; the value bound always applies,
since a session keeps the parsed data and many small values parse into far more objects than their size suggests.
Together they bound both the serialized input and the number of parsed values each of the `max_sessions` sessions can retain.
A session's idle timer is reset by activity that touches it (a GET, or a regular-request POST), and expired sessions are collected by
a background reaper roughly once a minute, so cleanup lags inactivity by up to that interval. At the cap, the transport first reclaims
any already-expired slots and then, if still full, rejects a new `initialize` with HTTP 503 (it does not evict an existing session).

```ruby
# Tune the limits
transport = MCP::Server::Transports::StreamableHTTPTransport.new(
  server,
  session_idle_timeout: 900,
  max_sessions: 5000,
  max_initialize_request_bytes: 16 * 1024,
)

# Opt out of expiry and/or the caps (not recommended on internet-facing deployments)
transport = MCP::Server::Transports::StreamableHTTPTransport.new(
  server,
  session_idle_timeout: nil,
  max_sessions: nil,
  max_initialize_request_bytes: nil,
)
```

Stateless mode (`stateless: true`) retains no sessions, so none of these limits applies to it. The same holds
for requests of the [modern lifecycle](/server/discover/#the-stateless-modern-lifecycle), which never create a session;
their long-lived [`subscriptions/listen`](/server/subscriptions/) streams are bounded separately
by `max_listen_subscriptions:`.

### Session Ownership

`StreamableHTTPTransport` issues a random `SecureRandom.uuid` session ID and validates incoming requests by session
existence and idle timeout only. Without bearer authentication it does not bind a session to a user, because the transport
then receives no authenticated identity on its own. A caller that obtains a valid session ID could therefore act on that session,
so binding a session to a user is the deploying application's responsibility (the MCP spec frames this as a SHOULD);
with `token_verifier:` configured the transport does it itself, as described at the end of this section.

The primary control is the `session_request_validator`. It is called as `->(request, session_id) { true | false }`
on every non-`initialize` POST, GET, and DELETE against an existing session (including notification and response POSTs,
so a stolen session ID cannot, for example, POST `notifications/cancelled` against a victim's request). A falsy return
rejects the request with HTTP 403. Use it to compare the request's authenticated principal against the one recorded
when the session was created:

```ruby
transport = MCP::Server::Transports::StreamableHTTPTransport.new(
  server,
  session_request_validator: ->(request, session_id) { owns_session?(request, session_id) },
)
```

Without a validator or bearer authentication the transport does not enforce ownership. As a limited defense in depth (not authentication),
it also records the `Origin` header at `initialize` and rejects a later request whose `Origin` differs, but only
when both are present - a non-browser client that omits `Origin` (e.g. `curl` or a script) is not stopped by this check.
Enforcing ownership against a determined attacker requires supplying the validator with an authenticated principal.
Bearer authentication configured with `token_verifier:` supplies one automatically: each session is then also bound
to the token identity that initialized it; see [Authorization](/server/authorization/).

Requests of the [modern lifecycle](/server/discover/#the-stateless-modern-lifecycle) carry no `Mcp-Session-Id` and touch no stored session,
so there is no session to steal, and neither the validator nor the recorded-`Origin` comparison runs for them
(the per-request `Origin` validation of the DNS rebinding protection above still applies);
on that path, bearer enforcement configured with `token_verifier:` still applies to every request; without it,
authorization is enforced per request by the deploying application.

### Request Size Limits

`StreamableHTTPTransport` bounds how many bytes a single POST body may allocate, so a peer cannot exhaust memory
with one oversized message. A body larger than `max_request_bytes` (default 4 MiB) is rejected with HTTP 413,
and JSON nesting depth is capped. The 4 MiB default comfortably fits a typical JSON-RPC message (a 4 MiB JSON
string decodes to roughly 3 MiB of base64 payload) and matches the TypeScript SDK's 4 MB default; raise it only
if you exchange unusually large payloads:

```ruby
transport = MCP::Server::Transports::StreamableHTTPTransport.new(server, max_request_bytes: 8 * 1024 * 1024)
```

Unlike the deployment options above, these bounds apply to both lifecycles:
requests of the [modern lifecycle](/server/discover/#the-stateless-modern-lifecycle) are read through the same byte and nesting limits.
