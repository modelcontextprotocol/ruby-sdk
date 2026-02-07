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

### Supported Methods

- `initialize` - Initializes the protocol and returns server capabilities
- `ping` - Simple health check
- `tools/list` - Lists all registered tools and their schemas
- `tools/call` - Invokes a specific tool with provided arguments
- `prompts/list` - Lists all registered prompts and their schemas
- `prompts/get` - Retrieves a specific prompt by name
- `resources/list` - Lists all registered resources and their schemas
- `resources/read` - Retrieves a specific resource by name
- `resources/templates/list` - Lists all registered resource templates and their schemas

### Custom Methods

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

### Notifications

The server supports sending notifications to clients when lists of tools, prompts, or resources change. This enables real-time updates without polling.

#### Notification Methods

The server provides three notification methods:

- `notify_tools_list_changed` - Send a notification when the tools list changes
- `notify_prompts_list_changed` - Send a notification when the prompts list changes
- `notify_resources_list_changed` - Send a notification when the resources list changes
- `notify_log_message` - Send a structured logging notification message

#### Notification Format

Notifications follow the JSON-RPC 2.0 specification and use these method names:

- `notifications/tools/list_changed`
- `notifications/prompts/list_changed`
- `notifications/resources/list_changed`
- `notifications/message`

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
server.transport = transport

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

server.transport = transport

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

### Unsupported Features (to be implemented in future versions)

- Resource subscriptions
- Completions
- Elicitation

### Usage

#### Rails Controller

