---
layout: default
title: Resources
nav_order: 6
---

# Resources

MCP spec includes [Resources](https://modelcontextprotocol.io/specification/latest/server/resources).

## Defining Resources

Like [tools](/server/tools/) and [prompts](/server/prompts/), resources can be defined in three ways.

### 1. As a class definition

Define a class that inherits from `MCP::Resource`, implementing `contents` to serve the resource body:

```ruby
class MyResource < MCP::Resource
  uri "https://example.com/my_resource"
  resource_name "my-resource"
  title "My Resource"
  description "Lorem ipsum dolor sit amet"
  mime_type "text/html"

  class << self
    def contents
      [MCP::Resource::TextContents.new(
        uri: uri,
        mime_type: mime_type,
        text: "Hello from example resource!"
      )]
    end
  end
end

server = MCP::Server.new(
  name: "my_server",
  resources: [MyResource],
)
```

`resources/read` requests are routed automatically: when the requested URI matches a registered
class-based resource, its `contents` method is called. `contents` may return an array of
`MCP::Resource::TextContents` / `MCP::Resource::BlobContents` objects (or plain hashes), or a single one.
Like tools, `contents` can opt in to a [`server_context:`](/server/server-context/) keyword argument to receive per-request context.

When class-based resources or resource templates are registered and a `resources/read` request
does not match any of them, the server responds with the standard JSON-RPC Invalid Params error
(`-32602`) carrying the requested URI in the error `data` member, per SEP-2164.

### 2. Using the `MCP::Resource.define` method

The block implements `contents`:

```ruby
resource = MCP::Resource.define(
  uri: "https://example.com/my_resource",
  name: "my-resource",
  mime_type: "text/html",
) do
  [MCP::Resource::TextContents.new(uri: uri, mime_type: mime_type, text: "Hello!")]
end
```

### 3. Using the `MCP::Server#define_resource` method

`MCP::Server#define_resource` registers the resource directly on a server instance:

```ruby
server = MCP::Server.new(name: "my_server")
server.define_resource(
  uri: "https://example.com/my_resource",
  name: "my-resource",
  mime_type: "text/html",
) do
  [MCP::Resource::TextContents.new(uri: "https://example.com/my_resource", mime_type: "text/html", text: "Hello!")]
end
```

Alternatively, resources can be registered as plain data objects with `MCP::Resource.new`,
in which case the server only lists them:

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

With plain data resources, the server must register a handler for the `resources/read` method to
retrieve a resource dynamically.

```ruby
server.resources_read_handler do |params|
  [{
    uri: params[:uri],
    mimeType: "text/plain",
    text: "Hello from example resource! URI: #{params[:uri]}"
  }]
end
```

otherwise `resources/read` requests will be a no-op. Note that a `resources_read_handler` fully replaces
the default `resources/read` handling, including the automatic routing to class-based resources described above.

To make the resource *list* depend on the request, register a `resources_list_handler`. The block returns the resource collection to serve,
so the visible resources can vary by the authenticated principal or the granted scope. The framework paginates the returned array
and stamps the same cache hints it applies to the constructor-provided resources, so the block returns only the array.
A block that declares `server_context:` receives it:

```ruby
server.resources_list_handler do |params, server_context:|
  server_context[:authenticated] ? real_resources : demo_resources
end
```

The block is invoked once per page, so it must return a stable ordering across the pages of one query; the cursor is a positional offset
into the returned collection. When no handler is set, the resources passed to `MCP::Server.new` are served unchanged.

For unknown URIs, raise `MCP::Server::ResourceNotFoundError` from the handler.
Per SEP-2164, the server then responds with the standard JSON-RPC Invalid Params error (`-32602`)
carrying the requested URI in the error `data` member:

```ruby
server.resources_read_handler do |params|
  resource = lookup(params[:uri])
  raise MCP::Server::ResourceNotFoundError.new(params[:uri], params) unless resource

  [{ uri: params[:uri], mimeType: resource.mime_type, text: resource.body }]
end
```

## Reading Binary Resources

For binary resources, respond with a base64-encoded `blob` field instead of `text`.
The `MCP::Resource::TextContents` and `MCP::Resource::BlobContents` classes build the two contents shapes defined by the spec:

```ruby
server.resources_read_handler do |params|
  case params[:uri]
  when "file:///logo.png"
    [
      MCP::Resource::BlobContents.new(
        uri: params[:uri],
        mime_type: "image/png",
        data: Base64.strict_encode64(File.binread("logo.png")),
      ).to_h,
    ]
  else
    [
      MCP::Resource::TextContents.new(
        uri: params[:uri],
        mime_type: "text/plain",
        text: "Hello from example resource!",
      ).to_h,
    ]
  end
end
```

## Resource Templates

Resource templates follow the same pattern. Class-based templates declare a `uri_template` and
receive the variables extracted from the requested URI as keyword arguments to `contents`:

```ruby
class UserProfileTemplate < MCP::ResourceTemplate
  uri_template "users://{user_id}/profile"
  resource_template_name "user-profile"
  title "User Profile"
  description "Profile data for a user"
  mime_type "application/json"

  class << self
    def contents(user_id:)
      [MCP::Resource::TextContents.new(
        uri: "users://#{user_id}/profile",
        mime_type: mime_type,
        text: { id: user_id }.to_json
      )]
    end
  end
end

server = MCP::Server.new(
  name: "my_server",
  resource_templates: [UserProfileTemplate],
)
```

A `resources/read` request for `users://42/profile` calls `UserProfileTemplate.contents(user_id: "42")`.
An exact match against a registered resource takes precedence over template matching.
`contents` can also opt in to a `server_context:` keyword argument.

URI template matching supports simple [RFC 6570](https://www.rfc-editor.org/rfc/rfc6570) level 1 `{variable}` expressions only:

- Operator expressions such as `{+path}`, `{#fragment}`, or `{?query}` are treated as literal text and never match an expanded URI.
- A variable matches one or more characters excluding `/`.
- Extracted values are not percent-decoded.

The `MCP::ResourceTemplate.define` and `MCP::Server#define_resource_template` methods are also available,
mirroring the resource variants:

```ruby
server.define_resource_template(
  uri_template: "users://{user_id}/profile",
  name: "user-profile",
  mime_type: "application/json",
) do |user_id:|
  [MCP::Resource::TextContents.new(
    uri: "users://#{user_id}/profile",
    mime_type: "application/json",
    text: { id: user_id }.to_json
  )]
end
```

Resource templates can also be registered as plain data objects with `MCP::ResourceTemplate.new`,
in which case reads must be served by a `resources_read_handler`:

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

Registered templates are listed through the `resources/templates/list` protocol method.
To serve reads for URIs that match a template, extract the variable parts of the URI in your `resources_read_handler`:

```ruby
resource_template = MCP::ResourceTemplate.new(
  uri_template: "file:///items/{item_id}",
  name: "item",
  mime_type: "application/json",
)

server = MCP::Server.new(name: "my_server", resource_templates: [resource_template])

server.resources_read_handler do |params|
  if (match = params[:uri].match(%r{\Afile:///items/(?<item_id>[^/]+)\z}))
    [{
      uri: params[:uri],
      mimeType: "application/json",
      text: { id: match[:item_id] }.to_json,
    }]
  else
    raise MCP::Server::ResourceNotFoundError.new(params[:uri], params)
  end
end
```

## Resource Subscriptions

Resource subscriptions allow clients to monitor specific resources for changes.
When a subscribed resource is updated, the server sends a notification to the client.

The SDK does not track subscription state internally.
Server developers register handlers and manage their own subscription state.
Three methods are provided:

- `Server#resources_subscribe_handler` - registers a handler for `resources/subscribe` requests
- `Server#resources_unsubscribe_handler` - registers a handler for `resources/unsubscribe` requests
- `ServerContext#notify_resources_updated` - sends a `notifications/resources/updated` notification to the subscribing client

```ruby
subscribed_uris = Set.new

server = MCP::Server.new(
  name: "my_server",
  resources: [my_resource],
  capabilities: { resources: { subscribe: true } },
)

server.resources_subscribe_handler do |params|
  subscribed_uris.add(params[:uri].to_s)
end

server.resources_unsubscribe_handler do |params|
  subscribed_uris.delete(params[:uri].to_s)
end

server.define_tool(name: "update_resource") do |server_context:, **args|
  if subscribed_uris.include?("test://my-resource")
    server_context.notify_resources_updated(uri: "test://my-resource")
  end
  MCP::Tool::Response.new([MCP::Content::Text.new("Resource updated").to_h])
end
```

The `resources/subscribe` and `resources/unsubscribe` responses are empty results. The one field the spec allows
alongside is `_meta`, so a handler that returns `{ _meta: { ... } }` has it passed through; any other field it
returns is dropped. To convey a subscription identifier or other advisory data to the client, nest it under `_meta`
rather than returning it at the top level, which interoperating clients reject:

```ruby
server.resources_subscribe_handler do |params|
  id = subscriptions.create(params[:uri].to_s)
  { _meta: { "myapp.example/subscriptionId" => id } }
end
```
