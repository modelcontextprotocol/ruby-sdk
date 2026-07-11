# MCP Ruby SDK [![Gem Version](https://img.shields.io/gem/v/mcp)](https://rubygems.org/gems/mcp) [![Apache 2.0 licensed](https://img.shields.io/badge/license-Apache%202.0-blue)](https://github.com/modelcontextprotocol/ruby-sdk/blob/main/LICENSE) [![CI](https://github.com/modelcontextprotocol/ruby-sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/modelcontextprotocol/ruby-sdk/actions/workflows/ci.yml)

The official Ruby SDK for Model Context Protocol servers and clients.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'mcp'
```

And then execute:

```console
$ bundle install
```

Or install it yourself as:

```console
$ gem install mcp
```

You may need to add additional dependencies depending on which features you wish to access.

## Building an MCP Server

The `MCP::Server` class is the core component that handles JSON-RPC requests and responses.
It implements the Model Context Protocol specification, handling model context requests and responses.

### Key Features

- Implements JSON-RPC 2.0 message handling
- Supports protocol initialization and capability negotiation
- Manages tool registration and invocation
- Supports prompt registration and execution
- Supports resource registration and retrieval
- Supports stdio & Streamable HTTP (including SSE) transports
- Supports notifications for list changes (tools, prompts, resources)
- Supports roots (server-to-client filesystem boundary queries)
- Supports sampling (server-to-client LLM completion requests)
- Supports cursor-based pagination for list operations
- Supports cancellation of in-flight requests on both server and client (notifications/cancelled)

### Supported Methods

- `initialize` - Initializes the protocol and returns server capabilities
- `server/discover` - Sessionless capability discovery (MCP 2026-07-28 draft, SEP-2575): returns `supportedVersions`, `capabilities`, `serverInfo`,
  and `instructions`, and responds before `initialize` and without an `Mcp-Session-Id`
- `ping` - Simple health check
- `logging/setLevel` - Configures the minimum log level for the server
- `tools/list` - Lists all registered tools and their schemas
- `tools/call` - Invokes a specific tool with provided arguments
- `prompts/list` - Lists all registered prompts and their schemas
- `prompts/get` - Retrieves a specific prompt by name
- `resources/list` - Lists all registered resources and their schemas
- `resources/read` - Retrieves a specific resource by name
- `resources/templates/list` - Lists all registered resource templates and their schemas
- `resources/subscribe` - Subscribes to updates for a specific resource
- `resources/unsubscribe` - Unsubscribes from updates for a specific resource
- `completion/complete` - Returns autocompletion suggestions for prompt arguments and resource URIs
- `roots/list` - Requests filesystem roots from the client (server-to-client)
- `sampling/createMessage` - Requests LLM completion from the client (server-to-client)
- `elicitation/create` - Requests user input from the client (server-to-client)

### Usage

#### Stdio Transport

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

#### Streamable HTTP Transport

`MCP::Server::Transports::StreamableHTTPTransport` is a standard Rack app, so it can be mounted in any Rack-compatible framework.
The following examples show two common integration styles in Rails.

> [!IMPORTANT]
> `MCP::Server::Transports::StreamableHTTPTransport` stores session and SSE stream state in memory,
> so it must run in a single process. Use a single-process server (e.g., Puma with `workers 0`).
> Multi-process configurations (Unicorn, or Puma with `workers > 0`) fork separate processes that
> do not share memory, which breaks session management and SSE connections.
>
> When running multiple server instances behind a load balancer, configure your load balancer to use
> sticky sessions (session affinity) so that requests with the same `Mcp-Session-Id` header are always
> routed to the same instance.
>
> Stateless mode (`stateless: true`) does not use sessions and works with any server configuration.

> [!IMPORTANT]
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

##### Rails (mount)

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
the [MCP Streamable HTTP transport spec](https://modelcontextprotocol.io/specification/latest/basic/transports#streamable-http),
so no additional route configuration is needed.

A complete runnable application using this approach is available in [`examples/rails`](examples/rails).

##### Rails (controller)

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
    # Since the `MCP-Session-Id` is not shared across requests, `stateless: true` is set.
    transport = MCP::Server::Transports::StreamableHTTPTransport.new(server, stateless: true)
    status, headers, body = transport.handle_request(request)

    render(json: body.first, status: status, headers: headers)
  end
end
```

### Configuration

The gem can be configured using the `MCP.configure` block:

```ruby
MCP.configure do |config|
  config.exception_reporter = ->(exception, server_context) {
    # Your exception reporting logic here
    # For example with Bugsnag:
    Bugsnag.notify(exception) do |report|
      report.add_metadata(:model_context_protocol, server_context)
    end
  }

  config.around_request = ->(data, &request_handler) {
    logger.info("Start: #{data[:method]}")
    request_handler.call
    logger.info("Done: #{data[:method]}, tool: #{data[:tool_name]}")
  }
end
```

or by creating an explicit configuration and passing it into the server.
This is useful for systems where an application hosts more than one MCP server but
they might require different configurations.

```ruby
configuration = MCP::Configuration.new
configuration.exception_reporter = ->(exception, server_context) {
  # Your exception reporting logic here
  # For example with Bugsnag:
  Bugsnag.notify(exception) do |report|
    report.add_metadata(:model_context_protocol, server_context)
  end
}

configuration.around_request = ->(data, &request_handler) {
  logger.info("Start: #{data[:method]}")
  request_handler.call
  logger.info("Done: #{data[:method]}, tool: #{data[:tool_name]}")
}

server = MCP::Server.new(
  # ... all other options
  configuration:,
)
```

### Capability Extensions

Per SEP-2133, both clients and servers can declare protocol extensions under the `extensions` member of their capabilities.
Keys are extension identifiers using the reverse-DNS prefix convention (e.g. `"io.modelcontextprotocol/tasks"`, `"com.example/feature"`);
values are extension-defined configuration objects, with `{}` meaning "supported with no settings".

On the server, declare extensions through the `capabilities` keyword, either as a plain hash or via the `MCP::Server::Capabilities` builder:

```ruby
capabilities = MCP::Server::Capabilities.new
capabilities.support_tools
capabilities.support_extensions("com.example/feature" => { enabled: true })

server = MCP::Server.new(name: "my_server", capabilities: capabilities)
```

The declared extensions appear in the `initialize` result's `capabilities.extensions`. Extensions the client declared during `initialize` are
readable via `server.client_capabilities[:extensions]` (or `session.client_capabilities[:extensions]` for per-session transports).

On the client, pass extensions through `connect`:

```ruby
client.connect(capabilities: { extensions: { "com.example/feature" => {} } })
```

### MCP Apps (SEP-1865)

MCP Apps is a Final extension (negotiated via the Capability Extensions mechanism above) that lets a server ship interactive
HTML user interfaces which the host renders for tool results. On the server side the extension is a thin convention,
and `MCP::Apps` provides the vocabulary and helpers:

```ruby
capabilities = MCP::Server::Capabilities.new
capabilities.support_tools
capabilities.support_resources
capabilities.support_extensions(MCP::Apps.capability) # { "io.modelcontextprotocol/ui" => { mimeTypes: [...] } }

server = MCP::Server.new(
  name: "weather_server",
  capabilities: capabilities,
  # UI templates are ordinary resources with a `ui://` URI and the `text/html;profile=mcp-app` MIME type.
  resources: [MCP::Apps.ui_resource(uri: "ui://weather-server/dashboard", name: "weather_dashboard")],
)

server.resources_read_handler do |params|
  [{ uri: params[:uri], mimeType: MCP::Apps::RESOURCE_MIME_TYPE, text: "<html>...</html>" }]
end

# Link the tool to its template via `_meta.ui.resourceUri` (pass `legacy: true` to also
# emit the older flat `"ui/resourceUri"` alias for hosts that predate the Final spec).
server.define_tool(
  name: "get_weather",
  meta: MCP::Apps.tool_meta(resource_uri: "ui://weather-server/dashboard"),
) do |server_context:|
  # The extension is optional: always return a meaningful text result, and use
  # `MCP::Apps.client_supports?` when UI-capable clients should get richer structured content.
  MCP::Apps.client_supports?(server.client_capabilities) # => true when the host declared the extension
  MCP::Tool::Response.new([{ type: "text", text: "Sunny, 22 degrees Celsius" }])
