# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "mcp"
require "json"

# Example MCP HTTP client using the improved MCP::Client library
# This demonstrates how to use the streamable HTTP transport with session management
class MCPHTTPClientExample
  def initialize(base_url = "http://localhost:9292")
    # Create the HTTP transport
    transport = MCP::Client::HTTP.new(url: base_url)

    # Create the MCP client with custom client info and protocol version
    @client = MCP::Client.new(
      transport: transport,
      client_info: { name: "example_client", version: "1.0" },
      protocol_version: "2024-11-05",
    )
  end

  def initialize_session
    puts "=== Initializing session ==="
    result = @client.init
    puts "Response: #{JSON.pretty_generate(result)}"
    puts "Session ID: #{@client.transport.session_id}" if @client.transport.session_id

    result
  end

  def list_tools
    puts "=== Listing tools ==="
    tools = @client.tools
    result = { tools: tools.map { |t| { name: t.name, description: t.description } } }
    puts "Response: #{JSON.pretty_generate(result)}"

    tools
  end

  def call_tool(name, arguments)
    puts "=== Calling tool: #{name} ==="
    tool = @client.tools.find { |t| t.name == name }

    unless tool
      puts "Error: Tool '#{name}' not found"
      return nil
    end

    result = @client.call_tool(tool: tool, arguments: arguments)
    puts "Response: #{JSON.pretty_generate(result)}"

    result
  end

  def list_prompts
    puts "=== Listing prompts ==="
    result = @client.prompts
    puts "Response: #{JSON.pretty_generate(result)}"

    result
  end

  def get_prompt(name, arguments)
    puts "=== Getting prompt: #{name} ==="
    result = @client.get_prompt(name: name, arguments: arguments)
    puts "Response: #{JSON.pretty_generate(result)}"

    result
  end

  def list_resources
    puts "=== Listing resources ==="
    result = @client.resources
    puts "Response: #{JSON.pretty_generate(result)}"

    result
  end

  def read_resource(uri)
    puts "=== Reading resource: #{uri} ==="
    result = @client.read_resource(uri: uri)
    puts "Response: #{JSON.pretty_generate(result)}"

    result
  end
end

# Main script
if __FILE__ == $PROGRAM_NAME
  puts <<~MESSAGE
    MCP HTTP Client Example (Using MCP::Client Library)
    Make sure the HTTP server is running (ruby examples/http_server.rb)
    #{"=" * 50}
  MESSAGE

  client = MCPHTTPClientExample.new

  begin
    # Initialize session (automatically called on first request if not explicit)
    client.initialize_session

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
  end
end
