# frozen_string_literal: true

require "mcp"

MCP.configure do |config|
  eval(File.read("code_snippet.rb"), binding)

  config.instrumentation_callback.call({ example: "data" })
end