end
```

Everything else the extension defines (the sandboxed iframe, the `ui/*` postMessage bridge, consent for UI-initiated actions)
is the HOST's responsibility; a server only ever receives ordinary `resources/read` and `tools/call` requests.
See the [MCP Apps specification](https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx).

### Server Context and Configuration Block Data

#### `server_context`

The `server_context` is a user-defined hash that is passed into the server instance and made available to tool and prompt calls.
It can be used to provide contextual information such as authentication state, user IDs, or request-specific data.

**Type:**

```ruby
server_context: { [String, Symbol] => Any }
```

**Example:**

```ruby
server = MCP::Server.new(
  name: "my_server",
  server_context: { user_id: current_user.id, request_id: request.uuid }
)
```

This hash is then passed as the `server_context` keyword argument to tool and prompt calls.
Note that exception and instrumentation callbacks do not receive this user-defined hash.
See the relevant sections below for the arguments they receive.

#### Request-specific `_meta` Parameter

The MCP protocol supports a special [`_meta` parameter](https://modelcontextprotocol.io/specification/2025-06-18/basic#general-fields) in requests that allows clients to pass request-specific metadata. The server automatically extracts this parameter and makes it available to tools and prompts as a nested field within the `server_context`.

> [!NOTE]
> `_meta` is only merged when `server_context` is a `Hash` (or `nil`, in which case a new `{ _meta: ... }` hash is synthesized).
> If you assign a non-`Hash` value to `server_context`, `_meta` is not merged and tools will not see it
> under `server_context[:_meta]`. Keep `server_context` as a `Hash` if your tools need access to `_meta`.

**Access Pattern:**

When a client includes `_meta` in the request params, it becomes available as `server_context[:_meta]`:

```ruby
class MyTool < MCP::Tool
  def self.call(message:, server_context:)
    # Access provider-specific metadata
    session_id = server_context.dig(:_meta, :session_id)
    request_id = server_context.dig(:_meta, :request_id)

    # Access server's original context
    user_id = server_context.dig(:user_id)

    MCP::Tool::Response.new([{
      type: "text",
      text: "Processing for user #{user_id} in session #{session_id}"
    }])
  end
end
```

**Client Request Example:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "my_tool",
    "arguments": { "message": "Hello" },
    "_meta": {
      "session_id": "abc123",
      "request_id": "req_456"
    }
  }
}
```

**Distributed Tracing (W3C Trace Context):**

Per SEP-414, the keys `traceparent`, `tracestate`, and `baggage` are reserved un-prefixed `_meta` keys for propagating
[W3C Trace Context](https://www.w3.org/TR/trace-context/) across MCP requests. The SDK guarantees these keys pass through
incoming request `_meta` untouched, and exposes their names as constants on `MCP::TraceContext` (`TRACEPARENT_META_KEY`,
`TRACESTATE_META_KEY`, `BAGGAGE_META_KEY`, and `META_KEYS`). The SDK does not depend on OpenTelemetry; bridge the values
to your tracing system yourself:

```ruby
class TracedTool < MCP::Tool
  def self.call(message:, server_context:)
    traceparent = server_context.dig(:_meta, :traceparent)
    # Hand traceparent/tracestate/baggage to your tracing library
    # (e.g. the opentelemetry-ruby gems) to continue the caller's trace.

    MCP::Tool::Response.new([{ type: "text", text: "ok" }])
  end
end
```

On the client side, every request method (`call_tool`, `read_resource`, `get_prompt`, `complete`, `ping`, and the `list_*` methods)
accepts a `meta:` keyword to inject these keys into the outgoing request, so trace context can flow on every request:

```ruby
meta = { MCP::TraceContext::TRACEPARENT_META_KEY => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" }

client.call_tool(tool: tool, arguments: { message: "Hello" }, meta: meta)
client.read_resource(uri: "file:///report.txt", meta: meta)
```

#### Configuration Block Data

##### Exception Reporter

The exception reporter receives:

- `exception`: The Ruby exception object that was raised
- `server_context`: A hash describing where the failure occurred (e.g., `{ request: <raw JSON-RPC request> }`
  for request handling, `{ notification: "tools_list_changed" }` for notification delivery).
  This is not the user-defined `server_context` passed to `Server.new`.

**Signature:**

```ruby
exception_reporter = ->(exception, server_context) { ... }
```

##### Around Request

The `around_request` hook wraps request handling, allowing you to execute code before and after each request.
This is useful for Application Performance Monitoring (APM) tracing, logging, or other observability needs.

The hook receives a `data` hash and a `request_handler` block. You must call `request_handler.call` to execute the request:

**Signature:**

```ruby
around_request = ->(data, &request_handler) { request_handler.call }
```

**`data` availability by timing:**

- Before `request_handler.call`: `method`
- After `request_handler.call`: `tool_name`, `tool_arguments`, `prompt_name`, `resource_uri`, `error`, `client`
- Not available inside `around_request`: `duration` (added after `around_request` returns)

> [!NOTE]
> `tool_name`, `prompt_name` and `resource_uri` may only be populated for the corresponding request methods
> (`tools/call`, `prompts/get`, `resources/read`), and may not be set depending on how the request is handled
> (for example, `prompt_name` is not recorded when the prompt is not found).
> `duration` is added after `around_request` returns, so it is not visible from within the hook.

**Example:**

```ruby
MCP.configure do |config|
  config.around_request = ->(data, &request_handler) {
    logger.info("Start: #{data[:method]}")
    request_handler.call
    logger.info("Done: #{data[:method]}, tool: #{data[:tool_name]}")
  }
end
```

##### Instrumentation Callback (soft-deprecated)

> [!NOTE]
> `instrumentation_callback` is soft-deprecated. Use `around_request` instead.
>
> To migrate, wrap the call in `begin/ensure` so the callback still runs when the request fails:
>
> ```ruby
> # Before
> config.instrumentation_callback = ->(data) { log(data) }
>
> # After
> config.around_request = ->(data, &request_handler) do
>   request_handler.call
> ensure
>   log(data)
> end
> ```
>
> Note that `data[:duration]` is not available inside `around_request`.
> If you need it, measure elapsed time yourself within the hook, or keep using `instrumentation_callback`.

The instrumentation callback is called after each request finishes, whether successfully or with an error.
It receives a hash with the following possible keys:

- `method`: (String) The protocol method called (e.g., "ping", "tools/list")
- `tool_name`: (String, optional) The name of the tool called
- `tool_arguments`: (Hash, optional) The arguments passed to the tool
- `prompt_name`: (String, optional) The name of the prompt called
- `resource_uri`: (String, optional) The URI of the resource called
- `error`: (String, optional) Error code if a lookup failed
- `duration`: (Float) Duration of the call in seconds
- `client`: (Hash, optional) Client information with `name` and `version` keys, from the initialize request

**Signature:**

```ruby
instrumentation_callback = ->(data) { ... }
```

### Server Protocol Version

The server's protocol version can be overridden using the `protocol_version` keyword argument:

```ruby
configuration = MCP::Configuration.new(protocol_version: "2024-11-05")
MCP::Server.new(name: "test_server", configuration: configuration)
```

If no protocol version is specified, the latest stable version will be applied by default.
The latest stable version includes new features from the [draft version](https://modelcontextprotocol.io/specification/draft).

This will make all new server instances use the specified protocol version instead of the default version. The protocol version can be reset to the default by setting it to `nil`:

```ruby
MCP::Configuration.new(protocol_version: nil)
```

If an invalid `protocol_version` value is set, an `ArgumentError` is raised.

Be sure to check the [MCP spec](https://modelcontextprotocol.io/specification/versioning) for the protocol version to understand the supported features for the version being set.

### Exception Reporting

The exception reporter receives two arguments:

- `exception`: The Ruby exception object that was raised
- `server_context`: A hash containing contextual information about where the error occurred

The `server_context` hash includes:

- For request handling failures: `{ request: { ... } }` (the raw JSON-RPC request hash)
- For notification delivery failures: `{ notification: "tools_list_changed" }` (or the relevant notification name)

When an exception occurs:

1. The exception is reported via the configured reporter
2. For tool calls, a generic error response is returned to the client: `{ error: "Internal error occurred", isError: true }`
3. For other requests, the exception is re-raised after reporting

If no exception reporter is configured, a default no-op reporter is used that silently ignores exceptions.

### Tools

MCP spec includes [Tools](https://modelcontextprotocol.io/specification/latest/server/tools) which provide functionality to LLM apps.

This gem provides a `MCP::Tool` class that can be used to create tools in three ways:

1. As a class definition:

```ruby
class MyTool < MCP::Tool
  title "My Tool"
  description "This tool performs specific functionality..."
  input_schema(
    properties: {
      message: { type: "string" },
    },
    required: ["message"]
  )
  output_schema(
    properties: {
      result: { type: "string" },
      success: { type: "boolean" },
      timestamp: { type: "string", format: "date-time" }
    },
    required: ["result", "success", "timestamp"]
  )
  annotations(
    read_only_hint: true,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false,
    title: "My Tool"
  )

  def self.call(message:, server_context:)
    MCP::Tool::Response.new([{ type: "text", text: "OK" }])
  end
end

tool = MyTool
```

2. By using the `MCP::Tool.define` method with a block:

```ruby
tool = MCP::Tool.define(
  name: "my_tool",
  title: "My Tool",
  description: "This tool performs specific functionality...",
  annotations: {
    read_only_hint: true,
    title: "My Tool"
  }
) do |args, server_context:|
  MCP::Tool::Response.new([{ type: "text", text: "OK" }])
end
```

3. By using the `MCP::Server#define_tool` method with a block:

```ruby
server = MCP::Server.new
server.define_tool(
  name: "my_tool",
  description: "This tool performs specific functionality...",
  annotations: {
    title: "My Tool",
    read_only_hint: true
  }
) do |args, server_context:|
  Tool::Response.new([{ type: "text", text: "OK" }])
end
```

The server_context parameter is the server_context passed into the server and can be used to pass per request information,
e.g. around authentication state.

Tool arguments arrive as a `Hash` with symbol keys at every nesting level, because the transports parse JSON with `symbolize_names: true`.
Read nested objects with symbol keys (`payload[:subject]`, not `payload["subject"]`).
See [Tool argument keys](docs/building-servers.md#tool-argument-keys) for details and a testing tip.

### Tool Annotations

Tools can include annotations that provide additional metadata about their behavior. The following annotations are supported:

- `destructive_hint`: Indicates if the tool performs destructive operations. Defaults to true
- `idempotent_hint`: Indicates if the tool's operations are idempotent. Defaults to false
- `open_world_hint`: Indicates if the tool operates in an open world context. Defaults to true
- `read_only_hint`: Indicates if the tool only reads data (doesn't modify state). Defaults to false
- `title`: A human-readable title for the tool

Annotations can be set either through the class definition using the `annotations` class method or when defining a tool using the `define` method.

> [!NOTE]
> This **Tool Annotations** feature is supported starting from `protocol_version: '2025-03-26'`.

### Tool Output Schemas

Tools can optionally define an `output_schema` to specify the expected structure of their results. This works similarly to how `input_schema` is defined and can be used in three ways:

1. **Class definition with output_schema:**

```ruby
class WeatherTool < MCP::Tool
  tool_name "get_weather"
  description "Get current weather for a location"

  input_schema(
    properties: {
      location: { type: "string" },
      units: { type: "string", enum: ["celsius", "fahrenheit"] }
    },
    required: ["location"]
  )

  output_schema(
    properties: {
      temperature: { type: "number" },
      condition: { type: "string" },
      humidity: { type: "integer" }
    },
    required: ["temperature", "condition", "humidity"]
  )

  def self.call(location:, units: "celsius", server_context:)
    # Call weather API and structure the response
    api_response = WeatherAPI.fetch(location, units)
    weather_data = {
      temperature: api_response.temp,
      condition: api_response.description,
      humidity: api_response.humidity_percent
    }

    output_schema.validate_result(weather_data)

    MCP::Tool::Response.new([{
      type: "text",
      text: weather_data.to_json
    }])
  end
end
```

2. **Using Tool.define with output_schema:**

```ruby
tool = MCP::Tool.define(
  name: "calculate_stats",
  description: "Calculate statistics for a dataset",
  input_schema: {
    properties: {
      numbers: { type: "array", items: { type: "number" } }
    },
    required: ["numbers"]
  },
  output_schema: {
    properties: {
      mean: { type: "number" },
      median: { type: "number" },
      count: { type: "integer" }
    },
    required: ["mean", "median", "count"]
  }
) do |args, server_context:|
  # Calculate statistics and validate against schema
  MCP::Tool::Response.new([{ type: "text", text: "Statistics calculated" }])
end
```

3. **Using OutputSchema objects:**

```ruby
class DataTool < MCP::Tool
  output_schema MCP::Tool::OutputSchema.new(
    properties: {
      success: { type: "boolean" },
      data: { type: "object" }
    },
    required: ["success"]
  )
end
```

Output schema may also describe an array of objects:

```ruby
class WeatherTool < MCP::Tool
  output_schema(
    type: "array",
    items: {
      properties: {
        temperature: { type: "number" },
        condition: { type: "string" },
        humidity: { type: "integer" }
      },
      required: ["temperature", "condition", "humidity"]
    }
  )
end
```

Please note: in this case, you must provide `type: "array"`. The default type for output schemas is `object`,
applied only when the schema declares no root keyword (`type`, `$ref`, `oneOf`, `anyOf`, `allOf`, `not`, `if`, `const`, `enum`).

Per SEP-2106, an output schema may be any valid JSON Schema 2020-12 document, including a primitive root
(`{ type: "string" }`) or a root-level composition:

```ruby
class FlexibleTool < MCP::Tool
  output_schema(
    oneOf: [
      { type: "string" },
      { type: "array", items: { type: "number" } }
    ]
  )
end
```

Input schemas keep `type: "object"` at the root but accept the full 2020-12 vocabulary below it
(`$defs`/`$ref`, `oneOf`/`anyOf`/`allOf`/`not`, `if`/`then`/`else`). Two resource bounds apply to
all tool schemas: only same-document `$ref`s (starting with `#`) are accepted, and documents are
capped at `MCP::Tool::Schema::MAX_SCHEMA_DEPTH` nesting levels and `MCP::Tool::Schema::MAX_SUBSCHEMA_COUNT` subschema objects;
violations raise `ArgumentError` at construction time.

MCP spec for the [Output Schema](https://modelcontextprotocol.io/specification/latest/server/tools#output-schema) specifies that:

- **Server Validation**: Servers MUST provide structured results that conform to the output schema
- **Client Validation**: Clients SHOULD validate structured results against the output schema
- **Better Integration**: Enables strict schema validation, type information, and improved developer experience
- **Backward Compatibility**: Tools returning structured content SHOULD also include serialized JSON in a TextContent block

The output schema follows standard JSON Schema format and helps ensure consistent data exchange between MCP servers and clients.

By default, server-side validation of tool results against `output_schema` is disabled for backwards compatibility. To validate successful tool responses, enable `validate_tool_call_results`:

```ruby
configuration = MCP::Configuration.new(validate_tool_call_results: true)
server = MCP::Server.new(
  name: "example_server",
  tools: [WeatherTool],
  configuration: configuration
)
```

When enabled, successful tool responses for tools with an `output_schema` must include `structured_content` that conforms to the schema. Error responses are not validated against the output schema.

### Tool Responses with Structured Content

Tools can return structured data alongside text content using the `structured_content` parameter.

The structured content will be included in the JSON-RPC response as the `structuredContent` field.

Per SEP-2106, `structured_content` may be any JSON value, not only an object. When a tool returns a non-object value (e.g. an array)
without providing any content blocks, the server automatically mirrors it into `content` as serialized JSON text so older clients
that only read `content` still receive the data.

```ruby
class WeatherTool < MCP::Tool
  description "Get current weather and return structured data"

  def self.call(location:, units: "celsius", server_context:)
    # Call weather API and structure the response
    api_response = WeatherAPI.fetch(location, units)
    weather_data = {
      temperature: api_response.temp,
      condition: api_response.description,
      humidity: api_response.humidity_percent
    }

    output_schema.validate_result(weather_data)

    MCP::Tool::Response.new(
      [{
        type: "text",
        text: weather_data.to_json
      }],
      structured_content: weather_data
    )
  end
end
```

### Tool Responses with Errors

Tools can return error information alongside text content using the `error` parameter.

The error will be included in the JSON-RPC response as the `isError` field.

```ruby
class WeatherTool < MCP::Tool
  description "Get current weather and return structured data"

  def self.call(server_context:)
    # Do something here
    content = {}

    MCP::Tool::Response.new(
      [{
        type: "text",
        text: content.to_json
      }],
      structured_content: content,
      error: true
    )
  end
end
```

### Prompts

MCP spec includes [Prompts](https://modelcontextprotocol.io/specification/latest/server/prompts), which enable servers to define reusable prompt templates and workflows that clients can easily surface to users and LLMs.

The `MCP::Prompt` class provides three ways to create prompts:

1. As a class definition with metadata:

```ruby
class MyPrompt < MCP::Prompt
  prompt_name "my_prompt"  # Optional - defaults to underscored class name
  title "My Prompt"
  description "This prompt performs specific functionality..."
  arguments [
    MCP::Prompt::Argument.new(
      name: "message",
      title: "Message Title",
      description: "Input message",
      required: true
    )
  ]
  meta({ version: "1.0", category: "example" })

  class << self
    def template(args, server_context:)
      MCP::Prompt::Result.new(
        description: "Response description",
        messages: [
          MCP::Prompt::Message.new(
            role: "user",
            content: MCP::Content::Text.new("User message")
          ),
          MCP::Prompt::Message.new(
            role: "assistant",
            content: MCP::Content::Text.new(args["message"])
          )
        ]
      )
    end
  end
end

prompt = MyPrompt
```

2. Using the `MCP::Prompt.define` method:

```ruby
prompt = MCP::Prompt.define(
  name: "my_prompt",
  title: "My Prompt",
  description: "This prompt performs specific functionality...",
  arguments: [
    MCP::Prompt::Argument.new(
      name: "message",
      title: "Message Title",
      description: "Input message",
      required: true
    )
  ],
  meta: { version: "1.0", category: "example" }
) do |args, server_context:|
  MCP::Prompt::Result.new(
    description: "Response description",
    messages: [
      MCP::Prompt::Message.new(
        role: "user",
        content: MCP::Content::Text.new("User message")
      ),
      MCP::Prompt::Message.new(
        role: "assistant",
        content: MCP::Content::Text.new(args["message"])
      )
    ]
  )
end
```

3. Using the `MCP::Server#define_prompt` method:

```ruby
server = MCP::Server.new
server.define_prompt(
  name: "my_prompt",
  description: "This prompt performs specific functionality...",
  arguments: [
    Prompt::Argument.new(
      name: "message",
      title: "Message Title",
      description: "Input message",
      required: true
    )
  ],
  meta: { version: "1.0", category: "example" }
) do |args, server_context:|
  Prompt::Result.new(
    description: "Response description",
    messages: [
      Prompt::Message.new(
        role: "user",
        content: Content::Text.new("User message")
      ),
      Prompt::Message.new(
        role: "assistant",
        content: Content::Text.new(args["message"])
      )
    ]
  )
end
```

The server_context parameter is the server_context passed into the server and can be used to pass per request information,
e.g. around authentication state or user preferences.

### Key Components

- `MCP::Prompt::Argument` - Defines input parameters for the prompt template with name, title, description, and required flag
- `MCP::Prompt::Message` - Represents a message in the conversation with a role and content
- `MCP::Prompt::Result` - The output of a prompt template containing description and messages
- `MCP::Content::Text` - Text content for messages

### Usage

Register prompts with the MCP server:

```ruby
server = MCP::Server.new(
  name: "my_server",
  prompts: [MyPrompt],
  server_context: { user_id: current_user.id },
)
```

The server will handle prompt listing and execution through the MCP protocol methods:

- `prompts/list` - Lists all registered prompts and their schemas
- `prompts/get` - Retrieves and executes a specific prompt with arguments

### Resources

MCP spec includes [Resources](https://modelcontextprotocol.io/specification/latest/server/resources).

### Reading Resources

Like tools and prompts, resources can be defined in three ways.

1. As a class that inherits from `MCP::Resource`, implementing `contents` to serve the resource body:

```ruby
class MyResource < MCP::Resource
  uri "https://example.com/my_resource"
  resource_name "my-resource"
  title "My Resource"
  description "Lorem ipsum dolor sit amet"
  mime_type "text/html"

  class << self
    def contents
      [MCP::Resource::TextContents.new(
        uri: uri,
        mime_type: mime_type,
        text: "Hello from example resource!"
      )]
    end
  end
end

server = MCP::Server.new(
  name: "my_server",
  resources: [MyResource],
)
```

`resources/read` requests are routed automatically: when the requested URI matches a registered
class-based resource, its `contents` method is called. `contents` may return an array of
`MCP::Resource::TextContents` / `MCP::Resource::BlobContents` objects (or plain hashes), or a single one.
Like tools, `contents` can opt in to a `server_context:` keyword argument to receive per-request context.

When class-based resources or resource templates are registered and a `resources/read` request
does not match any of them, the server responds with the standard JSON-RPC Invalid Params error
(`-32602`) carrying the requested URI in the error `data` member, per SEP-2164.

2. With the `MCP::Resource.define` method, whose block implements `contents`:

```ruby
resource = MCP::Resource.define(
  uri: "https://example.com/my_resource",
  name: "my-resource",
  mime_type: "text/html",
) do
  [MCP::Resource::TextContents.new(uri: uri, mime_type: mime_type, text: "Hello!")]
end
```

3. Using the `MCP::Server#define_resource` method:

```ruby
server = MCP::Server.new(name: "my_server")
server.define_resource(
  uri: "https://example.com/my_resource",
  name: "my-resource",
  mime_type: "text/html",
) do
  [MCP::Resource::TextContents.new(uri: "https://example.com/my_resource", mime_type: "text/html", text: "Hello!")]
end
```

Alternatively, resources can be registered as plain data objects with `MCP::Resource.new`,
in which case the server only lists them:

```ruby
resource = MCP::Resource.new(
  uri: "https://example.com/my_resource",
  name: "my-resource",
  title: "My Resource",
  description: "Lorem ipsum dolor sit amet",
  mime_type: "text/html",
)

server = MCP::Server.new(
  name: "my_server",
  resources: [resource],
)
```

With plain data resources, the server must register a handler for the `resources/read` method to
retrieve a resource dynamically.

```ruby
server.resources_read_handler do |params|
  [{
    uri: params[:uri],
    mimeType: "text/plain",
    text: "Hello from example resource! URI: #{params[:uri]}"
  }]
end
```

otherwise `resources/read` requests will be a no-op. Note that a `resources_read_handler` fully replaces
the default `resources/read` handling, including the automatic routing to class-based resources described above.

For unknown URIs, raise `MCP::Server::ResourceNotFoundError` from the handler.
Per SEP-2164, the server then responds with the standard JSON-RPC Invalid Params error (`-32602`)
carrying the requested URI in the error `data` member:

```ruby
server.resources_read_handler do |params|
  resource = lookup(params[:uri])
  raise MCP::Server::ResourceNotFoundError.new(params[:uri], params) unless resource

  [{ uri: params[:uri], mimeType: resource.mime_type, text: resource.body }]
end
```

### Resource Templates

Resource templates follow the same pattern. Class-based templates declare a `uri_template` and
receive the variables extracted from the requested URI as keyword arguments to `contents`:

```ruby
class UserProfileTemplate < MCP::ResourceTemplate
  uri_template "users://{user_id}/profile"
  resource_template_name "user-profile"
  title "User Profile"
  description "Profile data for a user"
  mime_type "application/json"

  class << self
    def contents(user_id:)
      [MCP::Resource::TextContents.new(
        uri: "users://#{user_id}/profile",
        mime_type: mime_type,
        text: { id: user_id }.to_json
      )]
    end
  end
end

server = MCP::Server.new(
  name: "my_server",
  resource_templates: [UserProfileTemplate],
)
```

A `resources/read` request for `users://42/profile` calls `UserProfileTemplate.contents(user_id: "42")`.
An exact match against a registered resource takes precedence over template matching.
`contents` can also opt in to a `server_context:` keyword argument.

URI template matching supports simple [RFC 6570](https://www.rfc-editor.org/rfc/rfc6570) level 1 `{variable}` expressions only:

- Operator expressions such as `{+path}`, `{#fragment}`, or `{?query}` are treated as literal text and never match an expanded URI.
- A variable matches one or more characters excluding `/`.
- Extracted values are not percent-decoded.

The `MCP::ResourceTemplate.define` and `MCP::Server#define_resource_template` methods are also available,
mirroring the resource variants:

```ruby
server.define_resource_template(
  uri_template: "users://{user_id}/profile",
  name: "user-profile",
  mime_type: "application/json",
) do |user_id:|
  [MCP::Resource::TextContents.new(
    uri: "users://#{user_id}/profile",
    mime_type: "application/json",
    text: { id: user_id }.to_json
  )]
end
```

Resource templates can also be registered as plain data objects with `MCP::ResourceTemplate.new`,
in which case reads must be served by a `resources_read_handler`:

```ruby
resource_template = MCP::ResourceTemplate.new(
  uri_template: "https://example.com/my_resource_template",
  name: "my-resource-template",
  title: "My Resource Template",
  description: "Lorem ipsum dolor sit amet",
  mime_type: "text/html",
)

server = MCP::Server.new(
  name: "my_server",
  resource_templates: [resource_template],
)
```

### Roots

The Model Context Protocol allows servers to request filesystem roots from clients through the `roots/list` method.
Roots define the boundaries of where a server can operate, providing a list of directories and files the client has made available.

**Key Concepts:**

- **Server-to-Client Request**: Like sampling, roots listing is initiated by the server
- **Client Capability**: Clients must declare `roots` capability during initialization
- **Change Notifications**: Clients that support `roots.listChanged` send `notifications/roots/list_changed` when roots change

> [!NOTE]
> Per SEP-2260, server-to-client requests (`roots/list`, `sampling/createMessage`, `elicitation/create`) must be associated with
> an originating client request (`ping` is exempt). Use the `server_context` passed to your handler, which stamps the association
> automatically and routes the request onto the originating POST stream on the Streamable HTTP transport. Calling the corresponding
> `ServerSession` methods without `related_request_id:` still works but emits a deprecation warning.

**Using Roots in Tools:**

Tools that accept a `server_context:` parameter can call `list_roots` on it.
The request is automatically routed to the correct client session:

```ruby
class FileSearchTool < MCP::Tool
  description "Search files within the client's project roots"
  input_schema(
    properties: {
      query: { type: "string" }
    },
    required: ["query"]
  )

  def self.call(query:, server_context:)
    roots = server_context.list_roots
    root_uris = roots[:roots].map { |root| root[:uri] }

    MCP::Tool::Response.new([{
      type: "text",
      text: "Searching in roots: #{root_uris.join(", ")}"
    }])
  end
end
```

Result contains an array of root objects:

```ruby
{
  roots: [
    { uri: "file:///home/user/projects/myproject", name: "My Project" },
    { uri: "file:///home/user/repos/backend", name: "Backend Repository" }
  ]
}
```

**Handling Root Changes:**

Register a callback to be notified when the client's roots change:

```ruby
server.roots_list_changed_handler do
  puts "Client's roots have changed, tools will see updated roots on next call."
end
```

**Error Handling:**

- Raises `RuntimeError` if client does not support `roots` capability
- Raises `StandardError` if client returns an error response

### Resource Subscriptions

Resource subscriptions allow clients to monitor specific resources for changes.
When a subscribed resource is updated, the server sends a notification to the client.

The SDK does not track subscription state internally.
Server developers register handlers and manage their own subscription state.
Three methods are provided:

- `Server#resources_subscribe_handler` - registers a handler for `resources/subscribe` requests
- `Server#resources_unsubscribe_handler` - registers a handler for `resources/unsubscribe` requests
- `ServerContext#notify_resources_updated` - sends a `notifications/resources/updated` notification to the subscribing client

```ruby
subscribed_uris = Set.new

server = MCP::Server.new(
  name: "my_server",
  resources: [my_resource],
  capabilities: { resources: { subscribe: true } },
)

server.resources_subscribe_handler do |params|
  subscribed_uris.add(params[:uri].to_s)
end

server.resources_unsubscribe_handler do |params|
  subscribed_uris.delete(params[:uri].to_s)
end

server.define_tool(name: "update_resource") do |server_context:, **args|
  if subscribed_uris.include?("test://my-resource")
    server_context.notify_resources_updated(uri: "test://my-resource")
  end
  MCP::Tool::Response.new([MCP::Content::Text.new("Resource updated").to_h])
end
```

### Sampling

The Model Context Protocol allows servers to request LLM completions from clients through the `sampling/createMessage` method.
This enables servers to leverage the client's LLM capabilities without needing direct access to AI models.

**Key Concepts:**

- **Server-to-Client Request**: Unlike typical MCP methods (client to server), sampling is initiated by the server
- **Client Capability**: Clients must declare `sampling` capability during initialization
- **Tool Support**: When using tools in sampling requests, clients must declare `sampling.tools` capability
- **Human-in-the-Loop**: Clients can implement user approval before forwarding requests to LLMs

**Using Sampling in Tools:**

Tools that accept a `server_context:` parameter can call `create_sampling_message` on it.
The request is automatically routed to the correct client session:

```ruby
class SummarizeTool < MCP::Tool
  description "Summarize text using LLM"
  input_schema(
    properties: {
      text: { type: "string" }
    },
    required: ["text"]
  )

  def self.call(text:, server_context:)
    result = server_context.create_sampling_message(
      messages: [
        { role: "user", content: { type: "text", text: "Please summarize: #{text}" } }
      ],
      max_tokens: 500
    )

    MCP::Tool::Response.new([{
      type: "text",
      text: result[:content][:text]
    }])
  end
end

server = MCP::Server.new(name: "my_server", tools: [SummarizeTool])
```

**Parameters:**

Required:

- `messages:` (Array) - Array of message objects with `role` and `content`
- `max_tokens:` (Integer) - Maximum tokens in the response

Optional:

- `system_prompt:` (String) - System prompt for the LLM
- `model_preferences:` (Hash) - Model selection preferences (e.g., `{ intelligencePriority: 0.8 }`)
- `include_context:` (String) - Context inclusion: `"none"`, `"thisServer"`, or `"allServers"` (soft-deprecated)
- `temperature:` (Float) - Sampling temperature
- `stop_sequences:` (Array) - Sequences that stop generation
- `metadata:` (Hash) - Additional metadata
- `tools:` (Array) - Tools available to the LLM (requires `sampling.tools` capability)
- `tool_choice:` (Hash) - Tool selection mode (e.g., `{ mode: "auto" }`)

**Error Handling:**

- Raises `RuntimeError` if client does not support `sampling` capability
- Raises `RuntimeError` if `tools` are used but client lacks `sampling.tools` capability
- Raises `StandardError` if client returns an error response

### Notifications

The server supports sending notifications to clients when lists of tools, prompts, or resources change. This enables real-time updates without polling.

#### Notification Methods

The server provides the following notification methods:

- `notify_tools_list_changed` - Send a notification when the tools list changes
- `notify_prompts_list_changed` - Send a notification when the prompts list changes
- `notify_resources_list_changed` - Send a notification when the resources list changes
- `notify_log_message` - Send a structured logging notification message

#### Session Scoping

When using Streamable HTTP transport with multiple clients, each client connection gets its own session. Notifications are scoped as follows:

- **`report_progress`** and **`notify_log_message`** called via `server_context` inside a tool handler are automatically sent only to the requesting client.
No extra configuration is needed.
- **`notify_tools_list_changed`**, **`notify_prompts_list_changed`**, and **`notify_resources_list_changed`** are always broadcast to all connected clients,
as they represent server-wide state changes. These should be called on the `server` instance directly.

#### Notification Format

Notifications follow the JSON-RPC 2.0 specification and use these method names:

- `notifications/tools/list_changed`
- `notifications/prompts/list_changed`
- `notifications/resources/list_changed`
- `notifications/cancelled`
- `notifications/progress`
- `notifications/message`

### Cancellation

The MCP Ruby SDK supports server-side handling of the
[MCP `notifications/cancelled` utility](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation).
When a client sends `notifications/cancelled` for an in-flight request, the server stops
processing cooperatively and suppresses the JSON-RPC response for that request.

Cancellation is cooperative: the SDK does not forcibly terminate tool code. Instead,
a `MCP::Cancellation` token is threaded through `server_context`, and long-running tools
poll it to exit early. When a tool returns after cancellation has been observed,
the server suppresses the JSON-RPC response, matching the spec. The `initialize` request
is never cancellable per the spec.

Client-initiated cancellation is also supported: see [Client-Side: Cancelling an In-Flight Request](#client-side-cancelling-an-in-flight-request) below.

#### Server-Side: Handlers that Check for Cancellation

Any handler that opts in to `server_context:` - tools (`Tool.call`), prompt templates,
`resources_read_handler`, `completion_handler`, `resources_subscribe_handler`,
`resources_unsubscribe_handler`, and `define_custom_method` blocks - receives
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

#### Nested Server-to-Client Requests Are Cancelled Automatically

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

#### Client-Side: Cancelling an In-Flight Request

`MCP::Client` lets the caller cancel a request it has already issued. The recommended pattern is to pass
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
`prompts`, `list_prompts`, `call_tool`, `read_resource`, `get_prompt`, `complete`, `ping`) accept the `cancellation:` keyword.
Request ids are managed internally, so the token is the only thing a caller needs to cancel a request.

> [!NOTE]
> When a cancel wins the race, the SDK's worker thread that is blocked on the underlying I/O is *not* force-killed;
> it stays blocked until the transport actually returns (or the user closes the transport). This matches the server-side
> `StreamableHTTPTransport#send_request` trade-off. For `StreamableHTTPTransport#send_request` trade-off. For `Client::HTTP`
> the leak resolves as soon as the server sends any response; for `Client::Stdio` you may need to call `client.transport.close`
> to free the thread if the server stops responding entirely. The cancel-dispatch thread waits for the worker's send-boundary signal
> (`&on_sent` from `send_request`) before issuing `notifications/cancelled`, so the cancel is held until the worker has at
> least committed to writing the request; while the worker is wedged the cancel notification is deferred along with it.

##### Wire-order guarantees

`Client::Stdio` serializes the request write and any subsequent `notifications/cancelled` write through a single `@write_mutex`,
so the server is guaranteed to read the request line before the cancel line.

`Client::HTTP` cannot offer the same wire-arrival guarantee. Faraday's synchronous `post` does not expose a post-write / pre-response hook,
so the SDK yields just before the request POST is dispatched. After the yield, the cancel-dispatch thread issues a separate `notifications/cancelled` POST
on its own connection, and the two POSTs may overlap on the network. The spec is satisfied either way: the sender has already issued the request and
still believes it to be in-progress when issuing the cancel ([MCP cancellation spec](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation)),
and on the receiver side, "receivers MAY ignore a cancellation notification whose `requestId` is unknown" covers the case where the cancel POST
happens to arrive first. The calling thread raises `MCP::CancelledError` regardless of network ordering.

##### Custom transports

Custom transports that want to support `cancellation:` must implement `send_notification(notification:)` so `notifications/cancelled` can be delivered.
They should also accept the optional block passed to `send_request(request:, &on_sent)` and call it once the request bytes have been handed off to the wire
(under a write-side mutex for stdio-style transports, immediately before the synchronous round-trip for HTTP-style transports).
The cancel-dispatch thread waits on this signal before sending `notifications/cancelled`. Transports that do not invoke the block fall back to waiting for
the worker thread to terminate, which preserves wire-order at the cost of delaying the cancel notification until the request has fully completed.

### Ping

The MCP Ruby SDK supports the
[MCP `ping` utility](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/ping),
which allows either side of the connection to verify that the peer is still responsive.
A `ping` request has no parameters, and the receiver MUST respond promptly with an empty result.

#### Server-Side

Servers respond to incoming `ping` requests automatically - no setup is required.
Any `MCP::Server` instance replies with an empty result.

Servers can also send `ping` requests to the client via `ServerSession#ping`.
Inside a tool handler that receives `server_context:`, call `ping` on it:

```ruby
class HealthCheckTool < MCP::Tool
  description "Verifies the client is still responsive"

  def self.call(server_context:)
    server_context.ping # => {} on success

    MCP::Tool::Response.new([{ type: "text", text: "client is alive" }])
  end
end
```

`#ping` raises `MCP::Server::ValidationError` when the client returns a `result`
that is not a Hash. Transport-level errors (e.g., the client returning a JSON-RPC error)
propagate as exceptions raised by the transport layer.

#### Client-Side

`MCP::Client` exposes `ping` to send a ping to the server:

```ruby
client = MCP::Client.new(transport: transport)
client.ping # => {} on success
```

`#ping` raises `MCP::Client::ServerError` when the server returns a JSON-RPC error.
It raises `MCP::Client::ValidationError` when the response `result` is missing or
is not a Hash (matching the spec requirement that `result` be an object).
Transport-level errors (for example, `MCP::Client::Stdio`'s `read_timeout:` firing)
propagate as exceptions raised by the transport layer.

### Progress

The MCP Ruby SDK supports progress tracking for long-running tool operations,
following the [MCP Progress specification](https://modelcontextprotocol.io/specification/latest/server/utilities/progress).

#### How Progress Works

1. **Client Request**: The client sends a `progressToken` in the `_meta` field when calling a tool
2. **Server Notification**: The server sends `notifications/progress` messages back to the client during tool execution
3. **Tool Integration**: Tools call `server_context.report_progress` to report incremental progress

#### Server-Side: Tool with Progress

Tools that accept a `server_context:` parameter can call `report_progress` on it.
The server automatically wraps the context in an `MCP::ServerContext` instance that provides this method:

```ruby
class LongRunningTool < MCP::Tool
  description "A tool that reports progress during execution"
  input_schema(
    properties: {
      count: { type: "integer" },
    },
    required: ["count"]
  )

  def self.call(count:, server_context:)
    count.times do |i|
      # Do work here.
      server_context.report_progress(i + 1, total: count, message: "Processing item #{i + 1}")
    end

    MCP::Tool::Response.new([{ type: "text", text: "Done" }])
  end
end
```

The `server_context.report_progress` method accepts:

- `progress` (required) — current progress value (numeric)
- `total:` (optional) — total expected value, so clients can display a percentage
- `message:` (optional) — human-readable status message

**Key Features:**

- Tools report progress via `server_context.report_progress`
- `report_progress` is a no-op when no `progressToken` was provided by the client
- Supports both numeric and string progress tokens

### Completions

MCP spec includes [Completions](https://modelcontextprotocol.io/specification/latest/server/utilities/completion),
which enable servers to provide autocompletion suggestions for prompt arguments and resource URIs.

To enable completions, declare the `completions` capability and register a handler:

```ruby
server = MCP::Server.new(
  name: "my_server",
  prompts: [CodeReviewPrompt],
  resource_templates: [FileTemplate],
  capabilities: { completions: {} },
)

server.completion_handler do |params|
  ref = params[:ref]
  argument = params[:argument]
  value = argument[:value]

  case ref[:type]
  when "ref/prompt"
    values = case argument[:name]
    when "language"
      ["python", "pytorch", "pyside"].select { |v| v.start_with?(value) }
    else
      []
    end
    { completion: { values: values, hasMore: false } }
  when "ref/resource"
    { completion: { values: [], hasMore: false } }
  end
end
```

The handler receives a `params` hash with:

- `ref` - The reference (`{ type: "ref/prompt", name: "..." }` or `{ type: "ref/resource", uri: "..." }`)
- `argument` - The argument being completed (`{ name: "...", value: "..." }`)
- `context` (optional) - Previously resolved arguments (`{ arguments: { ... } }`)

The handler must return a hash with a `completion` key containing `values` (array of strings), and optionally `total` and `hasMore`.
The SDK automatically enforces the 100-item limit per the MCP specification.

The server validates that the referenced prompt, resource, or resource template is registered before calling the handler.
Requests for unknown references return an error.

### Elicitation

The MCP Ruby SDK supports [elicitation](https://modelcontextprotocol.io/specification/2025-11-25/client/elicitation),
which allows servers to request additional information from users through the client during tool execution.

Elicitation is a **server-to-client request**. The server sends a request and blocks until the user responds via the client.

#### Capabilities

Clients must declare the `elicitation` capability during initialization. The server checks this before sending any elicitation request
and raises a `RuntimeError` if the client does not support it.

For URL mode support, the client must also declare `elicitation.url` capability.

#### Using Elicitation in Tools

Tools that accept a `server_context:` parameter can call `create_form_elicitation` on it:

```ruby
server.define_tool(name: "collect_info", description: "Collect user info") do |server_context:|
  result = server_context.create_form_elicitation(
    message: "Please provide your name",
    requested_schema: {
      type: "object",
      properties: { name: { type: "string" } },
      required: ["name"],
    },
  )

  MCP::Tool::Response.new([{ type: "text", text: "Hello, #{result[:content][:name]}" }])
end
```

#### Form Mode

Form mode collects structured data from the user directly through the MCP client:

```ruby
server.define_tool(name: "collect_contact", description: "Collect contact info") do |server_context:|
  result = server_context.create_form_elicitation(
    message: "Please provide your contact information",
    requested_schema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Your full name" },
        email: { type: "string", format: "email", description: "Your email address" },
      },
      required: ["name", "email"],
    },
  )

  text = case result[:action]
  when "accept"
    "Hello, #{result[:content][:name]} (#{result[:content][:email]})"
  when "decline"
    "User declined"
  when "cancel"
    "User cancelled"
  end

  MCP::Tool::Response.new([{ type: "text", text: text }])
end
```

#### URL Mode

URL mode directs the user to an external URL for out-of-band interactions such as OAuth flows:

```ruby
server.define_tool(name: "authorize_github", description: "Authorize GitHub") do |server_context:|
  elicitation_id = SecureRandom.uuid

  result = server_context.create_url_elicitation(
    message: "Please authorize access to your GitHub account",
    url: "https://example.com/oauth/authorize?elicitation_id=#{elicitation_id}",
    elicitation_id: elicitation_id,
  )

  server_context.notify_elicitation_complete(elicitation_id: elicitation_id)

  MCP::Tool::Response.new([{ type: "text", text: "Authorization complete" }])
end
```

#### URLElicitationRequiredError

When a tool cannot proceed until an out-of-band elicitation is completed, raise `MCP::Server::URLElicitationRequiredError`.
This returns a JSON-RPC error with code `-32042` to the client:

```ruby
server.define_tool(name: "access_github", description: "Access GitHub") do |server_context:|
  raise MCP::Server::URLElicitationRequiredError.new([
    {
      mode: "url",
      elicitationId: SecureRandom.uuid,
      url: "https://example.com/oauth/authorize",
      message: "GitHub authorization is required.",
    },
  ])
end
```

### Logging

The MCP Ruby SDK supports structured logging through the `notify_log_message` method, following the [MCP Logging specification](https://modelcontextprotocol.io/specification/latest/server/utilities/logging).

The `notifications/message` notification is used for structured logging between client and server.

#### Log Levels

The SDK supports 8 log levels with increasing severity:

- `debug` - Detailed debugging information
- `info` - General informational messages
- `notice` - Normal but significant events
- `warning` - Warning conditions
- `error` - Error conditions
- `critical` - Critical conditions
- `alert` - Action must be taken immediately
- `emergency` - System is unusable

#### How Logging Works

1. **Client Configuration**: The client sends a `logging/setLevel` request to configure the minimum log level
2. **Server Filtering**: The server only sends log messages at the configured level or higher severity
3. **Notification Delivery**: Log messages are sent as `notifications/message` to the client

For example, if the client sets the level to `"error"` (severity 4), the server will send messages with levels: `error`, `critical`, `alert`, and `emergency`.

For more details, see the [MCP Logging specification](https://modelcontextprotocol.io/specification/latest/server/utilities/logging).

**Usage Example:**

```ruby
server = MCP::Server.new(name: "my_server")
transport = MCP::Server::Transports::StdioTransport.new(server)

# The client first configures the logging level (on the client side):
transport.send_request(
  request: {
    jsonrpc: "2.0",
    method: "logging/setLevel",
    params: { level: "info" },
    id: session_id # Unique request ID within the session
  }
)

# Send log messages at different severity levels
server.notify_log_message(
  data: { message: "Application started successfully" },
  level: "info"
)

server.notify_log_message(
  data: { message: "Configuration file not found, using defaults" },
  level: "warning"
)

server.notify_log_message(
  data: {
    error: "Database connection failed",
    details: { host: "localhost", port: 5432 }
  },
  level: "error",
  logger: "DatabaseLogger" # Optional logger name
)
```

**Key Features:**

- Supports 8 log levels (debug, info, notice, warning, error, critical, alert, emergency) based on https://modelcontextprotocol.io/specification/2025-06-18/server/utilities/logging#log-levels
- Server has capability `logging` to send log messages
- Messages are only sent if a transport is configured
- Messages are filtered based on the client's configured log level
- If the log level hasn't been set by the client, no messages will be sent

#### Transport Support

- **stdio**: Notifications are sent as JSON-RPC 2.0 messages to stdout
- **Streamable HTTP**: Notifications are sent as JSON-RPC 2.0 messages over HTTP with streaming (chunked transfer or SSE)

#### Usage Example

```ruby
server = MCP::Server.new(name: "my_server")

# Default Streamable HTTP - session oriented
transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)

# When tools change, notify clients
server.define_tool(name: "new_tool") { |**args| { result: "ok" } }
server.notify_tools_list_changed
```

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

By default, stateful sessions are bounded so an `initialize` flood cannot retain sessions until memory is exhausted:
they expire after `session_idle_timeout` seconds of inactivity (default 1800, i.e. 30 minutes) and the concurrent
session count is capped at `max_sessions` (default 10000). A session's idle timer is reset by activity that touches it
(a GET, or a regular-request POST), and expired sessions are collected by a background reaper roughly once a minute,
so cleanup lags inactivity by up to that interval. At the cap, the transport first reclaims any already-expired slots
and then, if still full, rejects a new `initialize` with HTTP 503 (it does not evict an existing session).

```ruby
# Tune the limits
transport = MCP::Server::Transports::StreamableHTTPTransport.new(server, session_idle_timeout: 900, max_sessions: 5000)

# Opt out of expiry and/or the cap (not recommended on internet-facing deployments)
transport = MCP::Server::Transports::StreamableHTTPTransport.new(server, session_idle_timeout: nil, max_sessions: nil)
```

Stateless mode (`stateless: true`) retains no sessions, so neither limit applies to it.

#### Session Ownership

`StreamableHTTPTransport` issues a random `SecureRandom.uuid` session ID and validates incoming requests by session
existence and idle timeout only. It does not bind a session to a user, because the transport never receives
an authenticated identity on its own. A caller that obtains a valid session ID could therefore act on that session,
so binding a session to a user is the deploying application's responsibility (the MCP spec frames this as a SHOULD).

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

Without a validator the transport does not enforce ownership. As a limited defense in depth (not authentication),
it also records the `Origin` header at `initialize` and rejects a later request whose `Origin` differs, but only
when both are present - a non-browser client that omits `Origin` (e.g. `curl` or a script) is not stopped by this check.
Enforcing ownership against a determined attacker requires supplying the validator with an authenticated principal.

#### Request Size Limits

`StreamableHTTPTransport` bounds how many bytes a single POST body may allocate, so a peer cannot exhaust memory
with one oversized message. A body larger than `max_request_bytes` (default 4 MiB) is rejected with HTTP 413,
and JSON nesting depth is capped. The 4 MiB default comfortably fits a typical JSON-RPC message (a 4 MiB JSON
string decodes to roughly 3 MiB of base64 payload) and matches the TypeScript SDK's 4 MB default; raise it only
if you exchange unusually large payloads:

```ruby
transport = MCP::Server::Transports::StreamableHTTPTransport.new(server, max_request_bytes: 8 * 1024 * 1024)
```

### Pagination

The MCP Ruby SDK supports [pagination](https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/pagination)
for list operations that may return large result sets. Pagination uses string cursor tokens carrying a zero-based offset,
treated as opaque by clients: the server decides page size, and the client follows `nextCursor` until the server omits it.

Pagination applies to `tools/list`, `prompts/list`, `resources/list`, and `resources/templates/list`.

#### Server-Side: Enabling Pagination

Pass `page_size:` to `MCP::Server.new` to split list responses into pages. When `page_size` is omitted (the default),
list responses contain all items in a single response, preserving the pre-pagination behavior.

```ruby
server = MCP::Server.new(
  name: "my_server",
  tools: tools,
  page_size: 50,
)
```

When `page_size` is set, list responses include a `nextCursor` field whenever more pages are available:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "tools": [
      { "name": "example_tool" }
    ],
    "nextCursor": "50"
  }
}
```

Invalid cursors (e.g. non-numeric, negative, or out-of-range) are rejected with JSON-RPC error code `-32602 (Invalid params)` per the MCP specification.

#### Client-Side: Iterating Pages

`MCP::Client` exposes `list_tools`, `list_prompts`, `list_resources`, and `list_resource_templates`.
**Each call issues exactly one `*/list` JSON-RPC request and returns exactly one page** — not the full collection.
The returned result object (`MCP::Client::ListToolsResult` etc.) exposes the page items and the next cursor as method accessors:

```ruby
client = MCP::Client.new(transport: transport)

