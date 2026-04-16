---
layout: default
title: Building Clients
nav_order: 4
---

# Building an MCP Client

The `MCP::Client` class provides an interface for interacting with MCP servers.

**Supported operations:**

- Tool listing (`MCP::Client#tools`) and invocation (`MCP::Client#call_tool`)
- Resource listing (`MCP::Client#resources`) and reading (`MCP::Client#read_resources`)
- Resource template listing (`MCP::Client#resource_templates`)
- Prompt listing (`MCP::Client#prompts`) and retrieval (`MCP::Client#get_prompt`)
- Completion requests (`MCP::Client#complete`)

## Stdio Transport

Use `MCP::Client::Stdio` to interact with MCP servers running as subprocesses:

```ruby
stdio_transport = MCP::Client::Stdio.new(
  command: "bundle",
  args: ["exec", "ruby", "path/to/server.rb"],
  env: { "API_KEY" => "my_secret_key" },
  read_timeout: 30
)
client = MCP::Client.new(transport: stdio_transport)

tools = client.tools
tools.each do |tool|
  puts "Tool: #{tool.name} - #{tool.description}"
end

response = client.call_tool(
  tool: tools.first,
  arguments: { message: "Hello, world!" }
)

stdio_transport.close
```

| Parameter | Required | Description |
|---|---|---|
| `command:` | Yes | The command to spawn the server process. |
| `args:` | No | An array of arguments passed to the command. Defaults to `[]`. |
| `env:` | No | A hash of environment variables for the server process. Defaults to `nil`. |
| `read_timeout:` | No | Timeout in seconds for waiting for a server response. Defaults to `nil`. |

## HTTP Transport

Use `MCP::Client::HTTP` to interact with MCP servers over HTTP. Requires the `faraday` gem:

```ruby
gem 'mcp'
gem 'faraday', '>= 2.0'
```

```ruby
http_transport = MCP::Client::HTTP.new(url: "https://api.example.com/mcp")
client = MCP::Client.new(transport: http_transport)

tools = client.tools
tools.each do |tool|
  puts "Tool: #{tool.name} - #{tool.description}"
end

response = client.call_tool(
  tool: tools.first,
  arguments: { message: "Hello, world!" }
)
```

### Authorization

Provide custom headers for authentication:

```ruby
http_transport = MCP::Client::HTTP.new(
  url: "https://api.example.com/mcp",
  headers: {
    "Authorization" => "Bearer my_token"
  }
)
client = MCP::Client.new(transport: http_transport)
```

### Customizing the Faraday Connection

Pass a block to customize the underlying Faraday connection:

```ruby
http_transport = MCP::Client::HTTP.new(url: "https://api.example.com/mcp") do |faraday|
  faraday.use MyApp::Middleware::HttpRecorder
  faraday.adapter :typhoeus
end
```

## Custom Transport

If the built-in transports do not fit your needs, you can implement your own:

```ruby
class CustomTransport
  def send_request(request:)
    # Your transport-specific logic here.
    # Returns a Hash modeling a JSON-RPC response object.
  end
end

client = MCP::Client.new(transport: CustomTransport.new)
```

For more details, see the [full README](https://github.com/modelcontextprotocol/ruby-sdk/blob/main/README.md#building-an-mcp-client).
