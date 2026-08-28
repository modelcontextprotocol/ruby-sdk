---
layout: default
title: Introduction
nav_order: 1
---

# MCP Ruby SDK

The official Ruby SDK for the [Model Context Protocol](https://modelcontextprotocol.io/) (MCP), implementing both server and client functionality for JSON-RPC 2.0 based communication between LLM applications and context providers.

## Features

- Build [MCP servers](/server/) that expose tools, prompts, and resources to any MCP host
- Build [MCP clients](/client/) that connect to any MCP server, with automatic lifecycle negotiation and OAuth 2.1 authorization
- Speak every standard transport: stdio and Streamable HTTP (including SSE), with a Rails integration
- Cover the full protocol surface: server-to-client requests, multi round-trip requests, notifications, progress, logging, cancellation, completions, and pagination

## Quick Start

The following minimal programs show both sides of the protocol: a server that exposes a single tool,
and a client that spawns such a server and drives it over stdio.

### MCP Server

A minimal server defines a tool and serves it over the stdio transport:

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

Save the script as `server.rb`, run it, and send JSON-RPC requests via stdin:

```console
$ ruby server.rb
{"jsonrpc":"2.0","id":"1","method":"ping"}
{"jsonrpc":"2.0","id":"2","method":"tools/list"}
{"jsonrpc":"2.0","id":"3","method":"tools/call","params":{"name":"example_tool","arguments":{"message":"Hello"}}}
```

The same server can also run over Streamable HTTP, including mounted inside a Rails application;
see [Server Transports](/server/transports/).

### MCP Client

A minimal client spawns a stdio server as a subprocess, connects, and lists and calls its tools:

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

The same client can connect to Streamable HTTP servers with `MCP::Client::HTTP`;
see [Client Transports](/client/transports/).

For comprehensive documentation, see:

- [Installation](/installation/) - installing the gem and optional feature dependencies
- [Examples](/examples/) - runnable example scripts and a complete Rails application
- [Protocol Versions](/protocol-versions/) - supported versions, the era model, and client negotiation
- [Building Servers](server/) - transports, discovery, tools, prompts, resources, server-to-client requests, multi round-trip requests, notifications, protocol utilities, and configuration
- [Building Clients](client/) - transports, lifecycle negotiation, multi round-trip requests, and OAuth 2.1 authorization
- [Extensions](/extensions/) - capability extensions and MCP Apps

## API Documentation

Full API reference is hosted on [RubyDoc.info](https://rubydoc.info/gems/mcp). Select a version to view:

<select onchange="if(this.value) window.open(this.value, '_blank')">
  <option value="">Select version...</option>
  <option value="https://rubydoc.info/gems/mcp">Latest</option>
  {% for version in site.data.versions -%}
    <option value="https://rubydoc.info/gems/mcp/{{ version }}">v{{ version }}</option>
  {% endfor -%}
</select>

## License

This project is licensed under the Apache License 2.0 for new contributions, with existing code under MIT. See the [LICENSE](https://github.com/modelcontextprotocol/ruby-sdk/blob/main/LICENSE) file for details.
