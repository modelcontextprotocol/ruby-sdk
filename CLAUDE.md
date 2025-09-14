# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

### Core Commands
- `bundle install` - Install dependencies
- `rake test` - Run all tests
- `rake rubocop` - Run linter
- `rake` - Run tests and linting (default task)

### Testing
- `ruby -I lib -I test test/path/to/specific_test.rb` - Run single test file
- Test files are located in `test/` directory with `_test.rb` suffix

### Gem Management
- `gem build mcp.gemspec` - Build the gem
- Releases are triggered by updating version in `lib/mcp/version.rb` and merging to main

## Architecture Overview

This is the official Ruby SDK for the Model Context Protocol (MCP), implementing both server and client functionality for JSON-RPC 2.0 based communication between LLM applications and context providers.

### Core Components

**MCP::Server** (`lib/mcp/server.rb`):
- Main server class handling JSON-RPC requests
- Implements MCP protocol methods: initialize, ping, tools/list, tools/call, prompts/list, prompts/get, resources/list, resources/read
- Supports custom method registration via `define_custom_method`
- Handles instrumentation, exception reporting, and notifications
- Uses JsonRpcHandler for request processing

**MCP::Client** (`lib/mcp/client.rb`):
- Client interface for communicating with MCP servers
- Transport-agnostic design with pluggable transport layers
- Supports tool listing and invocation

**Transport Layer**:
- `MCP::Server::Transports::StdioTransport` - Command-line stdio transport
- `MCP::Server::Transports::StreamableHttpTransport` - HTTP with streaming support
- `MCP::Client::HTTP` - HTTP client transport (requires faraday gem)

**Protocol Components**:
- `MCP::Tool` - Tool definition with input/output schemas and annotations
- `MCP::Prompt` - Prompt templates with argument validation
- `MCP::Resource` - Resource registration and retrieval
- `MCP::Configuration` - Global configuration with exception reporting and instrumentation

### Key Patterns

**Three Ways to Define Components**:
1. Class inheritance (e.g., `class MyTool < MCP::Tool`)
2. Define methods (e.g., `MCP::Tool.define(name: "my_tool") { ... }`)
3. Server registration (e.g., `server.define_tool(name: "my_tool") { ... }`)

**Schema Validation**:
- Tools support input_schema and output_schema for JSON Schema validation
- Protocol version 2025-03-26+ supports tool annotations (destructive_hint, idempotent_hint, etc.)
- Validation is configurable via `configuration.validate_tool_call_arguments`

**Context Passing**:
- `server_context` hash passed through tool/prompt calls for request-specific data
- Methods can accept `server_context:` keyword argument for accessing context

### Dependencies
- `json_rpc_handler` ~> 0.1 - JSON-RPC 2.0 message handling
- `json-schema` >= 4.1 - Schema validation
- Ruby 3.2.0+ required

### Example Integration Patterns
- Rails controllers: Use `server.handle_json(request.body.read)` for HTTP endpoints
- Command-line tools: Use `StdioTransport.new(server).open` for CLI applications
- HTTP services: Use `StreamableHttpTransport` for web-based servers