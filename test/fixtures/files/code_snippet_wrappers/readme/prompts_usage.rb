# frozen_string_literal: true

require "mcp"

MyPrompt = MCP::Prompt.define(
  name: "my_prompt",
  description: "Test prompt",
  arguments: [
    MCP::Prompt::Argument.new(
      name: "message",
      description: "Input message",
      required: true,
    ),
  ],
) do |_args, server_context:|
  MCP::Prompt::Result.new(
    description: "Response with user context",
    messages: [
      MCP::Prompt::Message.new(
        role: "user",
        content: MCP::Content::Text.new("User ID: #{server_context[:user_id]}"),
      ),
    ],
  )
end

current_user = Object.new
def current_user.id = 123

b = binding
eval(File.read("code_snippet.rb"), b)
server = b.local_variable_get(:server)

puts server.handle_json({
  jsonrpc: "2.0",
  id: "1",
  method: "prompts/get",
  params: { name: "my_prompt", arguments: { message: "Test message" } },
}.to_json)
