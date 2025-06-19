# MCP Ruby Examples

This directory contains examples of how to use the Model Context Protocol (MCP) Ruby library.

## Available Examples

### 1. STDIO Server (`stdio_server.rb`)
A simple server that communicates over standard input/output. This is useful for desktop applications and command-line tools.

**Usage:**
```bash
ruby examples/stdio_server.rb
{"jsonrpc":"2.0","id":0,"method":"tools/list"}
```

### 2. HTTP Server (`http_server.rb`)
A standalone HTTP server built with Rack that implements the MCP Streamable HTTP transport protocol. This demonstrates how to create a web-based MCP server with session management and Server-Sent Events (SSE) support.

**Features:**
- HTTP transport with Server-Sent Events (SSE) for streaming
- Session management with unique session IDs
- Example tools, prompts, and resources
- JSON-RPC 2.0 protocol implementation
- Full MCP protocol compliance

**Usage:**
```bash
ruby examples/http_server.rb
```

The server will start on `http://localhost:9292` and provide:
- **Tools**: 
  - `ExampleTool` - adds two numbers
  - `echo` - echoes back messages
- **Prompts**: `ExamplePrompt` - echoes back arguments as a prompt
- **Resources**: `test_resource` - returns example content

### 3. HTTP Client Example (`http_client.rb`)
A client that demonstrates how to interact with the HTTP server using all MCP protocol methods.

**Usage:**
1. Start the HTTP server in one terminal:
   ```bash
   ruby examples/http_server.rb
   ```

2. Run the client example in another terminal:
   ```bash
   ruby examples/http_client.rb
   ```

The client will demonstrate:
- Session initialization
- Ping requests
- Listing and calling tools
- Listing and getting prompts
- Listing and reading resources
- Session cleanup

### 4. Streamable HTTP Server (`streamable_http_server.rb`)
A specialized HTTP server designed to test and demonstrate Server-Sent Events (SSE) functionality in the MCP protocol.

**Features:**
- Tools specifically designed to trigger SSE notifications
- Real-time progress updates and notifications
- Detailed SSE-specific logging

**Available Tools:**
- `NotificationTool` - Send custom SSE notifications with optional delays
- `echo` - Simple echo tool for basic testing

**Usage:**
```bash
ruby examples/streamable_http_server.rb
```

The server will start on `http://localhost:9393` and provide detailed instructions for testing SSE functionality.

### 5. Streamable HTTP Client (`streamable_http_client.rb`)
An interactive client that connects to the SSE stream and provides a menu-driven interface for testing SSE functionality.

**Features:**
- Automatic SSE stream connection
- Interactive menu for triggering various SSE events
- Real-time display of received SSE notifications
- Session management

**Usage:**
1. Start the SSE test server in one terminal:
   ```bash
   ruby examples/streamable_http_server.rb
   ```

2. Run the SSE test client in another terminal:
   ```bash
   ruby examples/streamable_http_client.rb
   ```

The client will:
- Initialize a session automatically
- Connect to the SSE stream
- Provide an interactive menu to trigger notifications
- Display all received SSE events in real-time

### Testing SSE with cURL

You can also test SSE functionality manually using cURL:

1. Initialize a session:
```bash
SESSION_ID=$(curl -D - -s -o /dev/null -X POST http://localhost:9393 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"curl-test","version":"1.0"}}}' |grep -i "Mcp-Session-Id:" | cut -d' ' -f2- | tr -d '\r')
```

2. Connect to SSE stream (in one terminal):
```bash
curl -N -H "Mcp-Session-Id: $SESSION_ID" http://localhost:9393
```

3. Trigger notifications (in another terminal):
```bash
# Send immediate notification
curl -X POST http://localhost:9393 \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","method":"tools/call","id":2,"params":{"name":"notification_tool","arguments":{"message":"Hello from cURL!"}}}'
```

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
```bash
curl -X POST http://localhost:9292 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
```

List tools (using the session ID from initialization):
```bash
curl -X POST http://localhost:9292 \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: YOUR_SESSION_ID" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":2}'
```

Call a tool:
```bash
curl -X POST http://localhost:9292 \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: YOUR_SESSION_ID" \
  -d '{"jsonrpc":"2.0","method":"tools/call","id":3,"params":{"name":"ExampleTool","arguments":{"a":5,"b":3}}}'
```
