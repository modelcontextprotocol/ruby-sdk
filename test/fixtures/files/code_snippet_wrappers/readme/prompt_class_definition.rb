# frozen_string_literal: true

require "mcp"

require_relative "code_snippet"

b = binding
eval(File.read("code_snippet.rb"), b)
prompt = b.local_variable_get(:prompt)

server = MCP::Server.new(prompts: [prompt])

[
  { jsonrpc: "2.0", id: "1", method: "prompts/list" },
  { jsonrpc: "2.0", id: "2", method: "prompts/get", params: { name: "my_prompt", arguments: { message: "Test message" } } },
].each { |request| puts server.handle_json(request.to_json) }
