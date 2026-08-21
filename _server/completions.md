---
layout: default
title: Completions
nav_order: 16
---

# Completions

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
