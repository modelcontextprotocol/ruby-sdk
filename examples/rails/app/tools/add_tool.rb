# frozen_string_literal: true

class AddTool < MCP::Tool
  title "Add Tool"
  description "A simple example tool that adds two numbers"
  input_schema(
    properties: {
      a: { type: "number" },
      b: { type: "number" },
    },
    required: ["a", "b"],
  )

  class << self
    def call(a:, b:)
      MCP::Tool::Response.new([{
        type: "text",
        text: "The sum of #{a} and #{b} is #{a + b}",
      }])
    end
  end
end
