# frozen_string_literal: true

class GreetingTool < MCP::Tool
  title "Greeting Tool"
  description "Greets the given name and reports which app served the request"
  input_schema(
    properties: {
      name: { type: "string" },
    },
    required: ["name"],
  )
  annotations(
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false,
    read_only_hint: true,
  )

  class << self
    def call(name:, server_context:)
      MCP::Tool::Response.new([{
        type: "text",
        text: "Hello, #{name}! (served by #{server_context[:app_name]})",
      }])
    end
  end
end
