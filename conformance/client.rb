# frozen_string_literal: true

# Conformance test client for the MCP Ruby SDK.
# Invoked by the conformance runner:
#   MCP_CONFORMANCE_SCENARIO=<scenario> bundle exec ruby conformance/client.rb <server-url>
#
# The server URL is passed as the last positional argument.
# The scenario name is read from the MCP_CONFORMANCE_SCENARIO environment variable,
# which is set automatically by the conformance test runner.

require "net/http"
require "json"
require "securerandom"
require "uri"
require_relative "../lib/mcp"

# A transport that handles both JSON and SSE (text/event-stream) responses.
# The standard `MCP::Client::HTTP` transport only accepts application/json,
# but the MCP `StreamableHTTPServerTransport` may return text/event-stream.
class ConformanceTransport
  def initialize(url:)
    @uri = URI(url)
  end

  def send_request(request:)
    http = Net::HTTP.new(@uri.host, @uri.port)
    req = Net::HTTP::Post.new(@uri.path.empty? ? "/" : @uri.path)
    req["Content-Type"] = "application/json"
    req["Accept"] = "application/json, text/event-stream"
    req.body = JSON.generate(request)

    response = http.request(req)

    case response.content_type
    when "application/json"
      JSON.parse(response.body)
    when "text/event-stream"
      parse_sse_response(response.body)
    else
      raise "Unexpected content type: #{response.content_type}"
    end
  end

  private

  def parse_sse_response(body)
    body.each_line do |line|
      next unless line.start_with?("data: ")

      data = line.delete_prefix("data: ").strip
      next if data.empty?

      return JSON.parse(data)
    end
    nil
  end
end

scenario = ENV["MCP_CONFORMANCE_SCENARIO"]
server_url = ARGV.last

unless scenario && server_url
  abort("Usage: MCP_CONFORMANCE_SCENARIO=<scenario> ruby conformance/client.rb <server-url>")
end

#
# TODO: Once https://github.com/modelcontextprotocol/ruby-sdk/pull/210 is merged,
# replace `ConformanceTransport` and the manual initialize handshake below with:
#
# ```
# transport = MCP::Client::HTTP.new(url: server_url)
# client = MCP::Client.new(transport: transport)
# client.connect(client_info: { ... }, protocol_version: "2025-11-25")
# ```
#
# After that `ConformanceTransport` will be removed.
#
transport = ConformanceTransport.new(url: server_url)

# MCP initialize handshake (the MCP::Client API does not expose this yet).
transport.send_request(request: {
  jsonrpc: "2.0",
  id: SecureRandom.uuid,
  method: "initialize",
  params: {
    clientInfo: { name: "ruby-sdk-conformance-client", version: MCP::VERSION },
    protocolVersion: "2025-11-25",
    capabilities: {},
  },
})

client = MCP::Client.new(transport: transport)

case scenario
when "initialize"
  client.tools
when "tools_call"
  tools = client.tools
  add_numbers = tools.find { |t| t.name == "add_numbers" }
  abort("Tool add_numbers not found") unless add_numbers
  client.call_tool(tool: add_numbers, arguments: { a: 1, b: 2 })
else
  abort("Unknown or unsupported scenario: #{scenario}")
end
