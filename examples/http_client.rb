#!/usr/bin/env ruby
# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

# Simple HTTP client example for interacting with the MCP HTTP server
class MCPHTTPClient
  def initialize(base_url = "http://localhost:9292")
    @base_url = base_url
    @session_id = nil
  end

  def send_request(method, params = nil, id = nil)
    uri = URI(@base_url)
    http = Net::HTTP.new(uri.host, uri.port)

    request = Net::HTTP::Post.new(uri.path.empty? ? "/" : uri.path)
    request["Content-Type"] = "application/json"
    request["Mcp-Session-Id"] = @session_id if @session_id

    body = {
      jsonrpc: "2.0",
      method: method,
      params: params,
      id: id || rand(10000),
    }.compact

    request.body = body.to_json

    response = http.request(request)

    # Store session ID if provided
    if response["Mcp-Session-Id"]
      @session_id = response["Mcp-Session-Id"]
      puts "Session ID: #{@session_id}"
    end

    JSON.parse(response.body)
  end

  def initialize_session
    puts "=== Initializing session ==="
    result = send_request("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: {
        name: "example_client",
        version: "1.0",
      },
    })
    puts "Response: #{JSON.pretty_generate(result)}"
    puts
    result
  end

  def ping
    puts "=== Sending ping ==="
    result = send_request("ping")
    puts "Response: #{JSON.pretty_generate(result)}"
    puts
    result
  end

  def list_tools
    puts "=== Listing tools ==="
    result = send_request("tools/list")
    puts "Response: #{JSON.pretty_generate(result)}"
    puts
    result
  end

  def call_tool(name, arguments)
    puts "=== Calling tool: #{name} ==="
    result = send_request("tools/call", {
      name: name,
      arguments: arguments,
    })
    puts "Response: #{JSON.pretty_generate(result)}"
    puts
    result
  end

  def list_prompts
    puts "=== Listing prompts ==="
    result = send_request("prompts/list")
    puts "Response: #{JSON.pretty_generate(result)}"
    puts
    result
  end

  def get_prompt(name, arguments)
    puts "=== Getting prompt: #{name} ==="
    result = send_request("prompts/get", {
      name: name,
      arguments: arguments,
    })
    puts "Response: #{JSON.pretty_generate(result)}"
    puts
    result
  end

  def list_resources
    puts "=== Listing resources ==="
    result = send_request("resources/list")
    puts "Response: #{JSON.pretty_generate(result)}"
    puts
    result
  end

  def read_resource(uri)
    puts "=== Reading resource: #{uri} ==="
    result = send_request("resources/read", {
      uri: uri,
    })
    puts "Response: #{JSON.pretty_generate(result)}"
    puts
    result
  end

  def close_session
    return unless @session_id

    puts "=== Closing session ==="
    uri = URI(@base_url)
    http = Net::HTTP.new(uri.host, uri.port)

    request = Net::HTTP::Delete.new(uri.path.empty? ? "/" : uri.path)
    request["Mcp-Session-Id"] = @session_id

    response = http.request(request)
    result = JSON.parse(response.body)
    puts "Response: #{JSON.pretty_generate(result)}"
    puts

    @session_id = nil
    result
  end
end

# Main script
if __FILE__ == $PROGRAM_NAME
  puts "MCP HTTP Client Example"
  puts "Make sure the HTTP server is running (ruby examples/http_server.rb)"
  puts "=" * 50
  puts

  client = MCPHTTPClient.new

  begin
    # Initialize session
    client.initialize_session

    # Test ping
    client.ping

    # List available tools
    client.list_tools

    # Call the example_tool (note: snake_case name)
    client.call_tool("example_tool", { a: 5, b: 3 })

    # Call the echo tool
    client.call_tool("echo", { message: "Hello from client!" })

    # List prompts
    client.list_prompts

    # Get a prompt (note: snake_case name)
    client.get_prompt("example_prompt", { message: "This is a test message" })

    # List resources
    client.list_resources

    # Read a resource
    client.read_resource("test_resource")
  rescue => e
    puts "Error: #{e.message}"
    puts e.backtrace
  ensure
    # Clean up session
    client.close_session
  end
end
