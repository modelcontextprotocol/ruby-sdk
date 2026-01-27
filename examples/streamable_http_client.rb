# frozen_string_literal: true

require "mcp"
require "mcp/client"
require "mcp/client/http"
require "mcp/client/tool"
require "net/http"
require "uri"
require "json"
require "logger"
require "event_stream_parser"

SERVER_URL = "http://localhost:9393"

# Logger for client operations
def create_logger
  logger = Logger.new($stdout)
  logger.formatter = proc do |severity, datetime, _progname, msg|
    "[CLIENT] #{severity} #{datetime.strftime("%H:%M:%S.%L")} - #{msg}\n"
  end
  logger
end

# Connect to SSE stream for real-time notifications
# The SDK doesn't support HTTP GET for SSE streaming yet, so we use raw Net::HTTP
# See: https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#listening-for-messages-from-the-server
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

def main
  logger = create_logger

  puts <<~MESSAGE
    MCP Streamable HTTP Client
    Make sure the server is running (ruby examples/streamable_http_server.rb)
    #{"=" * 60}
  MESSAGE

  # Initialize SDK client
  transport = MCP::Client::HTTP.new(url: SERVER_URL)
  client = MCP::Client.new(transport: transport)

  begin
    # Initialize session using SDK
    puts "=== Initializing session ==="
    init_response = client.connect(
      client_info: { name: "streamable-http-client", version: "1.0" },
    )
    puts <<~MESSAGE
      ID: #{client.session_id}
      Version: #{client.protocol_version}
      Server: #{init_response.dig("result", "serverInfo")}
    MESSAGE

    # Get available tools BEFORE establishing SSE connection
    # (Once SSE is active, server sends responses via SSE stream, not POST response)
    puts "=== Listing tools ==="
    tools = client.tools
    tools.each { |t| puts "  - #{t.name}: #{t.description}" }

    echo_tool = tools.find { |t| t.name == "echo" }
    notification_tool = tools.find { |t| t.name == "notification_tool" }

    # Start SSE connection in a separate thread (uses raw HTTP)
    # Note: After this, server responses will be sent via SSE, not POST
    sse_thread = Thread.new { connect_sse(client.session_id, logger) }

    # Give SSE time to connect
    sleep(1)

    # Interactive menu
    loop do
      puts <<~MENU.chomp

        === Available Actions ===
        1. Send notification (triggers SSE event)
        2. Echo message
        3. List tools
        0. Exit

        Choose an action:#{" "}
      MENU

      choice = gets.chomp

      case choice
      when "1"
        if notification_tool
          print("Enter notification message: ")
          message = gets.chomp
          print("Enter delay in seconds (0 for immediate): ")
          delay = gets.chomp.to_f

          puts "=== Calling tool: notification_tool ==="
          response = client.call_tool(
            tool: notification_tool,
            arguments: { message: message, delay: delay },
          )
          puts "Response: #{JSON.pretty_generate(response)}"
        else
          puts "notification_tool not available"
        end
      when "2"
        if echo_tool
          print("Enter message to echo: ")
          message = gets.chomp

          puts "=== Calling tool: echo ==="
          response = client.call_tool(tool: echo_tool, arguments: { message: message })
          puts "Response: #{JSON.pretty_generate(response)}"
        else
          puts "echo tool not available"
        end
      when "3"
        puts "=== Listing tools ==="
        puts "(Note: Response will appear in SSE stream when active)"
        client.tools.each do |tool|
          puts "  - #{tool.name}: #{tool.description}"
        end
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
    # Clean up SSE thread
    sse_thread.kill if sse_thread&.alive?

    # Close session using SDK
    puts "=== Closing session ==="
    client.close
    puts "Session closed"
  end
end

if __FILE__ == $PROGRAM_NAME
  main
end
