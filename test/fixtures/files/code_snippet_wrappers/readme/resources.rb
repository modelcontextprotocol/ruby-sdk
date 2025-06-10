# frozen_string_literal: true

require "mcp"

b = binding
eval(File.read("code_snippet.rb"), b)
server = b.local_variable_get(:server)

puts server.handle_json({ jsonrpc: "2.0", id: "1", method: "resources/list" }.to_json)
