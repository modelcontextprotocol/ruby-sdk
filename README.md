# MCP Ruby SDK [![Gem Version](https://img.shields.io/gem/v/mcp)](https://rubygems.org/gems/mcp) [![Apache 2.0 licensed](https://img.shields.io/badge/license-Apache%202.0-blue)](https://github.com/modelcontextprotocol/ruby-sdk/blob/main/LICENSE) [![CI](https://github.com/modelcontextprotocol/ruby-sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/modelcontextprotocol/ruby-sdk/actions/workflows/ci.yml)

The official Ruby SDK for Model Context Protocol servers and clients.

Detailed guides are available at https://ruby.sdk.modelcontextprotocol.io.

## Features

- Build [MCP servers](https://ruby.sdk.modelcontextprotocol.io/server/) that expose tools, prompts, and resources to any MCP host
- Build [MCP clients](https://ruby.sdk.modelcontextprotocol.io/client/) that connect to any MCP server, with automatic lifecycle negotiation and OAuth 2.1 authorization
- Speak every standard transport: stdio and Streamable HTTP (including SSE), with a Rails integration
- Cover the full protocol surface: server-to-client requests, multi round-trip results, notifications, progress, logging, cancellation, completions, and pagination

## Installation

Add this line to your application's Gemfile:

```ruby
gem "mcp"
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
see [Server Transports](https://ruby.sdk.modelcontextprotocol.io/server/transports/).

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
see [Client Transports](https://ruby.sdk.modelcontextprotocol.io/client/transports/).

## Examples

Runnable examples are available in [`examples/`](https://github.com/modelcontextprotocol/ruby-sdk/tree/main/examples),
including a complete Rails application in [`examples/rails`](https://github.com/modelcontextprotocol/ruby-sdk/tree/main/examples/rails).

## Documentation

- [SDK guides](https://ruby.sdk.modelcontextprotocol.io)
- [SDK API documentation](https://rubydoc.info/gems/mcp)
- [Model Context Protocol documentation](https://modelcontextprotocol.io)

## License

This project is licensed under the Apache License 2.0 for new contributions, with existing code under MIT. See the [LICENSE](https://github.com/modelcontextprotocol/ruby-sdk/blob/main/LICENSE) file for details.
