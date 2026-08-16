# MCP Ruby Examples

This directory contains examples of how to use the Model Context Protocol (MCP) Ruby library.

## Available Examples

### 1. stdio Server (`stdio_server.rb`)

A simple server that communicates over standard input/output. This is useful for desktop applications and command-line tools.

**Usage:**

```console
$ ruby examples/stdio_server.rb
{"jsonrpc":"2.0","id":0,"method":"tools/list"}
```

### 2. stdio Client (`stdio_client.rb`)

A client that connects to the stdio server using the `MCP::Client::Stdio` transport.
This demonstrates how to use the SDK's built-in client classes to interact with a server subprocess.

**Usage:**

```console
$ ruby examples/stdio_client.rb
```

The client will automatically launch `stdio_server.rb` as a subprocess and demonstrate:

- Performing the MCP initialization handshake via `client.connect`
- Listing and calling tools
- Listing prompts
- Listing and reading resources
- Transport cleanup on exit

### 3. HTTP Server (`http_server.rb`)

A standalone HTTP server built with Rack that implements the MCP Streamable HTTP transport protocol. This demonstrates how to create a web-based MCP server with session management and Server-Sent Events (SSE) support.

**Features:**

- HTTP transport with Server-Sent Events (SSE) for streaming
- Session management with unique session IDs
- Example tools, prompts, and resources
- JSON-RPC 2.0 protocol implementation
- Full MCP protocol compliance

**Usage:**

```console
$ ruby examples/http_server.rb
```

The server will start on `http://localhost:9292` and provide:

- **Tools**:
  - `example_tool` - adds two numbers
  - `echo` - echoes back messages
- **Prompts**: `example_prompt` - echoes back arguments as a prompt
- **Resources**: `test_resource` - returns example content

### 4. HTTP Client Example (`http_client.rb`)

A client that demonstrates how to interact with the HTTP server using all MCP protocol methods.

**Usage:**

1. Start the HTTP server in one terminal:

   ```console
   $ ruby examples/http_server.rb
   ```

2. Run the client example in another terminal:
   ```console
   $ ruby examples/http_client.rb
   ```

The client will demonstrate:

- Session initialization
- Ping requests
- Listing and calling tools
- Listing and getting prompts
- Listing and reading resources
- Session cleanup

### 5. Streamable HTTP Server (`streamable_http_server.rb`)

A specialized HTTP server designed to test and demonstrate Server-Sent Events (SSE) functionality in the MCP protocol.

**Features:**

- Tools specifically designed to trigger SSE notifications
- Real-time progress updates and notifications
- Detailed SSE-specific logging

**Available Tools:**

- `notification_tool` - Sends progress notifications over SSE, with optional delays
- `echo` - Simple echo tool for basic testing

**Usage:**

```console
$ ruby examples/streamable_http_server.rb
```

The server will start on `http://localhost:9393` and provide detailed instructions for testing SSE functionality.

### 6. Streamable HTTP Client (`streamable_http_client.rb`)

An interactive client that connects to the SSE stream and provides a menu-driven interface for testing SSE functionality.

**Features:**

- Automatic SSE stream connection
- Interactive menu for triggering various SSE events
- Real-time display of received SSE notifications
- Session management

**Usage:**

1. Start the SSE test server in one terminal:

```console
$ ruby examples/streamable_http_server.rb
```

2. Run the SSE test client in another terminal:

```console
$ ruby examples/streamable_http_client.rb
```

The client will:

- Initialize a session automatically
- Connect to the SSE stream
- Provide an interactive menu to trigger notifications
- Display all received SSE events in real-time

### 7. Rails Server (`rails/`)

A minimal Rails application that mounts `StreamableHTTPTransport` in its routes, following the "Rails (mount)" pattern from the top-level README.
It demonstrates class-based tools in `app/tools/` and a resource with a read handler.

**Usage:**

```console
$ cd examples/rails
$ bundle install
$ bundle exec puma --port 9292
```

The MCP endpoint is available at `http://localhost:9292/mcp`. See [`rails/README.md`](rails/README.md) for a full curl-based walkthrough.

### 8. Modern Lifecycle HTTP Server / Client (`modern_http_server.rb`, `modern_http_client.rb`)

A server and client pair demonstrating the 2026-07-28 modern lifecycle (SEP-2575), which replaces the `initialize` handshake and per-session state with sessionless, self-contained requests.

**Features:**

- `server/discover` capability discovery before (or instead of) a handshake
- The per-request `_meta` envelope and `Mcp-Method` / `Mcp-Name` headers, stamped by the SDK automatically
- `resultType` stamping and SEP-2549 cache hints (`ttlMs`, `cacheScope`) on results
- A multi round-trip `deploy` tool (SEP-2322), resumed automatically by the client's elicitation handler
- The removal of legacy-only methods such as `ping`

**Usage:**

1. Start the server in one terminal:

```console
$ ruby examples/modern_http_server.rb
```

2. Run the client in another terminal:

```console
$ ruby examples/modern_http_client.rb
```

The same server still accepts the legacy `initialize` flow: the transport routes each request to the legacy or modern lifecycle by its `MCP-Protocol-Version` header.

### Testing with MCP Inspector

