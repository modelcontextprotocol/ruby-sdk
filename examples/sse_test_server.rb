#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "mcp"
require "mcp/transports/http"
require "rack"
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

      logger&.info("Returning notification message: #{message}")

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

# Create the StreamableHTTP transport
server.transport = MCP::Transports::HTTP.new(server)

# Create a logger for MCP request/response logging
mcp_logger = Logger.new($stdout)
mcp_logger.formatter = proc do |_severity, _datetime, _progname, msg|
  "[MCP] #{msg}\n"
end

# Create the Rack application
app = proc do |env|
  request = Rack::Request.new(env)

  # Log request details
  if request.post?
    body = request.body.read
    request.body.rewind
    begin
      parsed_body = JSON.parse(body)
      mcp_logger.info("Request: #{parsed_body["method"]} (id: #{parsed_body["id"]})")

      # Log SSE-specific setup
      if parsed_body["method"] == "initialize"
        sse_logger.info("New client initializing session")
      end
    rescue JSON::ParserError
      mcp_logger.warn("Invalid JSON in request")
    end
  elsif request.get?
    session_id = request.env["HTTP_MCP_SESSION_ID"] ||
      Rack::Utils.parse_query(request.env["QUERY_STRING"])["sessionId"]
    sse_logger.info("SSE connection request for session: #{session_id}")
  end

  # Handle the request
  response = server.handle_rack_request(request)

  # Log response details
  status, headers, body = response
  if body.is_a?(Array) && !body.empty? && request.post?
    begin
      parsed_response = JSON.parse(body.first)
      if parsed_response["error"]
        mcp_logger.error("Response error: #{parsed_response["error"]["message"]}")
      elsif parsed_response["accepted"]
        # Response was sent via SSE
        sse_logger.info("Response sent via SSE stream")
      else
        mcp_logger.info("Response: success (id: #{parsed_response["id"]})")

        # Log session ID for initialization
        if headers["Mcp-Session-Id"]
          sse_logger.info("Session created: #{headers["Mcp-Session-Id"]}")
        end
      end
    rescue JSON::ParserError
      mcp_logger.warn("Invalid JSON in response")
    end
  elsif request.get? && status == 200
    sse_logger.info("SSE stream established")
  end

  response
end

# Build the Rack application with middleware
rack_app = Rack::Builder.new do
  use(Rack::CommonLogger, Logger.new($stdout))
  use(Rack::ShowExceptions)
  run(app)
end

# Print usage instructions
puts "=== MCP SSE Test Server ==="
puts ""
puts "Starting server on http://localhost:9393"
puts ""
puts "Available Tools:"
puts "1. NotificationTool - Returns messages that are sent via SSE when stream is active"
puts "2. echo - Simple echo tool"
puts ""
puts "Testing SSE:"
puts ""
puts "1. Initialize session:"
puts '   curl -X POST http://localhost:9393 -H "Content-Type: application/json" \\'
puts '     -d \'{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"sse-test","version":"1.0"}}}\''
puts ""
puts "2. Connect SSE stream (use the session ID from step 1):"
puts '   curl -N -H "Mcp-Session-Id: YOUR_SESSION_ID" http://localhost:9393'
puts ""
puts "3. In another terminal, test tools (responses will be sent via SSE if stream is active):"
puts ""
puts "   Echo tool:"
puts '   curl -X POST http://localhost:9393 -H "Content-Type: application/json" -H "Mcp-Session-Id: YOUR_SESSION_ID" \\'
puts '     -d \'{"jsonrpc":"2.0","method":"tools/call","id":2,"params":{"name":"echo","arguments":{"message":"Hello SSE!"}}}\''
puts ""
puts "   Notification tool (with 2 second delay):"
puts '   curl -X POST http://localhost:9393 -H "Content-Type: application/json" -H "Mcp-Session-Id: YOUR_SESSION_ID" \\'
puts '     -d \'{"jsonrpc":"2.0","method":"tools/call","id":3,"params":{"name":"notification_tool","arguments":{"message":"Hello SSE!", "delay": 2}}}\''
puts ""
puts "Note: When an SSE stream is active, tool responses will appear in the SSE stream and the POST request will return {\"accepted\": true}"
puts ""
puts "Press Ctrl+C to stop the server"
puts ""

# Start the server
Rackup::Handler.get("puma").run(rack_app, Port: 9393, Host: "localhost")