cursor = nil
loop do
  page = client.list_tools(cursor: cursor)
  page.tools.each { |tool| process(tool) }
  cursor = page.next_cursor
  break unless cursor
end
```

The same pattern applies to `list_prompts` (`page.prompts`), `list_resources` (`page.resources`), and
`list_resource_templates` (`page.resource_templates`). `next_cursor` is `nil` on the final page.

Because a single call returns a single page, how many items come back depends on the server's `page_size` configuration:

| Server `page_size` | `client.list_tools(cursor: nil)`                                    |
|--------------------|---------------------------------------------------------------------|
| Not set (default)  | Returns every item in one response. `next_cursor` is `nil`.         |
| Set to `N`         | Returns the first `N` items. `next_cursor` is set for continuation. |

If your application needs the complete collection regardless of how the server is configured, either loop on
`next_cursor` as shown above, or use the whole-collection methods described below.

#### Fetching the Complete Collection

`client.tools`, `client.resources`, `client.resource_templates`, and `client.prompts` auto-iterate
through all pages and return a plain array of items, guaranteeing the full collection regardless
of the server's `page_size` setting. When a server paginates, they issue multiple JSON-RPC round
trips per call and break out of the pagination loop if the server returns the same `nextCursor`
twice in a row as a safety measure.

```ruby
tools = client.tools # => Array<MCP::Client::Tool> of every tool on the server.
```

Use these when you want the complete list; use `list_tools(cursor:)` etc. when you need
fine-grained iteration (e.g. to stream-process pages without loading everything into memory).

#### List Result Caching (`ttlMs` / `cacheScope`)

Per SEP-2549, list and read results can carry cache hints telling clients how long a result stays fresh (`ttlMs`, max-age semantics in milliseconds;
`0` means do not cache) and whether shared intermediaries may cache it (`cacheScope`: `"public"` or `"private"`).

Emission is opt-in: pass `ttl_ms:` and/or `cache_scope:` to `MCP::Server.new` and both fields are added to `tools/list`, `prompts/list`, `resources/list`,
`resources/templates/list`, and `resources/read` results (a missing field is filled with the defaults `ttlMs: 0` / `cacheScope: "public"`).
When neither is set, responses are serialized exactly as before.

```ruby
server = MCP::Server.new(
  name: "my_server",
  tools: tools,
  ttl_ms: 60_000,        # results stay fresh for one minute
  cache_scope: "private", # only the requesting client may cache them
)
```

A `resources_read_handler` can override the hints per result by returning a full result hash instead of bare contents:

```ruby
server.resources_read_handler do |params|
  { contents: [{ uri: params[:uri], mimeType: "text/plain", text: "..." }], ttlMs: 5_000 }
