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

# Tool that emits `notifications/progress` events, delivered over the SSE stream.
# The client must request them by sending a `progressToken` in the request `_meta`.
class NotificationTool < MCP::Tool
  tool_name "notification_tool"
  description "Sends the message back as progress notifications via SSE, then returns a summary"
  input_schema(
    properties: {
      message: { type: "string", description: "Message to send via SSE" },
      steps: { type: "number", description: "Number of progress notifications to send (default: 3)" },
      delay: { type: "number", description: "Delay in seconds between notifications (optional)" },
    },
    required: ["message"],
  )

  class << self
    attr_accessor :logger

    def call(message:, server_context:, steps: 3, delay: 0)
      steps = steps.to_i.clamp(1, 10)

      steps.times do |i|
        sleep(delay) if delay > 0

        logger&.info("Reporting progress #{i + 1}/#{steps}: #{message}")
        server_context.report_progress(i + 1, total: steps, message: message)
      end

      MCP::Tool::Response.new([{
        type: "text",
        text: "Sent #{steps} progress notifications for: #{message}",
      }])
    end
  end
end

# Create the server
server = MCP::Server.new(
  name: "sse_test_server",
  version: "1.0.0",
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
          @sse_logger.info("Session created: #{headers["mcp-session-id"]}") if headers["mcp-session-id"]
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
  1. notification_tool - Sends the message back as progress notifications via SSE
  2. echo - Simple echo tool

  Testing SSE:

  1. Initialize session:
     curl -i http://localhost:9393 \\
       -H "Accept: application/json, text/event-stream" \\
       --json '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"sse-test","version":"1.0"}}}'

  2. Connect SSE stream (use the session ID from step 1):
     curl -i -N -H "Mcp-Session-Id: YOUR_SESSION_ID" http://localhost:9393

  3. In another terminal, test tools (responses will be sent via SSE if stream is active):

     Echo tool:
     curl -i http://localhost:9393 -H "Mcp-Session-Id: YOUR_SESSION_ID" \\
       -H "Accept: application/json, text/event-stream" \\
       --json '{"jsonrpc":"2.0","method":"tools/call","id":2,"params":{"name":"echo","arguments":{"message":"Hello SSE!"}}}'

     Notification tool (progress notifications require a progressToken in _meta):
     curl -i http://localhost:9393 -H "Mcp-Session-Id: YOUR_SESSION_ID" \\
       -H "Accept: application/json, text/event-stream" \\
       --json '{"jsonrpc":"2.0","method":"tools/call","id":3,"params":{"name":"notification_tool","arguments":{"message":"Hello SSE!","delay":1},"_meta":{"progressToken":"curl-progress"}}}'

  Note: Each POST is answered with an SSE stream of its own; request-scoped notifications
  (such as the progress events above) appear on it before the final response.
  The standalone GET stream carries server-initiated messages that are not tied to a request.

  Press Ctrl+C to stop the server
MESSAGE

# Start the server
Rackup::Handler.get("puma").run(rack_app, Port: 9393, Host: "localhost")
