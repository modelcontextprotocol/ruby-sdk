# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "mcp"
require "json"

# Simple stdio client example that connects to the stdio_server.rb example
# Usage: ruby examples/stdio_client.rb

server_script = File.expand_path("stdio_server.rb", __dir__)

transport = MCP::Client::Stdio.new(command: "ruby", args: [server_script])
client = MCP::Client.new(transport: transport)

begin
  # Perform the MCP initialization handshake before sending any requests.
  client.connect

  # List available tools
  puts "=== Listing tools ==="
  tools = client.tools
  tools.each do |tool|
    puts "  Tool: #{tool.name} - #{tool.description}"
  end

  # Call the example_tool (adds two numbers)
  puts "\n=== Calling tool: example_tool ==="
  tool = tools.find { |t| t.name == "example_tool" }
  response = client.call_tool(tool: tool, arguments: { a: 5, b: 3 })
  puts "  Response: #{JSON.pretty_generate(response.dig("result", "content"))}"

  # Call the echo tool
  puts "\n=== Calling tool: echo ==="
  tool = tools.find { |t| t.name == "echo" }
  response = client.call_tool(tool: tool, arguments: { message: "Hello from stdio client!" })
  puts "  Response: #{JSON.pretty_generate(response.dig("result", "content"))}"

  # List prompts
  puts "\n=== Listing prompts ==="
  prompts = client.prompts
  prompts.each do |prompt|
    puts "  Prompt: #{prompt["name"]} - #{prompt["description"]}"
  end

  # List resources
  puts "\n=== Listing resources ==="
  resources = client.resources
  resources.each do |resource|
    puts "  Resource: #{resource["name"]} (#{resource["uri"]})"
  end

  # Read a resource
  puts "\n=== Reading resource: https://test_resource.invalid ==="
  contents = client.read_resource(uri: "https://test_resource.invalid")
  puts "  Response: #{JSON.pretty_generate(contents)}"
rescue => e
  puts "Error: #{e.message}"
  puts e.backtrace.first(5).join("\n")
ensure
  transport.close
end
