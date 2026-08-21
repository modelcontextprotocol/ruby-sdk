---
layout: default
title: Examples
nav_order: 3
permalink: /examples/
---

# Examples

Runnable examples live in [`examples/`](https://github.com/modelcontextprotocol/ruby-sdk/tree/main/examples) in the repository.

## Standalone Scripts

- [`stdio_server.rb`](https://github.com/modelcontextprotocol/ruby-sdk/blob/main/examples/stdio_server.rb) - a stdio server for desktop applications and command-line tools
- [`stdio_client.rb`](https://github.com/modelcontextprotocol/ruby-sdk/blob/main/examples/stdio_client.rb) - a client that spawns the stdio server as a subprocess and exercises its tools, prompts, and resources
- [`http_server.rb`](https://github.com/modelcontextprotocol/ruby-sdk/blob/main/examples/http_server.rb) - a Rack-based Streamable HTTP server with session management and SSE support
- [`http_client.rb`](https://github.com/modelcontextprotocol/ruby-sdk/blob/main/examples/http_client.rb) - a client driving the HTTP server through all MCP protocol methods
- [`streamable_http_server.rb`](https://github.com/modelcontextprotocol/ruby-sdk/blob/main/examples/streamable_http_server.rb) - an SSE-focused server with tools that trigger notifications and progress updates
- [`streamable_http_client.rb`](https://github.com/modelcontextprotocol/ruby-sdk/blob/main/examples/streamable_http_client.rb) - an interactive, menu-driven client for testing the SSE stream

Each script is standalone and run from the repository root:

```console
$ ruby examples/stdio_server.rb
```

See [`examples/README.md`](https://github.com/modelcontextprotocol/ruby-sdk/blob/main/examples/README.md) for per-example usage and the requests each one demonstrates.

## Rails Application

[`examples/rails`](https://github.com/modelcontextprotocol/ruby-sdk/tree/main/examples/rails) is a complete, minimal
Rails application serving an MCP server over the Streamable HTTP transport. The server and transport are built once
at boot and mounted at `/mcp` in `config/routes.rb`; tools live in `app/tools/`, and a text resource is served through
a `resources_read_handler`.

```console
$ cd examples/rails
$ bundle install
$ bundle exec puma --port 9292
```

The MCP endpoint is then available at `http://localhost:9292/mcp`. See
[`examples/rails/README.md`](https://github.com/modelcontextprotocol/ruby-sdk/blob/main/examples/rails/README.md)
for a step-by-step cURL walkthrough of the session handshake and tool calls.

The mount pattern this application uses is explained in [Rails (mount)](/server/transports/#rails-mount)
on the Transports page, alongside [Rails (controller)](/server/transports/#rails-controller), an alternative
that builds a server per request so tools and configuration can vary by request.
