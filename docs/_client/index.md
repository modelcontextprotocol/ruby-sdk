---
layout: default
title: Overview
nav_order: 1
permalink: /client/
redirect_from:
  - /building-clients.html
  - /building-clients/
---

# Building an MCP Client

The `MCP::Client` class provides an interface for interacting with MCP servers.

This class supports:

- Lifecycle negotiation and connection via `MCP::Client#connect`, adopting the modern lifecycle
  when the server serves it; see [Lifecycle](/client/lifecycle/)
- Server discovery via the `server/discover` method (`MCP::Client#discover`); see [Explicit Discovery](/client/lifecycle/#explicit-discovery)
- Liveness check via the `ping` method (`MCP::Client#ping`)
- Tool listing via the `tools/list` method (`MCP::Client#tools`)
- Tool invocation via the `tools/call` method (`MCP::Client#call_tool`)
- Resource listing via the `resources/list` method (`MCP::Client#resources`)
- Resource template listing via the `resources/templates/list` method (`MCP::Client#resource_templates`)
- Resource reading via the `resources/read` method (`MCP::Client#read_resource`)
- Prompt listing via the `prompts/list` method (`MCP::Client#prompts`)
- Prompt retrieval via the `prompts/get` method (`MCP::Client#get_prompt`)
- Completion requests via the `completion/complete` method (`MCP::Client#complete`); see [Completion](/server/completion/)
- Automatic driving of multi round-trip `input_required` results once `on_elicitation`, `on_sampling`,
  or `on_roots` handlers are registered; see [Multi Round-Trip Requests](/client/mrtr/)
- Cancellation of in-flight requests via the `cancellation:` keyword; see [Cancellation](/client/cancellation/)
- Cursor-based page iteration on the `list_*` methods and whole-collection fetching with
  the `max_pages` guard; see [Pagination](/client/pagination/)
- Automatic JSON-RPC 2.0 message formatting
- UUID request ID generation

Clients are initialized with a [transport layer](/client/transports/) instance that handles the low-level communication mechanics.
Authorization is handled by the transport layer; see [Authorization](/client/authorization/).

## Tool Objects

The client provides a wrapper class for tools returned by the server:

- `MCP::Client::Tool` - Represents a single tool with its metadata

This class provides easy access to tool properties like name, description, input schema, and output schema.
