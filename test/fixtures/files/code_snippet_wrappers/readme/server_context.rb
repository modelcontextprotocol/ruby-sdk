# frozen_string_literal: true

require "mcp"

current_user = Object.new
def current_user.id = 123

request = Object.new
def request.uuid = "...uuid..."

b = binding
eval(File.read("code_snippet.rb"), b)
server = b.local_variable_get(:server)

puts server.server_context.to_json
