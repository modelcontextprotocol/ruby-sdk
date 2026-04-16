---
layout: default
title: Building Servers
nav_order: 3
---

# Building an MCP Server

The `MCP::Server` class is the core component that handles JSON-RPC requests and responses. It implements the Model Context Protocol specification.

## Supported Methods

- `initialize` - Initializes the protocol and returns server capabilities
- `ping` - Simple health check
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
- `sampling/createMessage` - Requests LLM completion from the client (server-to-client)

## Stdio Transport

If you want to build a local command-line application, you can use the stdio transport:

```ruby
require "mcp"

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

server = MCP::Server.new(
  name: "example_server",
  tools: [ExampleTool],
)

transport = MCP::Server::Transports::StdioTransport.new(server)
transport.open
```

## Streamable HTTP Transport

`MCP::Server::Transports::StreamableHTTPTransport` is a standard Rack app, so it can be mounted in any Rack-compatible framework.
The following examples show two common integration styles in Rails.

{: .important }
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
the [MCP Streamable HTTP transport spec](https://modelcontextprotocol.io/specification/latest/basic/transports#streamable-http),
so no additional route configuration is needed.

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
    transport = MCP::Server::Transports::StreamableHTTPTransport.new(server, stateless: true)
    status, headers, body = transport.handle_request(request)

    render(json: body.first, status: status, headers: headers)
  end
end
```

## Tools

Tools provide functionality to LLM applications. There are three ways to define tools:

### Class Definition

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
  annotations(
    read_only_hint: true,
    destructive_hint: false,
  )

  def self.call(message:, server_context:)
    MCP::Tool::Response.new([{ type: "text", text: "OK" }])
  end
end
```

### Block Definition

```ruby
tool = MCP::Tool.define(
  name: "my_tool",
  description: "This tool performs specific functionality...",
) do |args, server_context:|
  MCP::Tool::Response.new([{ type: "text", text: "OK" }])
end
```

### Server-level Definition

```ruby
server = MCP::Server.new
server.define_tool(
  name: "my_tool",
  description: "This tool performs specific functionality...",
) do |args, server_context:|
  MCP::Tool::Response.new([{ type: "text", text: "OK" }])
end
```

## Prompts

Prompts are templates for LLM interactions. Like tools, they can be defined in three ways:

### Class Definition

```ruby
class CodeReviewPrompt < MCP::Prompt
  prompt_name "code_review"
  description "Review code for best practices"
  arguments [
    MCP::Prompt::Argument.new(name: "code", description: "Code to review", required: true),
  ]

  class << self
    def template(args, server_context:)
      MCP::Prompt::Result.new(
        description: "Code review",
        messages: [
          MCP::Prompt::Message.new(
            role: "user",
            content: MCP::Content::Text.new("Please review this code:\n#{args[:code]}")
          ),
        ]
      )
    end
  end
end
```

### Server-level Definition

```ruby
server.define_prompt(
  name: "code_review",
  description: "Review code for best practices",
  arguments: [
    MCP::Prompt::Argument.new(name: "code", description: "Code to review", required: true),
  ]
) do |args, server_context:|
  MCP::Prompt::Result.new(
    description: "Code review",
    messages: [
      MCP::Prompt::Message.new(
        role: "user",
        content: MCP::Content::Text.new("Please review this code:\n#{args[:code]}")
      ),
    ]
  )
end
```

## Resources

Resources provide data access to LLM applications:

```ruby
class MyResource < MCP::Resource
  uri "file:///data/config.json"
  resource_name "config"
  description "Application configuration"
  mime_type "application/json"
end

server = MCP::Server.new(
  name: "my_server",
  resources: [MyResource],
  resources_read_handler: ->(uri, _server_context) {
    case uri
    when "file:///data/config.json"
      { uri: uri, text: File.read("config.json"), mimeType: "application/json" }
    end
  }
)
```

## Configuration

```ruby
MCP.configure do |config|
  config.exception_reporter = ->(exception, server_context) {
    Bugsnag.notify(exception) do |report|
      report.add_metadata(:model_context_protocol, server_context)
    end
  }

  config.instrumentation_callback = ->(data) {
    puts "Got instrumentation data #{data.inspect}"
  }
end
```

For more details on sampling, notifications, progress tracking, completions, logging, and advanced features, see the [full README](https://github.com/modelcontextprotocol/ruby-sdk/blob/main/README.md#building-an-mcp-server).
