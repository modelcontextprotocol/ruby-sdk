---
layout: default
title: Overview
nav_order: 1
permalink: /extensions/
---

# Extensions

Extensions add optional functionality on top of the core MCP protocol.
Support for an extension is negotiated per connection:
clients and servers declare the extensions they speak under the `extensions` member of their capabilities,
as described on [Capability Extensions](/extensions/capability-extensions/).

The extensions this SDK ships support for:

- [MCP Apps](/extensions/mcp-apps/) (SEP-1865) - interactive HTML user interfaces rendered by the host for tool results