When added to a Rails controller on a route that handles POST requests, your server will be compliant with non-streaming
[Streamable HTTP](https://modelcontextprotocol.io/specification/latest/basic/transports#streamable-http) transport
requests.

You can use the `Server#handle_json` method to handle requests.

```ruby
class ApplicationController < ActionController::Base
  def index
    server = MCP::Server.new(
      name: "my_server",
      title: "Example Server Display Name",
      version: "1.0.0",
      instructions: "Use the tools of this server as a last resort",
      tools: [SomeTool, AnotherTool],
      prompts: [MyPrompt],
      server_context: { user_id: current_user.id },
    )
    render(json: server.handle_json(request.body.read))
  end
end
```

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

You can run this script and then type in requests to the server at the command line.

```console
$ ruby examples/stdio_server.rb
{"jsonrpc":"2.0","id":"1","method":"ping"}
{"jsonrpc":"2.0","id":"2","method":"tools/list"}
{"jsonrpc":"2.0","id":"3","method":"tools/call","params":{"name":"example_tool","arguments":{"message":"Hello"}}}
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

  config.instrumentation_callback = ->(data) {
    puts "Got instrumentation data #{data.inspect}"
  }
end
```

or by creating an explicit configuration and passing it into the server.
This is useful for systems where an application hosts more than one MCP server but
they might require different instrumentation callbacks.

```ruby
configuration = MCP::Configuration.new
configuration.exception_reporter = ->(exception, server_context) {
  # Your exception reporting logic here
  # For example with Bugsnag:
  Bugsnag.notify(exception) do |report|
    report.add_metadata(:model_context_protocol, server_context)
  end
}

configuration.instrumentation_callback = ->(data) {
  puts "Got instrumentation data #{data.inspect}"
}

server = MCP::Server.new(
  # ... all other options
  configuration:,
)
```

### Server Context and Configuration Block Data

#### `server_context`

The `server_context` is a user-defined hash that is passed into the server instance and made available to tools, prompts, and exception/instrumentation callbacks. It can be used to provide contextual information such as authentication state, user IDs, or request-specific data.

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

This hash is then passed as the `server_context` argument to tool and prompt calls, and is included in exception and instrumentation callbacks.

#### Configuration Block Data

##### Exception Reporter

The exception reporter receives:

- `exception`: The Ruby exception object that was raised
- `server_context`: The context hash provided to the server

**Signature:**

```ruby
exception_reporter = ->(exception, server_context) { ... }
```

##### Instrumentation Callback

The instrumentation callback receives a hash with the following possible keys:

- `method`: (String) The protocol method called (e.g., "ping", "tools/list")
- `tool_name`: (String, optional) The name of the tool called
- `tool_arguments`: (Hash, optional) The arguments passed to the tool
- `prompt_name`: (String, optional) The name of the prompt called
- `resource_uri`: (String, optional) The URI of the resource called
- `error`: (String, optional) Error code if a lookup failed
- `duration`: (Float) Duration of the call in seconds
- `client`: (Hash, optional) Client information with `name` and `version` keys, from the initialize request

> [!NOTE]
> `tool_name`, `prompt_name` and `resource_uri` are only populated if a matching handler is registered.
> This is to avoid potential issues with metric cardinality.

**Type:**

```ruby
instrumentation_callback = ->(data) { ... }
# where data is a Hash with keys as described above
```

**Example:**

```ruby
MCP.configure do |config|
  config.instrumentation_callback = ->(data) {
    puts "Instrumentation: #{data.inspect}"
  }
end
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

The server_context hash includes:

- For tool calls: `{ tool_name: "name", arguments: { ... } }`
- For general request handling: `{ request: { ... } }`

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

Please note: in this case, you must provide `type: "array"`. The default type
for output schemas is `object`.

MCP spec for the [Output Schema](https://modelcontextprotocol.io/specification/latest/server/tools#output-schema) specifies that:

- **Server Validation**: Servers MUST provide structured results that conform to the output schema
- **Client Validation**: Clients SHOULD validate structured results against the output schema
- **Better Integration**: Enables strict schema validation, type information, and improved developer experience
- **Backward Compatibility**: Tools returning structured content SHOULD also include serialized JSON in a TextContent block

The output schema follows standard JSON Schema format and helps ensure consistent data exchange between MCP servers and clients.

### Tool Responses with Structured Content

Tools can return structured data alongside text content using the `structured_content` parameter.

The structured content will be included in the JSON-RPC response as the `structuredContent` field.

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

The `MCP::Resource` class provides a way to register resources with the server.

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

The server must register a handler for the `resources/read` method to retrieve a resource dynamically.

```ruby
server.resources_read_handler do |params|
  [{
    uri: params[:uri],
    mimeType: "text/plain",
    text: "Hello from example resource! URI: #{params[:uri]}"
  }]
end
```

otherwise `resources/read` requests will be a no-op.

### Resource Templates

The `MCP::ResourceTemplate` class provides a way to register resource templates with the server.

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

## Building an MCP Client

The `MCP::Client` class provides an interface for interacting with MCP servers.

This class supports:

- Tool listing via the `tools/list` method (`MCP::Client#tools`)
- Tool invocation via the `tools/call` method (`MCP::Client#call_tools`)
- Resource listing via the `resources/list` method (`MCP::Client#resources`)
- Resource template listing via the `resources/templates/list` method (`MCP::Client#resource_templates`)
- Resource reading via the `resources/read` method (`MCP::Client#read_resources`)
- Prompt listing via the `prompts/list` method (`MCP::Client#prompts`)
- Prompt retrieval via the `prompts/get` method (`MCP::Client#get_prompt`)
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

### HTTP Transport Layer

Use the `MCP::Client::HTTP` transport to interact with MCP servers using simple HTTP requests.

You'll need to add `faraday` as a dependency in order to use the HTTP transport layer:

```ruby
gem 'mcp'
gem 'faraday', '>= 2.0'
```

Example usage:

```ruby
http_transport = MCP::Client::HTTP.new(url: "https://api.example.com/mcp")
client = MCP::Client.new(transport: http_transport)

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
```

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

### Tool Objects

The client provides a wrapper class for tools returned by the server:

- `MCP::Client::Tool` - Represents a single tool with its metadata

This class provides easy access to tool properties like name, description, input schema, and output schema.

## Documentation

- [SDK API documentation](https://rubydoc.info/gems/mcp)
- [Model Context Protocol documentation](https://modelcontextprotocol.io)
