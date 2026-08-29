# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "mcp"
require "rackup"
require "json"
require "logger"

# Example server for the 2026-07-28 modern lifecycle (SEP-2575).
#
# The modern lifecycle is sessionless: there is no `initialize` handshake and no `Mcp-Session-Id`.
# Clients probe the server with `server/discover` and then send self-contained requests that carry
# a `_meta` envelope (protocol version, client info, capabilities) plus `MCP-Protocol-Version` / `Mcp-Method` headers.
#
# The same server still accepts the legacy `initialize` flow: the transport routes each request to
# the legacy or modern lifecycle by its `MCP-Protocol-Version` header, so no constructor flag is needed.
server = MCP::Server.new(
  name: "modern_lifecycle_server",
  version: "1.0.0",
  instructions: "Example server demonstrating the 2026-07-28 modern lifecycle.",
  # SEP-2549 cache hints, advertised in `server/discover` and stamped on cacheable results.
  # The defaults are 0 / "private"; non-default values are used here so they are visible
  # in the example output.
  ttl_ms: 60_000,
  cache_scope: "public",
)

server.define_tool(
  name: "greet",
  description: "Greets a name; a plain single round-trip tool",
  input_schema: { properties: { name: { type: "string" } }, required: ["name"] },
) do |name:|
  MCP::Tool::Response.new([{ type: "text", text: "Hello, #{name}!" }])
end

# A multi round-trip tool (SEP-2322). The first round returns an `input_required` result asking
# the client to answer an embedded `elicitation/create` request; the client re-issues the call with
# `inputResponses` plus the echoed opaque `requestState`, and the handler re-runs from the start
# and reads the answer via `server_context`.
# Over a legacy connection the default `input_required_legacy_shim` fulfills the same result through
# a real server-to-client elicitation request instead.
server.define_tool(
  name: "deploy",
  description: "Deploys an app; asks which environment via a multi round-trip elicitation (SEP-2322)",
  input_schema: { properties: { app: { type: "string" } }, required: ["app"] },
) do |app:, server_context:|
  answer = server_context.input_response("environment")

  if answer.nil?
    MCP::Server::InputRequiredResult.new(
      input_requests: {
        "environment" => {
          method: "elicitation/create",
          params: {
            message: "Which environment should #{app} deploy to?",
            requestedSchema: {
              type: "object",
              properties: {
                environment: { type: "string", title: "Environment", default: "staging" },
              },
              required: ["environment"],
            },
          },
        },
      },
      request_state: JSON.generate(app: app),
    )
  else
    # Transports parse JSON with `symbolize_names: true`, so answers normally arrive symbol-keyed;
    # the string fallback covers custom transports.
    action = answer[:action] || answer["action"]

    if action == "accept"
      environment = answer.dig(:content, :environment) || answer.dig("content", "environment")
      MCP::Tool::Response.new([{ type: "text", text: "Deployed #{app} to #{environment}" }])
    else
      MCP::Tool::Response.new([{ type: "text", text: "Deployment of #{app} was cancelled (#{action})" }])
    end
  end
end

transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)

# `StreamableHTTPTransport` responds to `call(env)`, so it can be used directly as a Rack app.
# See http_server.rb for a CORS setup for browser-based clients.
rack_app = Rack::Builder.new do
  use(Rack::CommonLogger, Logger.new($stdout))
  use(Rack::ShowExceptions)

  run(transport)
end

puts <<~MESSAGE
  === MCP Modern Lifecycle Server (2026-07-28) ===

  Starting server on http://localhost:9494

  Run the SDK client against it:
    ruby examples/modern_http_client.rb

  Or walk the modern lifecycle with cURL:

  1. Probe capabilities (sessionless, works without any protocol headers):
     curl -s http://localhost:9494 \\
       -H "Accept: application/json, text/event-stream" \\
       --json '{"jsonrpc":"2.0","id":0,"method":"server/discover"}'

  2. Modern tools/list (the MCP-Protocol-Version header selects the era, the
     Mcp-Method header mirrors the method, and params._meta carries the
     SEP-2575 envelope):
     curl -s http://localhost:9494 \\
       -H "Accept: application/json, text/event-stream" \\
       -H "MCP-Protocol-Version: 2026-07-28" -H "Mcp-Method: tools/list" \\
       --json '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'

  3. Modern tools/call (name-bearing methods additionally mirror the name in
     the Mcp-Name header; no Mcp-Session-Id is ever sent):
     curl -s http://localhost:9494 \\
       -H "Accept: application/json, text/event-stream" \\
       -H "MCP-Protocol-Version: 2026-07-28" -H "Mcp-Method: tools/call" -H "Mcp-Name: greet" \\
       --json '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"greet","arguments":{"name":"curl"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'

  Press Ctrl+C to stop the server
MESSAGE

Rackup::Handler.get("puma").run(rack_app, Port: 9494, Host: "localhost")
