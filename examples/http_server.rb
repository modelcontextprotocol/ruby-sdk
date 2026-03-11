# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "mcp"
require "rack/cors"
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
      uri: "https://test_resource.invalid",
      name: "test-resource",
      title: "Test Resource",
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
transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)
server.transport = transport

# Rack middleware for MCP-specific request/response logging.
class McpRequestLogger
  def initialize(app)
    @app = app
    @logger = Logger.new($stdout)
    @logger.formatter = proc { |_severity, _datetime, _progname, msg| "[MCP] #{msg}\n" }
  end

  def call(env)
    if env["REQUEST_METHOD"] == "POST"
      body = env["rack.input"].read
      env["rack.input"].rewind

      begin
        parsed = JSON.parse(body)

        @logger.info("Request: #{parsed["method"]} (id: #{parsed["id"]})")
        @logger.debug("Request body: #{JSON.pretty_generate(parsed)}")
      rescue JSON::ParserError
        @logger.warn("Request body (raw): #{body}")
      end
    end

    status, headers, response_body = @app.call(env)

    if response_body.is_a?(Array) && !response_body.empty? && response_body.first
      begin
        parsed = JSON.parse(response_body.first)

        if parsed["error"]
          @logger.error("Response error: #{parsed["error"]["message"]}")
        else
          @logger.info("Response: #{parsed["result"] ? "success" : "empty"} (id: #{parsed["id"]})")
        end
        @logger.debug("Response body: #{JSON.pretty_generate(parsed)}")
      rescue JSON::ParserError
        @logger.warn("Response body (raw): #{response_body}")
      end
    end

    [status, headers, response_body]
  end
end

# Build the Rack application with middleware.
# `StreamableHTTPTransport` responds to `call(env)`, so it can be used directly as a Rack app.
rack_app = Rack::Builder.new do
  # Enable CORS to allow browser-based MCP clients (e.g., MCP Inspector)
  # WARNING: origins("*") allows all origins. Restrict this in production.
  use(Rack::Cors) do
    allow do
      origins("*")
      resource(
        "*",
        headers: :any,
        methods: [:get, :post, :delete, :options],
        expose: ["Mcp-Session-Id"],
      )
    end
  end

  # Use CommonLogger for standard HTTP request logging
  use(Rack::CommonLogger, Logger.new($stdout))
  use(Rack::ShowExceptions)
  use(McpRequestLogger)

  run(transport)
end

# Start the server
puts <<~MESSAGE
  Starting MCP HTTP server on http://localhost:9292
  Use POST requests to initialize and send JSON-RPC commands
  Example initialization:
    curl -i http://localhost:9292 --json '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'

  The server will return a session ID in the Mcp-Session-Id header.
  Use this session ID for subsequent requests.

  Press Ctrl+C to stop the server
MESSAGE

# Run the server
# Use Rackup to run the server
Rackup::Handler.get("puma").run(rack_app, Port: 9292, Host: "localhost")
