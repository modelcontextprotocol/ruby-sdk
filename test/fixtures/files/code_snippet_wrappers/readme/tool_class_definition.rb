# frozen_string_literal: true

require "mcp"

require_relative "code_snippet"

b = binding
eval(File.read("code_snippet.rb"), b)
tool = b.local_variable_get(:tool)

puts MCP::Server.new(tools: [tool]).handle_json(
  {
    jsonrpc: "2.0",
    id: "1",
    method: "tools/call",
    params: { name: "my_tool", arguments: { message: "Hello, world!" } },
  }.to_json,
)
