---
layout: default
title: Configuration
nav_order: 20
---

# Configuration

The gem can be configured using the `MCP.configure` block:

```ruby
MCP.configure do |config|
  config.exception_reporter = ->(exception, server_context) {
    # Your exception reporting logic here
    # For example with Bugsnag:
    Bugsnag.notify(exception) do |report|
      report.add_metadata(:model_context_protocol, server_context)
    end
  }

  config.around_request = ->(data, &request_handler) {
    logger.info("Start: #{data[:method]}")
    request_handler.call
    logger.info("Done: #{data[:method]}, tool: #{data[:tool_name]}")
  }
end
```

or by creating an explicit configuration and passing it into the server.
This is useful for systems where an application hosts more than one MCP server but
they might require different configurations.

```ruby
configuration = MCP::Configuration.new
configuration.exception_reporter = ->(exception, server_context) {
  # Your exception reporting logic here
  # For example with Bugsnag:
  Bugsnag.notify(exception) do |report|
    report.add_metadata(:model_context_protocol, server_context)
  end
}

configuration.around_request = ->(data, &request_handler) {
  logger.info("Start: #{data[:method]}")
  request_handler.call
  logger.info("Done: #{data[:method]}, tool: #{data[:tool_name]}")
}

server = MCP::Server.new(
  # ... all other options
  configuration:,
)
```

## Exception Reporter

The exception reporter receives two arguments:

- `exception`: The Ruby exception object that was raised
- `server_context`: A hash containing contextual information about where the error occurred.
  This is not the user-defined [`server_context`](/server/server-context/) passed to `Server.new`.

The `server_context` hash includes:

- For request handling failures: `{ request: { ... } }` (the raw JSON-RPC request hash)
- For notification delivery failures: `{ notification: "tools_list_changed" }` (or the relevant notification name)

**Signature:**

```ruby
exception_reporter = ->(exception, server_context) { ... }
```

When an exception occurs:

1. The exception is reported via the configured reporter
2. The client receives a generic JSON-RPC error response (for example, "Internal error calling tool <name>"
   for a tool call); the exception's own message is deliberately withheld from clients

If no exception reporter is configured, a default no-op reporter is used that silently ignores exceptions.

## Around Request

The `around_request` hook wraps request handling, allowing you to execute code before and after each request.
This is useful for Application Performance Monitoring (APM) tracing, logging, or other observability needs.

The hook receives a `data` hash and a `request_handler` block. You must call `request_handler.call` to execute the request:

**Signature:**

```ruby
around_request = ->(data, &request_handler) { request_handler.call }
```

**`data` availability by timing:**

- Before `request_handler.call`: `method`, and `server_context` when `instrument_server_context` is enabled
- After `request_handler.call`: `tool_name`, `tool_arguments`, `prompt_name`, `resource_uri`, `error`, `client`
- Not available inside `around_request`: `duration` (added after `around_request` returns)

{: .note }
> `tool_name`, `prompt_name` and `resource_uri` may only be populated for the corresponding request methods
> (`tools/call`, `prompts/get`, `resources/read`), and may not be set depending on how the request is handled
> (for example, `prompt_name` is not recorded when the prompt is not found).
> `duration` is added after `around_request` returns, so it is not visible from within the hook.

**Example:**

```ruby
MCP.configure do |config|
  config.around_request = ->(data, &request_handler) {
    logger.info("Start: #{data[:method]}")
    request_handler.call
    logger.info("Done: #{data[:method]}, tool: #{data[:tool_name]}")
  }
end
```

### Exposing the User-Defined `server_context`

`data` omits the user-defined `server_context` by default, because that hash is
application-supplied and may hold values a tracing backend should not receive.
Enable it when you need to tag spans with the request's subject:

```ruby
MCP.configure do |config|
  config.instrument_server_context = true

  config.around_request = ->(data, &request_handler) {
    Sentry.set_user(id: data.dig(:server_context, :user_id))
    request_handler.call
  }
end
```

`data[:server_context]` is the hash passed to `Server.new` - `nil` when the host
set none. It is not the exception reporter's context argument, which describes
where a failure occurred rather than who made the request.

## Instrumentation Callback (soft-deprecated)

{: .note }
> `instrumentation_callback` is soft-deprecated. Use `around_request` instead.
>
> To migrate, wrap the call in `begin/ensure` so the callback still runs when the request fails:
>
> ```ruby
> # Before
> config.instrumentation_callback = ->(data) { log(data) }
>
> # After
> config.around_request = ->(data, &request_handler) do
>   request_handler.call
> ensure
>   log(data)
> end
> ```
>
> Note that `data[:duration]` is not available inside `around_request`.
> If you need it, measure elapsed time yourself within the hook, or keep using `instrumentation_callback`.

The instrumentation callback is called after each request finishes, whether successfully or with an error.
It receives a hash with the following possible keys:

- `method`: (String) The protocol method called (e.g., "ping", "tools/list")
- `tool_name`: (String, optional) The name of the tool called
- `tool_arguments`: (Hash, optional) The arguments passed to the tool
- `prompt_name`: (String, optional) The name of the prompt called
- `resource_uri`: (String, optional) The URI of the resource called
- `error`: (String, optional) Error code if a lookup failed
- `duration`: (Float) Duration of the call in seconds
- `client`: (Hash, optional) Client information with `name` and `version` keys, from the initialize request
- `server_context`: (Any, optional) The user-defined hash passed to `Server.new`, present only when
  `instrument_server_context` is enabled

**Signature:**

```ruby
instrumentation_callback = ->(data) { ... }
```

## Server Protocol Version

The server's protocol version can be overridden using the `protocol_version` keyword argument:

```ruby
configuration = MCP::Configuration.new(protocol_version: "2024-11-05")
MCP::Server.new(name: "test_server", configuration: configuration)
```

If no protocol version is specified, the latest handshake version (`2025-11-25`) is applied by default.

This will make all new server instances use the specified protocol version instead of the default version. The protocol version can be reset to the default by setting it to `nil`:

```ruby
MCP::Configuration.new(protocol_version: nil)
```

If an invalid `protocol_version` value is set, an `ArgumentError` is raised.

The pin scopes the `initialize` handshake, so it accepts handshake versions (`2025-11-25` and earlier) only. Per the SEP-2575 era model,
`2026-07-28` carries its version on every request and has no handshake at all, so there is nothing for a pin to configure there and setting it raises `ArgumentError`;
a client asking `initialize` for a modern version is counter-offered the pinned version (or the latest handshake version), matching the TypeScript and Python SDKs.
Clients reach `2026-07-28` through [`server/discover`](/server/discovery/) and the per-request `_meta` envelope, which the bundled transports serve alongside the handshake with no configuration needed.

Be sure to check the [MCP spec](https://modelcontextprotocol.io/specification/versioning) for the protocol version to understand the supported features for the version being set.
