# frozen_string_literal: true

# Conformance test client for MCP client testing.
#
# Usage: ruby conformance/client.rb <server-url>
#
# The scenario name is read from the MCP_CONFORMANCE_SCENARIO environment variable,
# which is set by the conformance test runner.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "mcp"
require "mcp/client"
require "mcp/client/http"

server_url = ARGV[0]
scenario = ENV["MCP_CONFORMANCE_SCENARIO"]

unless server_url && scenario
  warn "Usage: MCP_CONFORMANCE_SCENARIO=<scenario> ruby conformance/client.rb <server-url>"
  exit 1
end

transport = MCP::Client::HTTP.new(url: server_url)
client = MCP::Client.new(transport: transport)

case scenario
when "initialize"
  client.connect(client_info: { name: "ruby-conformance-client", version: "1.0.0" })
  client.tools
  client.close
when "tools_call"
  client.connect(client_info: { name: "ruby-conformance-client", version: "1.0.0" })
  tools = client.tools
  tool = tools.find { |t| t.name == "add_numbers" }
  if tool
    client.call_tool(tool: tool, arguments: { a: 1, b: 2 })
  end
  client.close
else
  warn "Unknown scenario: #{scenario}"
  exit 1
end
