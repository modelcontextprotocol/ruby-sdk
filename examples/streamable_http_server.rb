# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "mcp"
require "rack/cors"
require "rackup"
require "json"
require "logger"

# Create a logger for SSE-specific logging
sse_logger = Logger.new($stdout)
sse_logger.formatter = proc do |severity, datetime, _progname, msg|
  "[SSE] #{severity} #{datetime.strftime("%H:%M:%S.%L")} - #{msg}\n"
end

# Tool that returns a response that will be sent via SSE if a stream is active
class NotificationTool < MCP::Tool
  tool_name "notification_tool"
  description "Returns a notification message that will be sent via SSE if stream is active"
  input_schema(
    properties: {
      message: { type: "string", description: "Message to send via SSE" },
      delay: { type: "number", description: "Delay in seconds before returning (optional)" },
    },
    required: ["message"],
  )

  class << self
    attr_accessor :logger

    def call(message:, delay: 0)
      sleep(delay) if delay > 0

      logger.info("Returning notification message: #{message}")

      MCP::Tool::Response.new([{
        type: "text",
        text: "Notification: #{message} (timestamp: #{Time.now.iso8601})",
      }])
    end
  end
end

# Create the server
server = MCP::Server.new(
  name: "sse_test_server",
  tools: [NotificationTool],
  prompts: [],
  resources: [],
)

# Set logger for tools
NotificationTool.logger = sse_logger

# Add a simple echo tool for basic testing
server.define_tool(
  name: "echo",
  description: "Simple echo tool",
  input_schema: { properties: { message: { type: "string" } }, required: ["message"] },
) do |message:|
  MCP::Tool::Response.new([{ type: "text", text: "Echo: #{message}" }])
end

# Create the Streamable HTTP transport
transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)

# Rack middleware for MCP request/response and SSE logging.
class McpSseLogger
  def initialize(app)
    @app = app

    @mcp_logger = Logger.new($stdout)
    @mcp_logger.formatter = proc { |_severity, _datetime, _progname, msg| "[MCP] #{msg}\n" }

    @sse_logger = Logger.new($stdout)
    @sse_logger.formatter = proc { |severity, datetime, _progname, msg| "[SSE] #{severity} #{datetime.strftime("%H:%M:%S.%L")} - #{msg}\n" }
  end

  def call(env)
    if env["REQUEST_METHOD"] == "POST"
      body = env["rack.input"].read
      env["rack.input"].rewind

      begin
        parsed = JSON.parse(body)

        @mcp_logger.info("Request: #{parsed["method"]} (id: #{parsed["id"]})")
        @sse_logger.info("New client initializing session") if parsed["method"] == "initialize"
      rescue JSON::ParserError
        @mcp_logger.warn("Invalid JSON in request")
      end
    elsif env["REQUEST_METHOD"] == "GET"
      session_id = env["HTTP_MCP_SESSION_ID"] || Rack::Utils.parse_query(env["QUERY_STRING"])["sessionId"]

      @sse_logger.info("SSE connection request for session: #{session_id}")
    end

    status, headers, response_body = @app.call(env)

    if response_body.is_a?(Array) && !response_body.empty? && env["REQUEST_METHOD"] == "POST"
      begin
        parsed = JSON.parse(response_body.first)

        if parsed["error"]
          @mcp_logger.error("Response error: #{parsed["error"]["message"]}")
        else
          @mcp_logger.info("Response: success (id: #{parsed["id"]})")
          @sse_logger.info("Session created: #{headers["Mcp-Session-Id"]}") if headers["Mcp-Session-Id"]
        end
      rescue JSON::ParserError
        @mcp_logger.warn("Invalid JSON in response")
      end
    elsif env["REQUEST_METHOD"] == "GET" && status == 200
      @sse_logger.info("SSE stream established")
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

  use(Rack::CommonLogger, Logger.new($stdout))
  use(Rack::ShowExceptions)
  use(McpSseLogger)

  run(transport)
end

# Print usage instructions
puts <<~MESSAGE
  === MCP Streaming HTTP Test Server ===

  Starting server on http://localhost:9393

  Available Tools:
  1. NotificationTool - Returns messages that are sent via SSE when stream is active"
  2. echo - Simple echo tool

  Testing SSE:

  1. Initialize session:
     curl -i http://localhost:9393 \\
       --json '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"sse-test","version":"1.0"}}}'

  2. Connect SSE stream (use the session ID from step 1):"
     curl -i -N -H "Mcp-Session-Id: YOUR_SESSION_ID" http://localhost:9393

  3. In another terminal, test tools (responses will be sent via SSE if stream is active):

     Echo tool:
     curl -i http://localhost:9393 -H "Mcp-Session-Id: YOUR_SESSION_ID" \\
       --json '{"jsonrpc":"2.0","method":"tools/call","id":2,"params":{"name":"echo","arguments":{"message":"Hello SSE!"}}}'

     Notification tool (with 2 second delay):
     curl -i http://localhost:9393 -H "Mcp-Session-Id: YOUR_SESSION_ID" \\
       --json '{"jsonrpc":"2.0","method":"tools/call","id":3,"params":{"name":"notification_tool","arguments":{"message":"Hello SSE!", "delay": 2}}}'

  Note: When an SSE stream is active, tool responses will appear in the SSE stream and the POST request will return {"accepted": true}

  Press Ctrl+C to stop the server
MESSAGE

# Start the server
Rackup::Handler.get("puma").run(rack_app, Port: 9393, Host: "localhost")
