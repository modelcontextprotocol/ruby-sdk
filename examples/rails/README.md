# Rails Example MCP Server

A minimal Rails application that serves an MCP server over the Streamable HTTP transport,
following the "Rails (mount)" pattern from the [top-level README](../../README.md).

The application provides:

- `add_tool` tool (`app/tools/add_tool.rb`) - adds two numbers, demonstrates `input_schema`
- `greeting_tool` tool (`app/tools/greeting_tool.rb`) - greets a name, demonstrates `annotations` and `server_context`
- `example://rails/readme` resource - a text resource served via `resources_read_handler`

The MCP server and transport are built once at boot in `config/routes.rb`, where the transport is mounted at `/mcp`.

## Requirements

- Ruby >= 3.2 (required by Rails 8; the `mcp` gem itself supports older Rubies)
- curl >= 7.82 (for the `--json` flag used below)

## Running

```console
$ cd examples/rails
$ bundle install
$ bundle exec puma --port 9292
```

The MCP endpoint is now available at `http://localhost:9292/mcp`.

## Testing with cURL

POST requests must include an `Accept` header that allows both `application/json` and `text/event-stream`,
per the MCP Streamable HTTP transport spec. Responses arrive as SSE `data:` lines.

1. Initialize a session and capture the session ID:

```console
SESSION_ID=$(curl -s -D - -o /dev/null http://localhost:9292/mcp \
  -H "Accept: application/json, text/event-stream" \
  --json '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}' \
  | grep -i "^mcp-session-id:" | cut -d' ' -f2 | tr -d '\r')
```

2. Complete the handshake (expect `202 Accepted`):

```console
curl -i http://localhost:9292/mcp \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  --json '{"jsonrpc":"2.0","method":"notifications/initialized"}'
```

3. List and call tools:

```console
curl http://localhost:9292/mcp \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  --json '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

curl http://localhost:9292/mcp \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  --json '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"add_tool","arguments":{"a":5,"b":3}}}'

curl http://localhost:9292/mcp \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  --json '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"greeting_tool","arguments":{"name":"Rails"}}}'
```

4. List and read the resource:

```console
curl http://localhost:9292/mcp \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  --json '{"jsonrpc":"2.0","id":5,"method":"resources/list"}'

curl http://localhost:9292/mcp \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  --json '{"jsonrpc":"2.0","id":6,"method":"resources/read","params":{"uri":"example://rails/readme"}}'
```

5. Optionally, open the standalone SSE stream for server-to-client messages
   (in another terminal):

```console
curl -N http://localhost:9292/mcp \
  -H "Accept: text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID"
```

6. End the session:

```console
curl -i -X DELETE http://localhost:9292/mcp -H "Mcp-Session-Id: $SESSION_ID"
```

## Testing with MCP Inspector

Start [MCP Inspector](https://modelcontextprotocol.io/docs/tools/inspector) with `npx @modelcontextprotocol/inspector`,
set Transport Type to "Streamable HTTP", and connect to `http://localhost:9292/mcp`.

## Notes

- `StreamableHTTPTransport` keeps session and SSE state in memory, so it must run in a single process.
  Puma runs in single mode (`workers 0`) by default; do not enable clustered mode for this app.
  When running multiple instances behind a load balancer, use sticky sessions keyed on the `Mcp-Session-Id` header,
  or pass `stateless: true` to the transport.
- The server is built once at boot in `config/routes.rb`, so code reloading is disabled
  (`config.enable_reloading = false` in `config/application.rb`).
  Restart the server after changing tool or resource code. Note that tool classes cannot be referenced from
  `config/initializers` because Zeitwerk has not set up autoloading at that point; routes load late enough that they can.
- For a per-request server with request-specific tools or context, see the "Rails (controller)" section in the top-level README,
  which uses `stateless: true` and `transport.handle_request(request)` inside a controller action.
