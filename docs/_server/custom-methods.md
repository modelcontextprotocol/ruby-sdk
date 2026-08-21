---
layout: default
title: Custom Methods
nav_order: 21
---

# Custom Methods

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
- Blocks may opt in to a [`server_context:`](/server/server-context/) keyword like the built-in handlers
  (see [Cancellation](/server/cancellation/) for an example)

**Usage Example:**

The wire exchange for the custom `add` method defined above. The client sends:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "add",
  "params": { "a": 5, "b": 3 }
}
```

The server responds:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": 8
}
```

**Error Handling:**

- Raises `MCP::Server::MethodAlreadyDefinedError` if trying to override an existing method
- Supports the same [exception reporting and instrumentation](/server/configuration/) as standard methods
