---
layout: default
title: Transports
nav_order: 2
---

# Transports

`MCP::Client` is transport-agnostic: it sends every request through the transport instance it is built with.
This page covers the bundled [stdio](#stdio-transport-layer) and [Streamable HTTP](#http-transport-layer) transports,
their sessions and server-to-client request handling, and the interface a custom transport must implement.

## Stdio Transport Layer

Use the `MCP::Client::Stdio` transport to interact with MCP servers running as subprocesses over standard input/output.

`MCP::Client::Stdio.new` accepts the following keyword arguments:

| Parameter | Required | Description |
|---|---|---|
| `command:` | Yes | The command to spawn the server process (e.g., `"ruby"`, `"bundle"`, `"npx"`). |
| `args:` | No | An array of arguments passed to the command. Defaults to `[]`. |
| `env:` | No | A hash of environment variables to set for the server process. Defaults to `nil`. |
| `read_timeout:` | No | Timeout in seconds for waiting for a server response. Defaults to `nil` (no timeout). |
| `max_line_bytes:` | No | Maximum byte length of a single newline-delimited response frame. A frame that reaches this limit without a newline is rejected as a transport error, preventing unbounded memory growth from a server that never emits a newline. Defaults to `4 * 1024 * 1024` (4 MiB). |

Example usage:

```ruby
stdio_transport = MCP::Client::Stdio.new(
  command: "bundle",
  args: ["exec", "ruby", "path/to/server.rb"],
  env: { "API_KEY" => "my_secret_key" },
  read_timeout: 30
)
client = MCP::Client.new(transport: stdio_transport)

# Perform the MCP initialization handshake before sending any requests.
client.connect

# List available tools.
tools = client.tools
tools.each do |tool|
  puts "Tool: #{tool.name} - #{tool.description}"
end

# Call a specific tool.
response = client.call_tool(
  tool: tools.first,
  arguments: { message: "Hello, world!" }
)

# Close the transport when done.
stdio_transport.close
```

The stdio transport automatically handles:

- Spawning the server process with `Open3.popen3`
- MCP protocol initialization handshake (`initialize` request + `notifications/initialized`)
- JSON-RPC 2.0 message framing over newline-delimited JSON

## HTTP Transport Layer

Use the `MCP::Client::HTTP` transport to interact with MCP servers using simple HTTP requests.

You'll need to add `faraday` as a dependency in order to use the HTTP transport layer, and `event_stream_parser`
to read SSE (`text/event-stream`) responses.
Whether a response is JSON or SSE is the server's choice, made for each response, and a client must accept both,
so a client written for arbitrary servers needs both gems. This SDK's own server picks SSE by default and always
does on the modern lifecycle, and the listening stream that `on_elicitation` and `on_sampling` open is SSE as well.
`event_stream_parser` is loaded on the first SSE response, so it can be left out only against a server known to
answer with JSON alone, such as this SDK's server in [JSON response mode](/server/transports/#json-response-mode)
serving handshake-lifecycle clients, and only while no listening stream is opened:

```ruby
gem "mcp"
gem "faraday", ">= 2.0"
gem "event_stream_parser", ">= 1.0" # optional, required only for SSE responses
```

Example usage:

```ruby
http_transport = MCP::Client::HTTP.new(url: "https://api.example.com/mcp")
client = MCP::Client.new(transport: http_transport)

# Perform the MCP initialization handshake before sending any requests.
client.connect

# List available tools
tools = client.tools
tools.each do |tool|
  puts <<~TOOL_INFORMATION
    Tool: #{tool.name}
    Description: #{tool.description}
    Input Schema: #{tool.input_schema}
  TOOL_INFORMATION
end

# Call a specific tool
response = client.call_tool(
  tool: tools.first,
  arguments: { message: "Hello, world!" }
)

# Call a tool with progress tracking.
response = client.call_tool(
  tool: tools.first,
  arguments: { count: 10 },
  progress_token: "my-progress-token"
)
```

The server sends `notifications/progress` during execution; the bundled transports do not currently
expose these notifications to application code, so the token's effect is visible on the server side.
See the [Progress](/server/progress/) page.

`MCP::Client::HTTP.new` accepts an optional `max_message_bytes:` keyword that caps the bytes buffered in memory for a single message from the server -
an SSE event or a JSON response body. A message that reaches this limit before completing is rejected as a transport error, preventing unbounded memory growth from
a server that never terminates an SSE event. It defaults to `4 * 1024 * 1024` (4 MiB); raise it if your server returns larger responses.

`MCP::Client::HTTP.new` also accepts `max_reconnection_wait:`, a budget in seconds for resuming a closed SSE stream. It gates every wait between reconnection attempts,
and what is left of it becomes the read timeout of each resumed stream. The server chooses that wait through the SSE `retry:` field, and resuming happens on the calling thread,
so without a budget a server answering with a large `retry:` parks a thread of your application for as long as it likes. It defaults to `300` (5 minutes).
The server's `retry:` is never shortened: when honoring it would run past the budget, the client stops trying to resume and raises instead,
the same thing it already does once the reconnection attempts are used up. A floor of 100ms applies to each wait, so a `retry: 0` cannot spin
the listening stream's reconnect loop; waiting longer than the server asked for is explicitly allowed by the SSE reconnection algorithm the spec points at.

### Sessions

After `connect` succeeds, the HTTP transport captures the `Mcp-Session-Id` header and `protocolVersion` from the response and includes them on subsequent requests. Both are exposed on the transport as transport-specific state:

```ruby
http_transport.session_id       # => "abc123..."
http_transport.protocol_version # => "2025-11-25"
```

If the server terminates the session, subsequent requests return HTTP 404 and the transport raises `MCP::Client::SessionExpiredError` (a subclass of `RequestHandlerError`). Session state is cleared automatically; callers should start a new session by calling `connect` again.

To explicitly terminate a session (e.g., when the client application is shutting down), call `close`. The transport sends an HTTP DELETE to the MCP endpoint with the session header and clears local session state. A `405 Method Not Allowed` response (server doesn't support client-initiated termination) or `404 Not Found` (session already terminated server-side) is treated as success. Other errors - 5xx, authentication failures, connection errors - propagate to the caller. Local session state is cleared either way. Calling `close` without an active session is a no-op.

```ruby
http_transport.close
```

These are handshake-lifecycle mechanics: on a [modern](/client/lifecycle/) connection there is
no session to capture - `session_id` stays `nil` and requests carry the `_meta` envelope instead.

### Server-to-Client Requests (Elicitation)

Servers can send requests back to the client while one of the client's own requests is in flight - for example,
[`elicitation/create`](https://modelcontextprotocol.io/specification/2025-11-25/client/elicitation) to ask the user for additional input during a tool call.
Register a handler and advertise the capability on `connect` to respond to them:

```ruby
client.connect(capabilities: { elicitation: {} })

client.on_elicitation do |params|
  {
    action: "accept",
    # Fill fields omitted by the user with the schema's `default` values (SEP-1034)
    content: MCP::Client::Elicitation.apply_defaults(params["requestedSchema"]),
  }
end
```

Registering a handler opens a standalone HTTP GET SSE stream on a background thread
([listening for messages from the server](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#listening-for-messages-from-the-server)),
since servers deliver requests that are not tied to a client request on that stream. Server requests with no registered handler are answered with
a JSON-RPC `-32601` (method not found) error. To handle methods other than `elicitation/create`, register directly on the transport with
`http_transport.on_server_request("method/name") { |params| ... }`.

On a [modern](/client/lifecycle/) connection servers cannot send requests at all; the same
registered handlers instead drive the requests embedded in `input_required` results,
as documented on [Multi Round-Trip Requests](/client/mrtr/).

### Server-to-Client Requests (Sampling)

Servers can also request an LLM completion from the client with [`sampling/createMessage`](https://modelcontextprotocol.io/specification/2025-11-25/client/sampling),
letting a server leverage the client's model access without its own API keys.

{: .warning }
> MCP Sampling is deprecated as of protocol version `2026-07-28` (SEP-2577), while remaining fully supported under `2025-11-25`.
> Register this handler to interoperate with servers that still send sampling requests during the deprecation window;
> new servers should call LLM provider APIs directly.

Register a handler and advertise the capability on `connect`:

```ruby
client.connect(capabilities: { sampling: {} })

client.on_sampling do |params|
  completion = my_llm.complete(params["messages"], max_tokens: params["maxTokens"])
  {
    role: "assistant",
    content: { type: "text", text: completion.text },
    model: completion.model,
    stopReason: "endTurn",
  }
end
```

For trust and safety, the spec recommends a human in the loop able to review, edit, or reject the request and the generated response.
To reject a request, raise `MCP::Client::ServerRequestError` with the spec's user-rejection code `-1`:

```ruby
client.on_sampling do |params|
  raise MCP::Client::ServerRequestError.new("User rejected sampling request", code: -1) unless approved?(params)

  generate_completion(params)
end
```

Use `capabilities: { sampling: { tools: {} } }` to receive tool-enabled sampling requests. Like elicitation, this uses the same standalone GET SSE listening stream.

### Custom Headers from Tool Parameters

On a modern `MCP::Client::HTTP` connection, `tools/call` mirrors arguments whose `inputSchema` property carries
an `x-mcp-header` annotation into `Mcp-Param-{Name}` request headers per SEP-2243, so intermediaries can route
on the values without parsing bodies. The declarations are learned from `tools/list` responses:
list the tools before calling one to enable the mirroring. Values that cannot ride as plain ASCII header values
(non-ASCII, control characters, edge whitespace, empty strings) are wrapped as `=?base64?...?=`,
and a `null` or absent argument omits its header.

Per the specification, a tool definition whose `x-mcp-header` annotations are invalid (empty or non-token names,
duplicate names, non-primitive properties, annotations outside a chain of `properties` keys) is excluded from
`tools/list` results on modern connections, with a warning naming the tool.
Legacy connections are unaffected: nothing is learned, mirrored, or excluded.

### Customizing the Faraday Connection

You can pass a block to `MCP::Client::HTTP.new` to customize the underlying Faraday connection.
The block is called after the default middleware is configured, so you can add middleware or swap the HTTP adapter:

```ruby
http_transport = MCP::Client::HTTP.new(url: "https://api.example.com/mcp") do |faraday|
  faraday.use MyApp::Middleware::HttpRecorder
  faraday.adapter :typhoeus
end
```

{: .note }
> Answers to server-to-client requests (a pong, an elicitation result) are POSTed from inside
> the SSE streaming callback of another response, re-entering the connection on the same thread.
> The default Net::HTTP adapter opens a connection per request, which makes this safe; an adapter
> with persistent connections must tolerate that re-entry.

## Custom Transports

If the transport layer you need is not included in the gem, you can build and pass your own instances so long as they conform to the following interface:

```ruby
class CustomTransport
  # Sends a JSON-RPC request to the server and returns the raw response.
  #
  # @param request [Hash] A complete JSON-RPC request object.
  #     https://www.jsonrpc.org/specification#request_object
  # @return [Hash] A hash modeling a JSON-RPC response object.
  #     https://www.jsonrpc.org/specification#response_object
  def send_request(request:)
    # Your transport-specific logic here
    # - HTTP: POST to endpoint with JSON body
    # - WebSocket: Send message over WebSocket
    # - stdio: Write to stdout, read from stdin
    # - etc.
  end
end

client = MCP::Client.new(transport: CustomTransport.new)
```

Custom transports that need to support client-side cancellation have additional requirements;
see [Custom transports](/client/cancellation/#custom-transports) on the Cancellation page.
