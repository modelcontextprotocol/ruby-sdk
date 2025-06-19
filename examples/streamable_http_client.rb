#!/usr/bin/env ruby
# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "logger"

# Logger for client operations
logger = Logger.new($stdout)
logger.formatter = proc do |severity, datetime, _progname, msg|
  "[CLIENT] #{severity} #{datetime.strftime("%H:%M:%S.%L")} - #{msg}\n"
end

# Server configuration
SERVER_URL = "http://localhost:9393/mcp"
PROTOCOL_VERSION = "2024-11-05"

# Helper method to make JSON-RPC requests
def make_request(session_id, method, params = {}, id = nil)
  uri = URI(SERVER_URL)
  http = Net::HTTP.new(uri.host, uri.port)

  request = Net::HTTP::Post.new(uri)
  request["Content-Type"] = "application/json"
  request["Mcp-Session-Id"] = session_id if session_id

  body = {
    jsonrpc: "2.0",
    method: method,
    params: params,
    id: id || SecureRandom.uuid,
  }

  request.body = body.to_json
  response = http.request(request)

  {
    status: response.code,
    headers: response.to_hash,
    body: JSON.parse(response.body),
  }
rescue => e
  { error: e.message }
end

# Connect to SSE stream
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

        response.read_body do |chunk|
          chunk.split("\n").each do |line|
            if line.start_with?("data: ")
              data = line[6..-1]
              begin
                logger.info("SSE data: #{data}")
              rescue JSON::ParserError
                logger.debug("Non-JSON SSE data: #{data}")
              end
            elsif line.start_with?(": ")
              logger.debug("SSE keepalive received: #{line}")
            end
          end
        end
      else
        logger.error("Failed to connect to SSE: #{response.code} #{response.message}")
      end
    end
  end
rescue Interrupt
  logger.info("SSE connection interrupted by user")
rescue => e
  logger.error("SSE connection error: #{e.message}")
end

# Main client flow
def main
  logger = Logger.new($stdout)
  logger.formatter = proc do |severity, datetime, _progname, msg|
    "[CLIENT] #{severity} #{datetime.strftime("%H:%M:%S.%L")} - #{msg}\n"
  end

  puts "=== MCP SSE Test Client ==="
  puts ""

  # Step 1: Initialize session
  logger.info("Initializing session...")

  init_response = make_request(
    nil,
    "initialize",
    {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: {
        name: "sse-test-client",
        version: "1.0",
      },
    },
    "init-1",
  )

  if init_response[:error]
    logger.error("Failed to initialize: #{init_response[:error]}")
    exit(1)
  end

  session_id = init_response[:headers]["mcp-session-id"]&.first

  if session_id.nil?
    logger.error("No session ID received")
    exit(1)
  end

  logger.info("Session initialized: #{session_id}")
  logger.info("Server info: #{init_response[:body]["result"]["serverInfo"]}")

  # Step 2: Start SSE connection in a separate thread
  sse_thread = Thread.new { connect_sse(session_id, logger) }

  # Give SSE time to connect
  sleep(1)

  # Step 3: Interactive menu
  loop do
    puts "\n=== Available Actions ==="
    puts "1. Send custom notification"
    puts "2. Test echo"
    puts "3. List tools"
    puts "0. Exit"
    puts ""
    print("Choose an action: ")

    choice = gets.chomp

    case choice
    when "1"
      print("Enter notification message: ")
      message = gets.chomp
      print("Enter delay in seconds (0 for immediate): ")
      delay = gets.chomp.to_f

      response = make_request(
        session_id,
        "tools/call",
        {
          name: "notification_tool",
          arguments: {
            message: message,
            delay: delay,
          },
        },
      )

      if response[:body]["result"]
        logger.info("Notification tool response: #{response[:body]["result"]["content"]}")
      else
        logger.error("Error: #{response[:body]["error"]}")
      end

    when "2"
      print("Enter message to echo: ")
      message = gets.chomp
      make_request(session_id, "tools/call", { name: "echo", arguments: { message: message } })

    when "3"
      make_request(session_id, "tools/list")

    when "0"
      logger.info("Exiting...")
      break

    else
      puts "Invalid choice"
    end
  end

  # Clean up
  sse_thread.kill if sse_thread.alive?

  # Close session
  logger.info("Closing session...")
  make_request(session_id, "close")
  logger.info("Session closed")
rescue Interrupt
  logger.info("Client interrupted by user")
rescue => e
  logger.error("Client error: #{e.message}")
  logger.error(e.backtrace.join("\n"))
end

# Run the client
if __FILE__ == $PROGRAM_NAME
  main
end
