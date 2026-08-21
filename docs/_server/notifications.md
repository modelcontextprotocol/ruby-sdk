---
layout: default
title: Notifications
nav_order: 11
---

# Notifications

The server supports sending notifications to clients when lists of tools, prompts, or resources change. This enables real-time updates without polling.

## Notification Methods

The server provides the following notification methods:

- `notify_tools_list_changed` - Send a notification when the tools list changes
- `notify_prompts_list_changed` - Send a notification when the prompts list changes
- `notify_resources_list_changed` - Send a notification when the resources list changes
- `notify_log_message` - Send a structured logging notification message (see [Logging](/server/logging/))

## Session Scoping

When using Streamable HTTP transport with multiple clients, each client connection gets its own session. Notifications are scoped as follows:

- **`report_progress`** and **`notify_log_message`** called via [`server_context`](/server/server-context/) inside a tool handler are automatically sent only to the requesting client.
No extra configuration is needed.
- **`notify_tools_list_changed`**, **`notify_prompts_list_changed`**, and **`notify_resources_list_changed`** are always broadcast to all connected clients,
as they represent server-wide state changes. These should be called on the `server` instance directly.

On the [modern lifecycle](/server/discovery/#the-stateless-modern-lifecycle) (MCP 2026-07-28), clients receive these broadcasts through the `subscriptions/listen` stream;
see [Notification Subscriptions](/server/notification-subscriptions/).

## Notification Format

Notifications follow the JSON-RPC 2.0 specification and use these method names:

- `notifications/tools/list_changed`
- `notifications/prompts/list_changed`
- `notifications/resources/list_changed`
- `notifications/cancelled` (see [Cancellation](/server/cancellation/))
- `notifications/progress` (see [Progress](/server/progress/))
- `notifications/message` (see [Logging](/server/logging/))

## Broadcasting a List Change

Call the matching `notify_*` method after changing a server-wide list:

```ruby
server = MCP::Server.new(name: "my_server")

# Default Streamable HTTP - session oriented
transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)

# When tools change, notify clients
server.define_tool(name: "new_tool") { |**args| MCP::Tool::Response.new([{ type: "text", text: "ok" }]) }
server.notify_tools_list_changed

# When prompts change, notify clients
server.define_prompt(name: "new_prompt") do |args, server_context:|
  MCP::Prompt::Result.new(messages: [])
end
server.notify_prompts_list_changed

# When resources change, notify clients
server.define_resource(uri: "resource://new", name: "new_resource", mime_type: "text/plain") do
  [MCP::Resource::TextContents.new(uri: "resource://new", mime_type: "text/plain", text: "contents")]
end
server.notify_resources_list_changed
```
