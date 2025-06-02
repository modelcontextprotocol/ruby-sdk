#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "mcp"
require "mcp/transports/http"
require "rack"
require "rackup"
require "json"
require "logger"

# Create a simple tool
class ExampleTool < MCP::Tool
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

# Create a simple prompt
class ExamplePrompt < MCP::Prompt
  description "A simple example prompt that echoes back its arguments"
  arguments [
    MCP::Prompt::Argument.new(
      name: "message",
      description: "The message to echo back",
      required: true,
    ),
  ]

  class << self
    def template(args, server_context:)
      MCP::Prompt::Result.new(
        messages: [
          MCP::Prompt::Message.new(
            role: "user",
            content: MCP::Content::Text.new(args[:message]),
          ),
        ],
      )
    end
  end
end

# Set up the server
server = MCP::Server.new(
  name: "example_http_server",
  tools: [ExampleTool],
  prompts: [ExamplePrompt],
  resources: [
    MCP::Resource.new(
      uri: "test_resource",
      name: "Test resource",
      description: "Test resource that echoes back the uri as its content",
      mime_type: "text/plain",
    ),
  ],
)

server.define_tool(
  name: "echo",
  description: "A simple example tool that echoes back its arguments",
  input_schema: { properties: { message: { type: "string" } }, required: ["message"] },
) do |message:|
  MCP::Tool::Response.new(
    [
      {
        type: "text",
        text: "Hello from echo tool! Message: #{message}",
      },
    ],
  )
end

server.resources_read_handler do |params|
  [{
    uri: params[:uri],
    mimeType: "text/plain",
    text: "Hello from HTTP server resource!",
  }]
end

# Create the Streamable HTTP transport
transport = MCP::Transports::HTTP.new(server)
server.transport = transport

# Create a logger for MCP-specific logging
mcp_logger = Logger.new($stdout)
mcp_logger.formatter = proc do |_severity, _datetime, _progname, msg|
  "[MCP] #{msg}\n"
end

# Create a Rack application with logging
app = proc do |env|
  request = Rack::Request.new(env)

  # Log MCP-specific details for POST requests
  if request.post?
    body = request.body.read
    request.body.rewind
    begin
      parsed_body = JSON.parse(body)
      mcp_logger.info("Request: #{parsed_body["method"]} (id: #{parsed_body["id"]})")
      mcp_logger.debug("Request body: #{JSON.pretty_generate(parsed_body)}")
    rescue JSON::ParserError
      mcp_logger.warn("Request body (raw): #{body}")
    end
  end

  # Handle the request
  puts "request: #{request.inspect}"
  response = transport.handle_request(request)

  # Log the MCP response details
  _, _, body = response
  if body.is_a?(Array) && !body.empty?
    begin
      parsed_response = JSON.parse(body.first)
      if parsed_response["error"]
        mcp_logger.error("Response error: #{parsed_response["error"]["message"]}")
      else
        mcp_logger.info("Response: #{parsed_response["result"] ? "success" : "empty"} (id: #{parsed_response["id"]})")
      end
      mcp_logger.debug("Response body: #{JSON.pretty_generate(parsed_response)}")
    rescue JSON::ParserError
      mcp_logger.warn("Response body (raw): #{body}")
    end
  end

  response
end

# Wrap the app with Rack middleware
rack_app = Rack::Builder.new do
  # Use CommonLogger for standard HTTP request logging
  use(Rack::CommonLogger, Logger.new($stdout))

  # Add other useful middleware
  use(Rack::ShowExceptions)

  run(app)
end

# Start the server
puts "Starting MCP HTTP server on http://localhost:9292"
puts "Use POST requests to initialize and send JSON-RPC commands"
puts "Example initialization:"
puts '  curl -X POST http://localhost:9292 -H "Content-Type: application/json" -d \'{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}\''
puts ""
puts "The server will return a session ID in the Mcp-Session-Id header."
puts "Use this session ID for subsequent requests."
puts ""
puts "Press Ctrl+C to stop the server"

# Run the server
# Use Rackup to run the server
Rackup::Handler.get("puma").run(rack_app, Port: 9292, Host: "localhost")
