# Model Context Protocol

A Ruby gem for implementing Model Context Protocol servers and clients.

## MCP Server

The `ModelContextProtocol::Server` class is the core component that handles JSON-RPC requests and responses.
It implements the Model Context Protocol specification, handling model context requests and responses.

### Supported Methods

- `initialize` - Initializes the protocol and returns server capabilities
- `ping` - Simple health check that returns "pong"
- `tools/list` - Lists all registered tools and their schemas
- `tools/call` - Invokes a specific tool with provided arguments
- `prompts/list` - Lists all registered prompts and their schemas
- `prompts/get` - Retrieves a specific prompt by name

### Usage

#### Rails Controller
Implement an `ApplicationController` which calls the `Server#handle_json` method, eg

```ruby
module ModelContextProtocol
  class ApplicationController < ActionController::Base

    def index
      server = ModelContextProtocol::Server.new(
        name: "my_server",
        tools: [SomeTool, AnotherTool],
        prompts: [MyPrompt],
        context: { user_id: current_user.id },
      )
      render(json: server.handle_json(request.body.read).to_h)
    end
  end
end
```

#### Stdio Transport

If you want to build a simple command-line application, you can use the stdio transport:

```ruby
#!/usr/bin/env ruby
require "model_context_protocol"
require "model_context_protocol/transports/stdio"

# Set up the server
server = ModelContextProtocol::Server.new(name: "example_server")

server.tool(
  name: "example_tool",
  description: "A simple example tool that echoes back its arguments",
  input_schema: {
    type: "object",
    properties: {
      message: { type: "string" },
    },
    required: ["message"]
  }
) do |args, context|
  ModelContextProtocol::Tool::Response.new([{
    type: "text",
    text: "Hello from example tool! Message: #{args["message"]}"
  }])
end

# Create and start the transport
transport = ModelContextProtocol::Transports::StdioTransport.new(server)
transport.open
```

You can then interact with the server at the command line.

```
$ ./stdio_server.rb
{"jsonrpc": "2.0", "id": 123, "method": "ping"}
{"jsonrpc":"2.0","id":123,"result":{}}
```

## Configuration

The gem can be configured using the `ModelContextProtocol.configure` block:

```ruby
ModelContextProtocol.configure do |config|
  config.exception_reporter = do |exception, context|
    # Your exception reporting logic here
    # For example with Bugsnag:
    Bugsnag.notify(exception) do |report|
      report.add_metadata(:model_context_protocol, context)
    end
  end

  config.instrumentation_callback = do |data|
    puts "Got instrumentation data #{data.inspect}"
  end
end
```

Or by creating an explicit configuration and passing it into the server.


```ruby
configuration = ModelContextProtocol::Configuration.new
configuration.exception_reporter = do |exception, context|
  # Your exception reporting logic here
  # For example with Bugsnag:
  Bugsnag.notify(exception) do |report|
    report.add_metadata(:model_context_protocol, context)
  end
end

configuration.instrumentation_callback = do |data|
  puts "Got instrumentation data #{data.inspect}"
end

server = ModelContextProtocol::Server.new(
  # ... all other options
  configuration:,
)
```

This is useful for systems where an application hosts more than one MCP server but
they might require different instrumentation callbacks.

### Server Protocol Version

The server's protocol version can be overridden using the `protocol_version` class method:

```ruby
ModelContextProtocol::Server.protocol_version = "2024-11-05"
```

This will make all new server instances use the specified protocol version instead of the default version. The protocol version can be reset to the default by setting it to `nil`:

```ruby
ModelContextProtocol::Server.protocol_version = nil
```

Be sure to check the [MCP spec](https://spec.modelcontextprotocol.io/specification/2024-11-05/) for the protocol version to understand the supported features for the version being set.

### Exception Reporting

The exception reporter receives two arguments:

- `exception`: The Ruby exception object that was raised
- `context`: A hash containing contextual information about where the error occurred

The context hash includes:

- For tool calls: `{ tool_name: "name", arguments: { ... } }`
- For general request handling: `{ request: { ... } }`

When an exception occurs:

1. The exception is reported via the configured reporter
2. For tool calls, a generic error response is returned to the client: `{ error: "Internal error occurred", isError: true }`
3. For other requests, the exception is re-raised after reporting

If no exception reporter is configured, a default no-op reporter is used that silently ignores exceptions.

## Tools

MCP spec includes [Tools](https://modelcontextprotocol.io/docs/concepts/tools) which provide functionality to LLM apps.

This gem provides a `ModelContextProtocol::Tool` class that can be used to create tools in two ways:

1. As a class definition:

```ruby
class MyTool < ModelContextProtocol::Tool
  description "This tool performs specific functionality..."
  input_schema [{ type: "text", text: "message" }]
  annotations(
    title: "My Tool",
    read_only_hint: true,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false
  )

  input_schema type: 'object',
    properties: {
      message: { type: 'string' },
    },
    required: ['message']

  def self.call(message:, context:)
    Tool::Response.new([{ type: "text", text: "OK" }])
  end
end

tool = MyTool
```

2. By using the `ModelContextProtocol::Tool.define` method with a block:

```ruby
tool = ModelContextProtocol::Tool.define(
  name: "my_tool",
  description: "This tool performs specific functionality...",
  annotations: {
    title: "My Tool",
    read_only_hint: true
  }
) do |args, context|
  Tool::Response.new([{ type: "text", text: "OK" }])
end
```

The context parameter is the context passed into the server and can be used to pass per request information,
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

The `ModelContextProtocol::Prompt` class provides two ways to create prompts:

1. As a class definition with metadata:

```ruby
class MyPrompt < ModelContextProtocol::Prompt
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
    def template(args, context:)
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

2. Using the `ModelContextProtocol::Prompt.define` method:

```ruby
prompt = ModelContextProtocol::Prompt.define(
  name: "my_prompt",
  description: "This prompt performs specific functionality...",
  arguments: [
    Prompt::Argument.new(
      name: "message",
      description: "Input message",
      required: true
    )
  ]
) do |args, context:|
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

The context parameter is the context passed into the server and can be used to pass per request information,
e.g. around authentication state or user preferences.

### Key Components

- `Prompt::Argument` - Defines input parameters for the prompt template
- `Prompt::Message` - Represents a message in the conversation with a role and content
- `Prompt::Result` - The output of a prompt template containing description and messages
- `Content::Text` - Text content for messages

### Usage

Register prompts with the MCP server:

```ruby
server = ModelContextProtocol::Server.new(
  name: "my_server",
  prompts: [MyPrompt],
  context: { user_id: current_user.id },
)
```

The server will handle prompt listing and execution through the MCP protocol methods:

- `prompts/list` - Lists all registered prompts and their schemas
- `prompts/get` - Retrieves and executes a specific prompt with arguments

### Instrumentation

The server allows registering a callback to receive information about instrumentation.
To register a handler pass a proc/lambda to as `instrumentation_callback` into the server constructor.

```ruby
ModelContextProtocol.configure do |config|
  config.instrumentation_callback = do |data|
    puts "Got instrumentation data #{data.inspect}"
  end
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