end
```

On the client, the values are surfaced on the paginated result structs as `ttl_ms` and `cache_scope`:

```ruby
page = client.list_tools
page.ttl_ms      # => 60000 (nil when the server sent no hint)
page.cache_scope # => "private"
```

### Advanced

#### Custom Methods

The server allows you to define custom JSON-RPC methods beyond the standard MCP protocol methods using the `define_custom_method` method:

```ruby
server = MCP::Server.new(name: "my_server")

# Define a custom method that returns a result
server.define_custom_method(method_name: "add") do |params|
  params[:a] + params[:b]
end

# Define a custom notification method (returns nil)
server.define_custom_method(method_name: "notify") do |params|
  # Process notification
  nil
end
```

**Key Features:**

- Accepts any method name as a string
- Block receives the request parameters as a hash
- Can handle both regular methods (with responses) and notifications
- Prevents overriding existing MCP protocol methods
- Supports instrumentation callbacks for monitoring

**Usage Example:**

```ruby
# Client request
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "add",
  "params": { "a": 5, "b": 3 }
}

# Server response
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": 8
}
```

**Error Handling:**

- Raises `MCP::Server::MethodAlreadyDefinedError` if trying to override an existing method
- Supports the same exception reporting and instrumentation as standard methods

## Building an MCP Client

The `MCP::Client` class provides an interface for interacting with MCP servers.

This class supports:

- Liveness check via the `ping` method (`MCP::Client#ping`)
- Tool listing via the `tools/list` method (`MCP::Client#tools`)
- Tool invocation via the `tools/call` method (`MCP::Client#call_tool`)
- Resource listing via the `resources/list` method (`MCP::Client#resources`)
- Resource template listing via the `resources/templates/list` method (`MCP::Client#resource_templates`)
- Resource reading via the `resources/read` method (`MCP::Client#read_resource`)
- Prompt listing via the `prompts/list` method (`MCP::Client#prompts`)
- Prompt retrieval via the `prompts/get` method (`MCP::Client#get_prompt`)
- Completion requests via the `completion/complete` method (`MCP::Client#complete`)
- Automatic JSON-RPC 2.0 message formatting
- UUID request ID generation