[MCP Inspector](https://modelcontextprotocol.io/docs/tools/inspector) is a browser-based tool for testing and debugging MCP servers.

1. Start the server:

```console
$ ruby examples/streamable_http_server.rb
```

2. Start Inspector in another terminal:

```console
$ npx @modelcontextprotocol/inspector
```

3. Open `http://localhost:6274` in a browser:

- Set Transport Type to "Streamable HTTP"
- Set URL to `http://localhost:9393`
- Disable the Authorization header toggle (the example server does not require authentication)
- Click "Connect"

Once connected, you can list tools, call them, and see SSE notifications in the Inspector UI.

### Testing SSE with cURL

You can also test SSE functionality manually using cURL:

1. Initialize a session:

```console
SESSION_ID=$(curl -D - -s -o /dev/null http://localhost:9393 \
  -H "Accept: application/json, text/event-stream" \
  --json '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"curl-test","version":"1.0"}}}' | grep -i "Mcp-Session-Id:" | cut -d' ' -f2- | tr -d '\r')
```

2. Optionally connect the standalone SSE stream, which carries server-initiated messages that are not tied to a request (in another terminal):

```console
curl -i -N -H "Mcp-Session-Id: $SESSION_ID" http://localhost:9393
```

3. Call the notification tool. The `notifications/progress` events (requested via the `progressToken` in `_meta`) and the final response arrive as SSE events on the POST response itself:

```console
curl -i http://localhost:9393 \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  --json '{"jsonrpc":"2.0","method":"tools/call","id":2,"params":{"name":"notification_tool","arguments":{"message":"Hello from cURL!","delay":0.5},"_meta":{"progressToken":"curl-progress"}}}'
```

### Testing the modern lifecycle with cURL

The modern lifecycle (2026-07-28, SEP-2575) is sessionless: there is no `initialize` handshake and no `Mcp-Session-Id`. Start `examples/modern_http_server.rb` and walk it manually:

1. Probe capabilities with `server/discover`:

```console
curl -s http://localhost:9494 \
  -H "Accept: application/json, text/event-stream" \
  --json '{"jsonrpc":"2.0","id":0,"method":"server/discover"}'
```

2. List tools (the `MCP-Protocol-Version` header selects the era, `Mcp-Method` mirrors the method, and `params._meta` carries the SEP-2575 envelope):

```console
curl -s http://localhost:9494 \
  -H "Accept: application/json, text/event-stream" \
  -H "MCP-Protocol-Version: 2026-07-28" \
  -H "Mcp-Method: tools/list" \
  --json '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
```

3. Call a tool (name-bearing methods additionally mirror the name in the `Mcp-Name` header):

```console
curl -s http://localhost:9494 \
  -H "Accept: application/json, text/event-stream" \
  -H "MCP-Protocol-Version: 2026-07-28" \
  -H "Mcp-Method: tools/call" \
  -H "Mcp-Name: greet" \
  --json '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"greet","arguments":{"name":"curl"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
```

4. Observe a multi round-trip result (SEP-2322), then resume it by echoing the `requestState` back together with the answer. Declaring the `elicitation` capability in the envelope is required before the server may embed elicitation requests:

```console
curl -s http://localhost:9494 \
  -H "Accept: application/json, text/event-stream" \
  -H "MCP-Protocol-Version: 2026-07-28" \
  -H "Mcp-Method: tools/call" \
  -H "Mcp-Name: deploy" \
  --json '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"deploy","arguments":{"app":"storefront"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{"elicitation":{}}}}}'

curl -s http://localhost:9494 \
  -H "Accept: application/json, text/event-stream" \
  -H "MCP-Protocol-Version: 2026-07-28" \
  -H "Mcp-Method: tools/call" \
  -H "Mcp-Name: deploy" \
  --json '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"deploy","arguments":{"app":"storefront"},"inputResponses":{"environment":{"action":"accept","content":{"environment":"staging"}}},"requestState":"{\"app\":\"storefront\"}","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{"elicitation":{}}}}}'
```

The same server still accepts the legacy flow from the previous sections, routed by the `MCP-Protocol-Version` header.

## Streamable HTTP Transport Details

### Protocol Flow

The HTTP server implements the MCP Streamable HTTP transport protocol:

1. **Initialize Session**:

   - Client sends POST request with `initialize` method
   - Server responds with session ID in `Mcp-Session-Id` header

2. **Establish SSE Connection** (optional):

   - Client sends GET request with `Mcp-Session-Id` header
   - Server establishes Server-Sent Events stream for notifications

3. **Send Requests**:

   - Client sends POST requests with JSON-RPC 2.0 format
   - Server processes and responds with results

4. **Close Session**:
   - Client sends DELETE request with `Mcp-Session-Id` header

### Example cURL Commands

Initialize a session:

```console
curl -i http://localhost:9292 \
  -H "Accept: application/json, text/event-stream" \
  --json '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
```

List tools (using the session ID from initialization):

```console
curl -i http://localhost:9292 \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: YOUR_SESSION_ID" \
  --json '{"jsonrpc":"2.0","method":"tools/list","id":2}'
```

Call a tool:

```console
curl -i http://localhost:9292 \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: YOUR_SESSION_ID" \
  --json '{"jsonrpc":"2.0","method":"tools/call","id":3,"params":{"name":"example_tool","arguments":{"a":5,"b":3}}}'
```
