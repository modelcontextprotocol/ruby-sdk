# MCP Ruby SDK ![Gem Version](https://img.shields.io/gem/v/mcp) ![MIT licensed](https://img.shields.io/badge/license-MIT-green) [![CI](https://github.com/modelcontextprotocol/ruby-sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/modelcontextprotocol/ruby-sdk/actions/workflows/ci.yml)

The official Ruby SDK for Model Context Protocol servers and clients.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'mcp'
```

And then execute:

```bash
$ bundle install
```

Or install it yourself as:

```bash
$ gem install mcp
```

## MCP Server

The `MCP::Server` class is the core component that handles JSON-RPC requests and responses.
It implements the Model Context Protocol specification, handling model context requests and responses.

### Key Features
- Implements JSON-RPC 2.0 message handling
- Supports protocol initialization and capability negotiation
- Manages tool registration and invocation
- Supports prompt registration and execution
- Supports resource registration and retrieval

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

### Unsupported Features ( to be implemented in future versions )

- Notifications
- Log Level
- Resource subscriptions
- Completions
- Complete StreamableHTTP implementation with streaming responses

### Usage

#### Rails Controller

When added to a Rails controller on a route that handles POST requests, your server will be compliant with non-streaming
[StreamableHTTP](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports#streamable-http) transport
requests.

You can use the `Server#handle_json` method to handle requests.

```ruby
class ApplicationController < ActionController::Base

  def index
    server = MCP::Server.new(
      name: "my_server",
      version: "1.0.0",
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
#!/usr/bin/env ruby
require "mcp"
require "mcp/server/transports/stdio_transport"

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

```bash
$ ./examples/stdio_server.rb
{"jsonrpc":"2.0","id":"1","method":"ping"}
{"jsonrpc":"2.0","id":"2","method":"tools/list"}
```

## Configuration

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
- `prompt_name`: (String, optional) The name of the prompt called
- `resource_uri`: (String, optional) The URI of the resource called
- `error`: (String, optional) Error code if a lookup failed
- `duration`: (Float) Duration of the call in seconds

**Type:**
```ruby
instrumentation_callback = ->(data) { ... }
# where data is a Hash with keys as described above
```

**Example:**
```ruby
config.instrumentation_callback = ->(data) {
  puts "Instrumentation: #{data.inspect}"
}
```

### Server Protocol Version

The server's protocol version can be overridden using the `protocol_version` class method:

```ruby
MCP::Server.protocol_version = "2024-11-05"
```

This will make all new server instances use the specified protocol version instead of the default version. The protocol version can be reset to the default by setting it to `nil`:

```ruby
MCP::Server.protocol_version = nil
```

Be sure to check the [MCP spec](https://spec.modelcontextprotocol.io/specification/2024-11-05/) for the protocol version to understand the supported features for the version being set.

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

## Tools

MCP spec includes [Tools](https://modelcontextprotocol.io/docs/concepts/tools) which provide functionality to LLM apps.

This gem provides a `MCP::Tool` class that can be used to create tools in two ways:

1. As a class definition:

```ruby
class MyTool < MCP::Tool
  description "This tool performs specific functionality..."
  input_schema(
    properties: {
      message: { type: "string" },
    },
    required: ["message"]
  )
  annotations(
    title: "My Tool",
    read_only_hint: true,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false
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
  description: "This tool performs specific functionality...",
  annotations: {
    title: "My Tool",
    read_only_hint: true
  }
) do |args, server_context|
  Tool::Response.new([{ type: "text", text: "OK" }])
end
```

The server_context parameter is the server_context passed into the server and can be used to pass per request information,
e.g. around authentication state.

### Tool Annotations

Tools can include annotations that provide additional metadata about their behavior. The following annotations are supported:

- `title`: A human-readable title for the tool
- `read_only_hint`: Indicates if the tool only reads data (doesn't modify state)
- `destructive_hint`: Indicates if the tool performs destructive operations
- `idempotent_hint`: Indicates if the tool's operations are idempotent
- `open_world_hint`: Indicates if the tool operates in an open world context

Annotations can be set either through the class definition using the `annotations` class method or when defining a tool using the `define` method.

## Prompts

MCP spec includes [Prompts](https://modelcontextprotocol.io/docs/concepts/prompts), which enable servers to define reusable prompt templates and workflows that clients can easily surface to users and LLMs.

The `MCP::Prompt` class provides two ways to create prompts:

1. As a class definition with metadata:

```ruby
class MyPrompt < MCP::Prompt
  prompt_name "my_prompt"  # Optional - defaults to underscored class name
  description "This prompt performs specific functionality..."
  arguments [
    Prompt::Argument.new(
      name: "message",
      description: "Input message",
      required: true
    )
  ]

  class << self
    def template(args, server_context:)
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
  end
end

prompt = MyPrompt
```

2. Using the `MCP::Prompt.define` method:

```ruby
prompt = MCP::Prompt.define(
  name: "my_prompt",
  description: "This prompt performs specific functionality...",
  arguments: [
    Prompt::Argument.new(
      name: "message",
      description: "Input message",
      required: true
    )
  ]
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

- `Prompt::Argument` - Defines input parameters for the prompt template
- `Prompt::Message` - Represents a message in the conversation with a role and content
- `Prompt::Result` - The output of a prompt template containing description and messages
- `Content::Text` - Text content for messages

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

### Instrumentation

The server allows registering a callback to receive information about instrumentation.
To register a handler pass a proc/lambda to as `instrumentation_callback` into the server constructor.

```ruby
MCP.configure do |config|
  config.instrumentation_callback = ->(data) {
    puts "Got instrumentation data #{data.inspect}"
  }
end
```

The data contains the following keys:
`method`: the metod called, e.g. `ping`, `tools/list`, `tools/call` etc
`tool_name`: the name of the tool called
`prompt_name`: the name of the prompt called
`resource_uri`: the uri of the resource called
`error`: if looking up tools/prompts etc failed, e.g. `tool_not_found`
`duration`: the duration of the call in seconds

`tool_name`, `prompt_name` and `resource_uri` are only populated if a matching handler is registered.
This is to avoid potential issues with metric cardinality

## Resources

MCP spec includes [Resources](https://modelcontextprotocol.io/docs/concepts/resources)

The `MCP::Resource` class provides a way to register resources with the server.

```ruby
resource = MCP::Resource.new(
  uri: "https://example.com/my_resource",
  name: "My Resource",
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
    text: params[:uri],
  }]
end

```

otherwise `resources/read` requests will be a no-op.

## Releases

This gem is published to [RubyGems.org](https://rubygems.org/gems/mcp)

Releases are triggered by PRs to the `main` branch updating the version number in `lib/mcp/version.rb`.

1. **Update the version number** in `lib/mcp/version.rb`, following [semver](https://semver.org/)
2. **Create A PR and get approval from a maintainer**
3. **Merge your PR to the main branch** - This will automatically trigger the release workflow via GitHub Actions

When changes are merged to the `main` branch, the GitHub Actions workflow (`.github/workflows/release.yml`) is triggered and the gem is published to RubyGems.