Clients are initialized with a transport layer instance that handles the low-level communication mechanics.
Authorization is handled by the transport layer.

## Transport Layer Interface

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
```

### Stdio Transport Layer

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

### HTTP Transport Layer

Use the `MCP::Client::HTTP` transport to interact with MCP servers using simple HTTP requests.

You'll need to add `faraday` as a dependency in order to use the HTTP transport layer. Add `event_stream_parser` as well if the server uses SSE (`text/event-stream`) responses:

```ruby
gem 'mcp'
gem 'faraday', '>= 2.0'
gem 'event_stream_parser', '>= 1.0' # optional, required only for SSE responses
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

The server will send `notifications/progress` back to the client during execution.

#### Server-to-Client Requests (Elicitation)

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

#### HTTP Authorization

By default, the HTTP transport layer provides no authentication to the server, but you can provide custom headers if you need authentication. For example, to use Bearer token authentication:

```ruby
http_transport = MCP::Client::HTTP.new(
  url: "https://api.example.com/mcp",
  headers: {
    "Authorization" => "Bearer my_token"
  }
)

client = MCP::Client.new(transport: http_transport)
client.tools # will make the call using Bearer auth
```

You can add any custom headers needed for your authentication scheme, or for any other purpose. The client will include these headers on every request.

#### OAuth 2.1 Authorization

