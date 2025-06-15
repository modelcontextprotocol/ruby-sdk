# frozen_string_literal: true

require "mcp"

server = MCP::Server.new

b = binding
eval(File.read("code_snippet.rb"), b)

puts server.handle_json({
  jsonrpc: "2.0",
  id: "1",
  method: "resources/read",
  params: { uri: "https://example.com/test_resource" },
}.to_json)
