# frozen_string_literal: true

require "json"
require "stringio"

# For simplicity, we'll stub out the relevant parts of the Rails API.
module ActionController
  class Base
    class Request
      attr_reader :body

      def initialize(body)
        @body = StringIO.new(body)
      end
    end

    class User
      attr_reader :id

      def initialize(id:)
        @id = id
      end
    end

    attr_reader :request

    def initialize(request_body)
      @request = Request.new(request_body)
    end

    def render(json:) = json

    private

    def current_user = User.new(id: 1)
  end
end

# We need to create the minimal surrounding resources to run the code snippet
require "mcp"

SomeTool    = MCP::Tool.define(name: "some_tool")    { MCP::Tool::Response.new(content: "some_tool response") }
AnotherTool = MCP::Tool.define(name: "another_tool") { MCP::Tool::Response.new(content: "another_tool response") }
MyPrompt    = MCP::Prompt.define(name: "my_prompt")  { MCP::Prompt::Result.new }

require_relative "code_snippet"

puts ApplicationController.new(
  { jsonrpc: "2.0", id: "1", method: "ping" }.to_json,
).index