When an MCP server enforces the [MCP Authorization spec](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization),
pass an `MCP::Client::OAuth::Provider` to the transport instead of a static `Authorization` header. The transport will:

- Send `Authorization: Bearer <access_token>` on every request when a token is available.
- On a `401 Unauthorized`, parse the `WWW-Authenticate` header, discover the authorization server (Protected Resource Metadata + RFC 8414 Authorization Server Metadata),
  perform Dynamic Client Registration if needed, run the OAuth 2.1 Authorization Code flow with PKCE (S256), and retry the failed request with the acquired token.
- Fall back to the legacy 2025-03-26 discovery when the server publishes no Protected Resource Metadata, matching the TypeScript and Python SDKs: the MCP server's origin acts
  as the authorization base URL, its metadata is fetched from `<origin>/.well-known/oauth-authorization-server` without the RFC 8414 issuer byte-match (which the legacy spec predates),
  and when even that is absent the spec's default endpoints `/authorize`, `/token`, and `/register` at the origin are used with PKCE S256 assumed.
- On subsequent 401s with a saved `refresh_token`, exchange it at the token endpoint before falling back to the full interactive flow (RFC 6749 Section 6).
- On a `403 Forbidden` whose `WWW-Authenticate` header carries `error="insufficient_scope"` (OAuth 2.0 step-up, RFC 6750 Section 3.1 and the MCP scope-selection-strategy),
  run a fresh authorization request for the union of the currently granted scope and the scope named in the challenge, then retry the failed request once.
  The refresh path is bypassed because refreshing would re-issue the same scope set the server just rejected. A `403` without that challenge is surfaced unchanged.
