---
layout: default
title: Introduction
nav_order: 1
---

The official Ruby SDK for the [Model Context Protocol](https://modelcontextprotocol.io/) (MCP), implementing both server and client functionality for JSON-RPC 2.0 based communication between LLM applications and context providers.

**Key features:**

- JSON-RPC 2.0 message handling with protocol initialization and capability negotiation
- Tool, prompt, and resource registration and invocation
- Stdio and Streamable HTTP (including SSE) transports
- Client support for communicating with MCP servers
- Notifications, sampling, progress tracking, and completions

## Quick Start

Here is a minimal MCP server using the stdio transport:

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

Run the script and send JSON-RPC requests via stdin:

```console
$ ruby server.rb
{"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"example","version":"0.1.0"}}}
{"jsonrpc":"2.0","id":"2","method":"tools/list"}
{"jsonrpc":"2.0","id":"3","method":"tools/call","params":{"name":"example_tool","arguments":{"message":"Hello"}}}
```

For comprehensive documentation, see the [full README](https://github.com/modelcontextprotocol/ruby-sdk/blob/main/README.md).

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

This project is transitioning from the MIT License to the Apache License 2.0. See [LICENSE](https://github.com/modelcontextprotocol/ruby-sdk/blob/main/LICENSE) for details.
