# frozen_string_literal: true

# Conformance test client for the MCP Ruby SDK.
# Invoked by the conformance runner:
#   MCP_CONFORMANCE_SCENARIO=<scenario> bundle exec ruby conformance/client.rb <server-url>
#
# The server URL is passed as the last positional argument.
# The scenario name is read from the MCP_CONFORMANCE_SCENARIO environment variable,
# which is set automatically by the conformance test runner.

require "faraday"
require "json"
require_relative "../lib/mcp"

scenario = ENV["MCP_CONFORMANCE_SCENARIO"]
server_url = ARGV.last

unless scenario && server_url
  abort("Usage: MCP_CONFORMANCE_SCENARIO=<scenario> ruby conformance/client.rb <server-url>")
end

# The conformance harness optionally injects scenario-specific data via
# the `MCP_CONFORMANCE_CONTEXT` environment variable as a JSON document. The shape is
# defined by the harness, not the MCP spec, and has varied between versions:
#
# - Newer (`@modelcontextprotocol/conformance` >= 0.x): scenario fields are
#   spread at the top level alongside `name`, e.g.
#   `{"name":"auth/pre-registration","client_id":"...","client_secret":"..."}`.
# - Older: a nested `context` object: `{"name":"...","context":{...}}`.
#
# Both shapes are accepted so the client conforms to whichever harness version
# the developer has on hand.
def conformance_context
  raw = ENV["MCP_CONFORMANCE_CONTEXT"]
  return {} if raw.nil? || raw.empty?

  parsed = JSON.parse(raw)
  return {} unless parsed.is_a?(Hash)

  if parsed["context"].is_a?(Hash)
    parsed["context"]
  else
    parsed.reject { |key, _| key == "name" }
  end
rescue JSON::ParserError
  {}
end

# Builds an OAuth provider that drives the authorization code + PKCE + DCR flow
# non-interactively against the conformance test's auth server. The conformance
# `/authorize` endpoint redirects synchronously to `redirect_uri` with
# `code=test-auth-code`, so we follow it manually instead of opening a browser.
def build_oauth_provider(context)
  callback_holder = {}
  redirect_uri = "http://localhost:0/callback"

  redirect_handler = ->(authorization_url) do
    response = Faraday.new.get(authorization_url) do |req|
      req.options.params_encoder = nil
    end
    location = response.headers["location"] || response.headers["Location"]
    abort("Authorization request did not redirect: #{response.status}.") unless location

    callback_holder[:url] = URI.parse(location)
  end

  callback_handler = -> do
    query = URI.decode_www_form(callback_holder.fetch(:url).query).to_h
    [query["code"], query["state"]]
  end

  storage = MCP::Client::OAuth::InMemoryStorage.new
  if context["client_id"]
    storage.save_client_information(
      "client_id" => context["client_id"],
      "client_secret" => context["client_secret"],
      "token_endpoint_auth_method" => context["token_endpoint_auth_method"] || "client_secret_basic",
    )
  end

  MCP::Client::OAuth::Provider.new(
    client_metadata: {
      client_name: "ruby-sdk-conformance-client",
      redirect_uris: [redirect_uri],
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      token_endpoint_auth_method: "none",
    },
    redirect_uri: redirect_uri,
    redirect_handler: redirect_handler,
    callback_handler: callback_handler,
    storage: storage,
  )
end

oauth = scenario.start_with?("auth/") ? build_oauth_provider(conformance_context) : nil
transport = MCP::Client::HTTP.new(url: server_url, oauth: oauth)
client = MCP::Client.new(transport: transport)
client.connect(client_info: { name: "ruby-sdk-conformance-client", version: MCP::VERSION })

case scenario
when "initialize"
  client.tools
when "tools_call"
  tools = client.tools
  add_numbers = tools.find { |t| t.name == "add_numbers" }
  abort("Tool add_numbers not found") unless add_numbers
  client.call_tool(tool: add_numbers, arguments: { a: 1, b: 2 })
when %r|\Aauth/|
  # Auth-only scenarios: the protocol-level checks (PRM/AS metadata, DCR, PKCE, token usage)
  # are observed by the conformance server during `connect` and the subsequent request below.
  # Listing tools forces a second authenticated MCP request so the bearer token usage check fires.
  client.tools
else
  abort("Unknown or unsupported scenario: #{scenario}")
end