- Request the `offline_access` scope when `client_metadata[:grant_types]` includes `refresh_token` and the authorization server advertises `offline_access` in its metadata
  `scopes_supported` (SEP-2207). This is what lets the server issue the `refresh_token` used above. As an SDK-level safeguard, when the authorization server does not advertise
  `offline_access` the scope is also stripped from any other source (challenge, PRM, or provider-supplied scope) so a server that does not support it never receives it.

```ruby
require "mcp"

provider = MCP::Client::OAuth::Provider.new(
  client_metadata: {
    client_name: "My MCP App",
    redirect_uris: ["http://localhost:3030/callback"],
    grant_types: ["authorization_code", "refresh_token"],
    response_types: ["code"],
    token_endpoint_auth_method: "none",
  },
  redirect_uri: "http://localhost:3030/callback",
  redirect_handler: ->(authorization_url) {
    # Send the user to the authorization URL - typically `Launchy.open(authorization_url)`
    # or a manual `puts authorization_url` in CLI tools.
  },
  callback_handler: -> {
    # Capture the redirect (for example, by running a small HTTP listener on
    # `redirect_uri`) and return [code, state] from the query string.
  },
)

transport = MCP::Client::HTTP.new(
  url: "https://api.example.com/mcp",
  oauth: provider,
)
client = MCP::Client.new(transport: transport)
client.connect # `initialize` is sent here; if the server replies 401 the OAuth flow runs and the handshake is retried with the acquired token
client.tools
```

