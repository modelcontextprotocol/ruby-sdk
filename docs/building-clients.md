---
layout: default
title: Building Clients
nav_order: 4
---

# Building an MCP Client

The `MCP::Client` class provides an interface for interacting with MCP servers.

**Supported operations:**

- Tool listing (`MCP::Client#tools`) and invocation (`MCP::Client#call_tool`)
- Resource listing (`MCP::Client#resources`) and reading (`MCP::Client#read_resources`)
- Resource template listing (`MCP::Client#resource_templates`)
- Prompt listing (`MCP::Client#prompts`) and retrieval (`MCP::Client#get_prompt`)
- Completion requests (`MCP::Client#complete`)

## Stdio Transport

Use `MCP::Client::Stdio` to interact with MCP servers running as subprocesses:

```ruby
stdio_transport = MCP::Client::Stdio.new(
  command: "bundle",
  args: ["exec", "ruby", "path/to/server.rb"],
  env: { "API_KEY" => "my_secret_key" },
  read_timeout: 30
)
client = MCP::Client.new(transport: stdio_transport)

tools = client.tools
tools.each do |tool|
  puts "Tool: #{tool.name} - #{tool.description}"
end

response = client.call_tool(
  tool: tools.first,
  arguments: { message: "Hello, world!" }
)

stdio_transport.close
```

| Parameter | Required | Description |
|---|---|---|
| `command:` | Yes | The command to spawn the server process. |
| `args:` | No | An array of arguments passed to the command. Defaults to `[]`. |
| `env:` | No | A hash of environment variables for the server process. Defaults to `nil`. |
| `read_timeout:` | No | Timeout in seconds for waiting for a server response. Defaults to `nil`. |

## HTTP Transport

Use `MCP::Client::HTTP` to interact with MCP servers over HTTP. Requires the `faraday` gem, plus `event_stream_parser` if the server uses SSE (`text/event-stream`) responses:

```ruby
gem 'mcp'
gem 'faraday', '>= 2.0'
gem 'event_stream_parser', '>= 1.0' # optional, required only for SSE responses
```

```ruby
http_transport = MCP::Client::HTTP.new(url: "https://api.example.com/mcp")
client = MCP::Client.new(transport: http_transport)
client.connect

tools = client.tools
tools.each do |tool|
  puts "Tool: #{tool.name} - #{tool.description}"
end

response = client.call_tool(
  tool: tools.first,
  arguments: { message: "Hello, world!" }
)
```

### Handshake

Call `MCP::Client#connect` to perform the MCP [initialization handshake](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle#initialization): the client sends an `initialize` request through the transport, followed by the required `notifications/initialized` notification, and caches the server's `InitializeResult` (protocol version, capabilities, server info, instructions):

```ruby
client.connect
# => { "protocolVersion" => "2025-11-25", "capabilities" => {...}, "serverInfo" => {...} }

client.connected?  # => true
client.server_info # => cached InitializeResult
```

`connect` accepts optional `client_info:`, `protocol_version:`, and `capabilities:` keyword arguments. It is idempotent — a second call returns the cached result without contacting the server. After `close`, state is cleared and `connect` will handshake again.

### Sessions

After `connect` succeeds, the HTTP transport captures the `Mcp-Session-Id` header and `protocolVersion` from the response and includes them on subsequent requests. Both are exposed on the transport as transport-specific state:

```ruby
http_transport.session_id       # => "abc123..."
http_transport.protocol_version # => "2025-11-25"
```

If the server terminates the session, subsequent requests return HTTP 404 and the transport raises `MCP::Client::SessionExpiredError` (a subclass of `RequestHandlerError`). Session state is cleared automatically; callers should start a new session by calling `connect` again.

To explicitly terminate a session (e.g., when the client application is shutting down), call `close`. The transport sends an HTTP DELETE to the MCP endpoint with the session header and clears local session state. A `405 Method Not Allowed` response (server doesn't support client-initiated termination) or `404 Not Found` (session already terminated server-side) is treated as success. Other errors — 5xx, authentication failures, connection errors — propagate to the caller. Local session state is cleared either way. Calling `close` without an active session is a no-op.

```ruby
http_transport.close
```

### Authorization

Provide custom headers for authentication:

```ruby
http_transport = MCP::Client::HTTP.new(
  url: "https://api.example.com/mcp",
  headers: {
    "Authorization" => "Bearer my_token"
  }
)
client = MCP::Client.new(transport: http_transport)
```

### Customizing the Faraday Connection

Pass a block to customize the underlying Faraday connection:

```ruby
http_transport = MCP::Client::HTTP.new(url: "https://api.example.com/mcp") do |faraday|
  faraday.use MyApp::Middleware::HttpRecorder
  faraday.adapter :typhoeus
end
```

## Custom Transport

If the built-in transports do not fit your needs, you can implement your own:

```ruby
class CustomTransport
  def send_request(request:)
    # Your transport-specific logic here.
    # Returns a Hash modeling a JSON-RPC response object.
  end
end

client = MCP::Client.new(transport: CustomTransport.new)
```

For more details, see the [full README](https://github.com/modelcontextprotocol/ruby-sdk/blob/main/README.md#building-an-mcp-client).
