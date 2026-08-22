---
layout: default
title: Elicitation
nav_order: 9
---

# Elicitation

The MCP Ruby SDK supports [elicitation](https://modelcontextprotocol.io/specification/latest/client/elicitation),
which allows servers to request additional information from users through the client during tool execution.

Elicitation is a **server-to-client request**. The server sends a request and blocks until the user responds via the client.

{: .note }
> Unlike [roots](/server/roots/) and [sampling](/server/sampling/), elicitation carries no SEP-2577 deprecation
> and remains fully available. On the [modern lifecycle](/server/discover/#the-stateless-modern-lifecycle) (MCP 2026-07-28), which forbids server-initiated requests,
> an `elicitation/create` request is embedded in an `input_required` result instead;
> see [Multi Round-Trip Requests](/server/mrtr/).

{: .important }
> Per SEP-2260, server-to-client requests (`roots/list`, `sampling/createMessage`, `elicitation/create`) must be associated with
> an originating client request (`ping` is exempt). Use the `server_context` passed to your handler, which stamps the association
> automatically and routes the request onto the originating POST stream on the Streamable HTTP transport. Calling the corresponding
> `ServerSession` methods without `related_request_id:` still works but emits a deprecation warning.

## Capabilities

Clients must declare the `elicitation` capability during initialization. The server checks this before sending any elicitation request
and raises a `RuntimeError` if the client does not support it.

For URL mode support, the client must also declare `elicitation.url` capability.

## Using Elicitation in Tools

Tools that accept a [`server_context:`](/server/server-context/) parameter can call `create_form_elicitation` on it:

```ruby
server.define_tool(name: "collect_info", description: "Collect user info") do |server_context:|
  result = server_context.create_form_elicitation(
    message: "Please provide your name",
    requested_schema: {
      type: "object",
      properties: { name: { type: "string" } },
      required: ["name"],
    },
  )

  MCP::Tool::Response.new([{ type: "text", text: "Hello, #{result[:content][:name]}" }])
end
```

## Form Mode

Form mode collects structured data from the user directly through the MCP client:

```ruby
server.define_tool(name: "collect_contact", description: "Collect contact info") do |server_context:|
  result = server_context.create_form_elicitation(
    message: "Please provide your contact information",
    requested_schema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Your full name" },
        email: { type: "string", format: "email", description: "Your email address" },
      },
      required: ["name", "email"],
    },
  )

  text = case result[:action]
  when "accept"
    "Hello, #{result[:content][:name]} (#{result[:content][:email]})"
  when "decline"
    "User declined"
  when "cancel"
    "User cancelled"
  end

  MCP::Tool::Response.new([{ type: "text", text: text }])
end
```

The `requested_schema` must be a flat object schema: a top-level `type: "object"` whose `properties` are limited to
primitive types (`string`, `number`, `integer`, `boolean`). Nested objects and arrays are not allowed, which keeps
the schema simple enough for clients to render as a form. Per the MCP specification, the client validates
the user's input against this schema before returning it, so the `content` of an `accept` response matches the requested shape.

## Default Values and Enums

Properties may declare a `default` value (SEP-1034), which clients use to pre-fill the form.
String properties may declare `enum` values, optionally with human-readable `enumNames` (SEP-1330), which clients render as a choice list:

```ruby
server.define_tool(name: "configure_deploy", description: "Configure a deployment") do |server_context:|
  result = server_context.create_form_elicitation(
    message: "Configure the deployment",
    requested_schema: {
      type: "object",
      properties: {
        replicas: { type: "integer", default: 3 },
        verbose: { type: "boolean", default: false },
        environment: {
          type: "string",
          enum: ["dev", "staging", "prod"],
          enumNames: ["Development", "Staging", "Production"],
          default: "dev",
        },
      },
      required: ["environment"],
    },
  )

  MCP::Tool::Response.new([{ type: "text", text: "Deploying to #{result[:content][:environment]}" }])
end
```

## Enum Schemas

For enumerated choices, use `MCP::Elicitation::EnumSchema` to construct the canonical schema shapes per
[SEP-1330](https://github.com/modelcontextprotocol/modelcontextprotocol/issues/1330) instead of building
the underlying Hash by hand. The five class methods cover titled and untitled, single-select and multi-select,
plus the legacy `enumNames` form retained for backward compatibility:

```ruby
size_schema = MCP::Elicitation::EnumSchema.titled_single_select(
  options: [
    { value: "s", title: "Small" },
    { value: "m", title: "Medium" },
    { value: "l", title: "Large" },
  ],
  default: "m",
)

tags_schema = MCP::Elicitation::EnumSchema.untitled_multi_select(
  values: ["urgent", "billing", "feedback"],
)

result = server_context.create_form_elicitation(
  message: "Tell us about your order",
  requested_schema: {
    type: "object",
    properties: {
      size: size_schema.to_h,
      tags: tags_schema.to_h,
    },
    required: ["size"],
  },
)
```

The available builders are `untitled_single_select`, `titled_single_select`, `untitled_multi_select`, `titled_multi_select`,
and `legacy_titled`. Each accepts optional `default:`, `title:`, and `description:`.

The same builders produce the `requestedSchema` of an `elicitation/create` request embedded in a SEP-2322 `input_required` result,
which is how elicitation reaches clients on the stateless 2026-07-28 lifecycle:

```ruby
MCP::Server::InputRequiredResult.new(
  input_requests: {
    "size" => {
      method: "elicitation/create",
      params: {
        message: "Pick a size",
        requestedSchema: {
          type: "object",
          properties: { size: size_schema.to_h },
          required: ["size"],
        },
      },
    },
  },
)
```

## URL Mode

URL mode directs the user to an external URL for out-of-band interactions such as OAuth flows:

```ruby
server.define_tool(name: "authorize_github", description: "Authorize GitHub") do |server_context:|
  elicitation_id = SecureRandom.uuid

  result = server_context.create_url_elicitation(
    message: "Please authorize access to your GitHub account",
    url: "https://example.com/oauth/authorize?elicitation_id=#{elicitation_id}",
    elicitation_id: elicitation_id,
  )

  server_context.notify_elicitation_complete(elicitation_id: elicitation_id)

  MCP::Tool::Response.new([{ type: "text", text: "Authorization complete" }])
end
```

## URLElicitationRequiredError

When a tool cannot proceed until an out-of-band elicitation is completed, raise `MCP::Server::URLElicitationRequiredError`.
This returns a JSON-RPC error with code `-32042` to the client:

```ruby
server.define_tool(name: "access_github", description: "Access GitHub") do |server_context:|
  raise MCP::Server::URLElicitationRequiredError.new([
    {
      mode: "url",
      elicitationId: SecureRandom.uuid,
      url: "https://example.com/oauth/authorize",
      message: "GitHub authorization is required.",
    },
  ])
end
```

## Timeouts

Every server-to-client request is bounded, so a client that never answers cannot park the handler's thread indefinitely.
`MCP::Server::Transports::StreamableHTTPTransport` waits `server_to_client_request_timeout:` seconds (600 by default), then tells
the client the request was abandoned and raises `MCP::Server::RequestTimeoutError`. Individual calls override the deadline with `timeout:`,
which is the knob to reach for when a prompt legitimately waits on a person:

```ruby
server_context.create_form_elicitation(
  message: "Approve this deployment?",
  requested_schema: { type: "object", properties: { approved: { type: "boolean" } } },
  timeout: 3600, # This one waits up to an hour.
)
```

`StdioTransport` is not bounded and ignores `timeout:`: it owns the client process, so a client that stops answering
surfaces as end-of-file rather than as a wait that never ends.

The same timeout applies to [roots](/server/roots/) and [sampling](/server/sampling/) requests.