Required keyword arguments to `Provider.new`:

- `client_metadata`: Hash sent to the authorization server's Dynamic Client Registration endpoint. Must include `redirect_uris`, `grant_types`, `response_types`,
  `token_endpoint_auth_method`. `redirect_uri` (below) must appear in this list, otherwise the constructor raises `Provider::UnregisteredRedirectURIError`.
  When `application_type` is omitted, the SDK infers `"native"` or `"web"` from `redirect_uris` per SEP-837 before registering (loopback or custom-scheme URIs are native);
  an explicit value always wins.
- `redirect_uri`: String. Must use HTTPS or be a loopback URL (`localhost`, `127.0.0.0/8`, `::1`); other values raise `Provider::InsecureRedirectURIError`.
- `redirect_handler`: Callable invoked with the fully-built authorization `URI`. Typically opens the user's browser.
- `callback_handler`: Callable that returns `[code, state]` or `[code, state, iss]` after the user is redirected back to `redirect_uri`. Returning the 3-element form
  (with `iss` set to the RFC 9207 `iss` parameter from the redirect, or `nil` when absent) opts into SEP-2468 issuer validation: a present `iss` must match
  the authorization server's issuer, and a missing one is rejected when the server advertises `authorization_response_iss_parameter_supported`.

Optional keyword arguments:

- `scope`: Space-separated scopes to request when the server's `WWW-Authenticate` does not specify one.
- `storage`: Object responding to `tokens`, `save_tokens(t)`, `client_information`, `save_client_information(info)`. Defaults to `MCP::Client::OAuth::InMemoryStorage`,
  which keeps credentials in process memory only. Persisted `client_information` is stamped with an `"issuer"` member binding it to the authorization server that
  issued it (SEP-2352): when the server's authorization server changes, the SDK discards the stale registration and its tokens and re-registers automatically
  (portable CIMD `client_id`s are kept). Treat the hash as opaque and persist it as-is.
- `client_id_metadata_document_url`: URL where you publish a Client ID Metadata Document
  (`draft-ietf-oauth-client-id-metadata-document` and the MCP authorization specification).
  When the authorization server advertises `client_id_metadata_document_supported: true`,
  the SDK uses this URL as the OAuth `client_id` and skips Dynamic Client Registration.
  Spec-required: the URL MUST be `https://` with a non-root path and MUST NOT include a fragment,
  userinfo, or `.`/`..` segments. The SDK additionally rejects query strings (the draft only marks
  them SHOULD NOT include, but the SDK refuses to send any) for `client_id` stability.
  Any of these failures raise `Provider::InvalidClientIDMetadataDocumentURLError`. The CIMD document
  served at the URL is a separate JSON artifact from the `client_metadata` keyword above:
  the DCR `client_metadata` MUST NOT include `client_id`, while the CIMD document MUST include
  `client_id` set to the document URL, `client_name`, and `redirect_uris` covering `redirect_uri`.

To persist credentials across restarts, supply your own storage:

```ruby
class FileTokenStorage
  def initialize(path)
    @path = path
  end

  def tokens
    read["tokens"]
  end

  def save_tokens(value)
    write("tokens" => value)
  end

  def client_information
    read["client"]
  end

  def save_client_information(value)
    write("client" => value)
  end

  private

  def read
    File.exist?(@path) ? JSON.parse(File.read(@path)) : {}
  end

  def write(updates)
    File.write(@path, JSON.dump(read.merge(updates)))
  end
end

provider = MCP::Client::OAuth::Provider.new(
  # ... required keywords ...
  storage: FileTokenStorage.new(File.expand_path("~/.config/my-app/oauth.json")),
)
```

##### Client Credentials Grant

For a confidential machine-to-machine client (no user, no browser redirect), use `MCP::Client::OAuth::ClientCredentialsProvider` instead of `Provider`.
The transport discovers the authorization server the same way, then exchanges the OAuth 2.1 `client_credentials` grant (RFC 6749 Section 4.4) at
the token endpoint. There is no authorization request, PKCE, or `offline_access`, because the grant does not issue a refresh token.

```ruby
provider = MCP::Client::OAuth::ClientCredentialsProvider.new(
  client_id: "my-service",
  client_secret: ENV.fetch("MCP_CLIENT_SECRET"),
  # token_endpoint_auth_method: "client_secret_basic" (default) or "client_secret_post"
  # scope: "mcp:read mcp:write" (optional; used when the server does not advertise scopes)
)

transport = MCP::Client::HTTP.new(url: "https://api.example.com/mcp", oauth: provider)
```

Keyword arguments:

- `client_id`, `client_secret`: Required. The grant is for confidential clients, so a credential is mandatory.
- `token_endpoint_auth_method`: `"client_secret_basic"` (default) or `"client_secret_post"`. `"none"` is rejected with `ClientCredentialsProvider::InvalidCredentialsError`.
- `scope`, `storage`: Optional, same meaning as on `Provider`.

##### Communication Security

When `oauth:` is set, the MCP transport URL and every OAuth-facing URL (PRM, Authorization Server metadata, `authorization_endpoint`, `token_endpoint`, `registration_endpoint`,
`redirect_uri`) must use HTTPS or a loopback host. Non-loopback `http://` URLs are rejected at the SDK boundary so a bearer token is never sent over plain HTTP to a remote host.

The transport also snapshots the canonicalized origin, path, and query string of the MCP URL at `initialize` time and re-checks them on every outgoing request through
a Faraday middleware that runs after any user-supplied customizer. That means any URL swap raises `MCP::Client::HTTP::InsecureURLError` before the request reaches the adapter,
whether the swap was triggered by
`instance_variable_set(:@url, ...)`, by a Faraday customizer rewriting `url_prefix`, or by a custom middleware rewriting `env.url` (including just `env.url.query`) at request time,
and whether the new URL is `http://` *or* `https://` to a different host or tenant.

#### Customizing the Faraday Connection

You can pass a block to `MCP::Client::HTTP.new` to customize the underlying Faraday connection.
The block is called after the default middleware is configured, so you can add middleware or swap the HTTP adapter:

```ruby
http_transport = MCP::Client::HTTP.new(url: "https://api.example.com/mcp") do |faraday|
  faraday.use MyApp::Middleware::HttpRecorder
  faraday.adapter :typhoeus
end
```

### Tool Objects

The client provides a wrapper class for tools returned by the server:

- `MCP::Client::Tool` - Represents a single tool with its metadata

This class provides easy access to tool properties like name, description, input schema, and output schema.

### Multi-Round-Trip Results (Experimental, SEP-2322)

The MCP 2026-07-28 draft replaces in-flight server-to-client requests with Multi Round-Trip Requests: instead of issuing `sampling/createMessage`, `roots/list`,
or `elicitation/create` while a request is being processed, a server may answer with a result whose `resultType` is `"input_required"`, carrying an `inputRequests` map
and an opaque `requestState`; the client fulfills the requests and re-issues the original request with `inputResponses` and the echoed `requestState`.

The Ruby client recognizes such results and raises `MCP::Client::InputRequiredError` instead of returning them as if they were final. The error exposes `input_requests`, `request_state`,
and the raw `result`; automatic resumption is not implemented yet, so callers respond manually if they opt into the draft flow. `MCP::ResultType::COMPLETE` and `MCP::ResultType::INPUT_REQUIRED`
are provided for forward compatibility. Servers on stable protocol versions never send `resultType`, so existing behavior is unchanged.

## Conformance Testing

The `conformance/` directory contains a test server and runner that validate the SDK against the MCP specification using [`@modelcontextprotocol/conformance`](https://github.com/modelcontextprotocol/conformance).

See [conformance/README.md](conformance/README.md) for usage instructions.

## Documentation

- [SDK API documentation](https://rubydoc.info/gems/mcp)
- [Model Context Protocol documentation](https://modelcontextprotocol.io)
