# frozen_string_literal: true

# The MCP server and its Streamable HTTP transport are built here, once at boot,
# following the "Rails (mount)" pattern from the top-level README.
# Routes are loaded after the application initializes, so the tool classes in app/tools
# are available at this point (they are not yet available in config/initializers,
# where Zeitwerk has not set up autoloading).
#
# The transport keeps session and SSE state in memory, so run a single server process
# (e.g., Puma with `workers 0`, which is the rackup default).
# See the top-level README for multi-instance and stateless deployment notes.
server = MCP::Server.new(
  name: "rails_example_server",
  title: "Rails Example Server",
  version: "1.0.0",
  tools: [AddTool, GreetingTool],
  resources: [
    MCP::Resource.new(
      uri: "example://rails/readme",
      name: "readme",
      title: "Example README",
      description: "Describes this Rails example MCP server",
      mime_type: "text/plain",
    ),
  ],
  server_context: { app_name: "mcp_rails_example" },
)

server.resources_read_handler do |params|
  [
    {
      uri: params[:uri],
      mimeType: "text/plain",
      text: "This resource is served by the Rails example MCP server (Rails #{Rails.version}).",
    },
  ]
end

transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)

Rails.application.routes.draw do
  # `StreamableHTTPTransport` is a Rack app, so it can be mounted directly.
  # `mount` directs all HTTP methods on /mcp to the transport, which internally dispatches POST (JSON-RPC messages),
  # GET (SSE stream), and DELETE (session termination) per the MCP Streamable HTTP transport spec.
  mount(transport => "/mcp")
end
