# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "mcp"
require "net/http"
require "uri"
require "json"
require "logger"
require "event_stream_parser"

SERVER_URL = "http://localhost:9393"

def create_logger
  logger = Logger.new($stdout)
  logger.formatter = proc do |severity, datetime, _progname, msg|
    "[CLIENT] #{severity} #{datetime.strftime("%H:%M:%S.%L")} - #{msg}\n"
  end
  logger
end

# MCP::Client::HTTP opens the optional GET SSE stream itself once a server-request handler
# (e.g. `client.on_elicitation`) is registered. This example instead opens the stream with
# raw `Net::HTTP` to show the SSE wire format. The GET stream carries server-initiated messages
# that are not tied to a client request; request-scoped notifications such as progress arrive on
# the POST's own SSE response stream (see `stream_tool_call` below).
def connect_sse(session_id, logger)
  uri = URI(SERVER_URL)

  logger.info("Connecting to SSE stream...")

  Net::HTTP.start(uri.host, uri.port) do |http|
    request = Net::HTTP::Get.new(uri)
    request["Mcp-Session-Id"] = session_id
    request["Accept"] = "text/event-stream"
    request["Cache-Control"] = "no-cache"

    http.request(request) do |response|
      if response.code == "200"
        logger.info("SSE stream connected successfully")

        parser = EventStreamParser::Parser.new
        response.read_body do |chunk|
          parser.feed(chunk) do |type, data, _id|
            if type.empty?
              logger.info("SSE event: #{data}")
            else
              logger.info("SSE event (#{type}): #{data}")
            end
          end
        end
      else
        logger.error("Failed to connect to SSE: #{response.code} #{response.message}")
      end
    end
  end
rescue Interrupt
  logger.info("SSE connection interrupted")
rescue => e
  logger.error("SSE connection error: #{e.message}")
end

def print_response(response)
  if response.nil?
    puts "Response accepted; watch the SSE stream for the server response."
  else
    puts "Response: #{JSON.pretty_generate(response)}"
  end
end

# Calls a tool with a raw streaming POST so each SSE event on the response stream is printed as
# it arrives: the `notifications/progress` events requested via `_meta.progressToken`,
# then the final JSON-RPC response. `MCP::Client#call_tool` reads the same stream but consumes
# the progress notifications internally, so the raw request makes them visible here.
def stream_tool_call(session_id, request_id, name:, arguments:, logger:)
  uri = URI(SERVER_URL)

  body = {
    jsonrpc: "2.0",
    id: request_id,
    method: "tools/call",
    params: {
      name: name,
      arguments: arguments,
      _meta: { progressToken: "streamable-http-client" },
    },
  }

  Net::HTTP.start(uri.host, uri.port) do |http|
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Accept"] = "application/json, text/event-stream"
    request["Mcp-Session-Id"] = session_id
    request.body = JSON.generate(body)

    http.request(request) do |response|
      parser = EventStreamParser::Parser.new
      response.read_body do |chunk|
        parser.feed(chunk) do |_type, data, _id|
          logger.info("SSE event: #{data}")
        end
      end
    end
  end
end

def main
  logger = create_logger

  puts <<~MESSAGE
    MCP Streamable HTTP Client
    Make sure the server is running (ruby examples/streamable_http_server.rb)
    #{"=" * 60}
  MESSAGE

  http_transport = MCP::Client::HTTP.new(url: SERVER_URL)
  client = MCP::Client.new(transport: http_transport)
  sse_thread = nil
  raw_request_id = 0

  begin
    puts "=== Initializing session ==="

    # The default `mode: :auto` adopts the sessionless modern lifecycle (2026-07-28)
    # when the server supports it. This example demonstrates the legacy session's SSE stream,
    # so pin the legacy `initialize` handshake.
    server_info = client.connect(
      client_info: { name: "streamable-http-client", version: "1.0" },
      mode: :legacy,
    )

    puts <<~MESSAGE
      ID: #{http_transport.session_id}
      Version: #{http_transport.protocol_version}
      Server: #{server_info["serverInfo"]}
    MESSAGE

    unless http_transport.session_id
      logger.error("No session ID received; this example requires a stateful Streamable HTTP session.")
      return
    end

    puts "=== Listing tools ==="
    tools = client.tools
    tools.each { |tool| puts "  - #{tool.name}: #{tool.description}" }

    echo_tool = tools.find { |tool| tool.name == "echo" }
    notification_tool = tools.find { |tool| tool.name == "notification_tool" }

    sse_thread = Thread.new { connect_sse(http_transport.session_id, logger) }
    sleep(1)

    loop do
      puts <<~MENU.chomp

        === Available Actions ===
        1. Send notification (triggers SSE event)
        2. Echo message
        3. Show cached tools
        0. Exit

        Choose an action:#{" "}
      MENU

      case gets.chomp
      when "1"
        if notification_tool
          print("Enter notification message: ")
          message = gets.chomp
          print("Enter delay in seconds (0 for immediate): ")
          delay = gets.chomp.to_f

          puts "=== Calling tool: notification_tool (raw streaming POST) ==="
          raw_request_id += 1
          stream_tool_call(
            http_transport.session_id,
            "raw-#{raw_request_id}",
            name: notification_tool.name,
            arguments: { message: message, delay: delay },
            logger: logger,
          )
        else
          puts "notification_tool not available"
        end
      when "2"
        if echo_tool
          print("Enter message to echo: ")
          message = gets.chomp

          puts "=== Calling tool: echo ==="
          response = client.call_tool(tool: echo_tool, arguments: { message: message })
          print_response(response)
        else
          puts "echo tool not available"
        end
      when "3"
        puts "=== Cached tools ==="
        tools.each { |tool| puts "  - #{tool.name}: #{tool.description}" }
      when "0"
        logger.info("Exiting...")
        break
      else
        puts "Invalid choice"
      end
    end
  rescue MCP::Client::SessionExpiredError => e
    logger.error("Session expired: #{e.message}")
  rescue MCP::Client::RequestHandlerError => e
    logger.error("Request error: #{e.message}")
  rescue Interrupt
    logger.info("Client interrupted")
  rescue => e
    logger.error("Error: #{e.message}")
    logger.error(e.backtrace.first(5).join("\n"))
  ensure
    sse_thread.kill if sse_thread&.alive?

    if http_transport.connected?
      puts "=== Closing session ==="
      http_transport.close
      puts "Session closed"
    end
  end
end

main
