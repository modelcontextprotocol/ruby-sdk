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

# URL the conformance harness expects to see as the OAuth `client_id` for the `auth/basic-cimd` scenario
# when the AS advertises `client_id_metadata_document_supported`. The harness does not fetch the document,
# only matches the value, so the URL does not need to resolve.
CONFORMANCE_CIMD_URL = "https://conformance-test.local/client-metadata.json"

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

# Saves the pre-registered `client_id` / `client_secret` the harness injects
# via context (used by pre-registration and client_credentials scenarios).
def storage_for(context)
  storage = MCP::Client::OAuth::InMemoryStorage.new
  if context["client_id"]
    storage.save_client_information(
      "client_id" => context["client_id"],
      "client_secret" => context["client_secret"],
      "token_endpoint_auth_method" => context["token_endpoint_auth_method"] || "client_secret_basic",
    )
  end
  storage
end

# Builds a `client_credentials`-only provider (machine-to-machine, no redirect).
# The pre-registered credentials are injected by the harness via context:
# a shared secret for the basic scenario, or a PEM private key plus signing algorithm
# (default ES256, matching the TypeScript and Python conformance clients)
# for the `private_key_jwt` scenario.
def build_client_credentials_provider(context)
  if context["private_key_pem"]
    MCP::Client::OAuth::ClientCredentialsProvider.new(
      client_id: context["client_id"],
      token_endpoint_auth_method: "private_key_jwt",
      private_key: context["private_key_pem"],
      signing_algorithm: context["signing_algorithm"] || "ES256",
    )
  else
    MCP::Client::OAuth::ClientCredentialsProvider.new(
      client_id: context["client_id"],
      client_secret: context["client_secret"],
      token_endpoint_auth_method: context["token_endpoint_auth_method"] || "client_secret_basic",
    )
  end
end

# Builds an OAuth provider that drives the authorization code + PKCE + DCR flow
# non-interactively against the conformance test's auth server. The conformance
# `/authorize` endpoint redirects synchronously to `redirect_uri` with
# `code=test-auth-code`, so we follow it manually instead of opening a browser.
def build_oauth_provider(context, scenario:)
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
    # The 3-element form opts into SEP-2468 / RFC 9207 `iss` validation;
    # `query["iss"]` is nil when the authorization response carried no `iss`.
    [query["code"], query["state"], query["iss"]]
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
    storage: storage_for(context),
    client_id_metadata_document_url: (scenario == "auth/basic-cimd" ? CONFORMANCE_CIMD_URL : nil),
  )
end

def build_provider_for(scenario, context)
  if scenario.start_with?("auth/client-credentials")
    build_client_credentials_provider(context)
  else
    build_oauth_provider(context, scenario: scenario)
  end
end

oauth = scenario.start_with?("auth/") ? build_provider_for(scenario, conformance_context) : nil
transport = MCP::Client::HTTP.new(url: server_url, oauth: oauth)
client = MCP::Client.new(transport: transport)
capabilities = scenario == "elicitation-sep1034-client-defaults" ? { elicitation: {} } : {}
client.connect(
  client_info: { name: "ruby-sdk-conformance-client", version: MCP::VERSION },
  capabilities: capabilities,
)

case scenario
when "initialize"
  client.tools
when "tools_call"
  tools = client.tools
  add_numbers = tools.find { |t| t.name == "add_numbers" }
  abort("Tool add_numbers not found") unless add_numbers
  client.call_tool(tool: add_numbers, arguments: { a: 1, b: 2 })
when "sse-retry"
  # SEP-1699: the server closes the tools/call SSE stream right after a priming event.
  # The transport waits the server's `retry:` interval, reconnects with a GET carrying `Last-Event-ID`,
  # and receives the tool result on the resumed stream; the harness verifies the reconnect,
  # its timing, and the header.
  tools = client.tools
  test_reconnection = tools.find { |t| t.name == "test_reconnection" }
  abort("Tool test_reconnection not found") unless test_reconnection
  client.call_tool(tool: test_reconnection, arguments: {})
when "elicitation-sep1034-client-defaults"
  # SEP-1034: the server sends `elicitation/create` on the tools/call SSE stream with every property declaring
  # a `default` and none required. The handler accepts and fills the omitted fields from those defaults.
  client.on_elicitation do |params|
    { action: "accept", content: MCP::Client::Elicitation.apply_defaults(params["requestedSchema"] || {}) }
  end

  tools = client.tools
  defaults_tool = tools.find { |t| t.name == "test_client_elicitation_defaults" }

  abort("Tool test_client_elicitation_defaults not found") unless defaults_tool

  client.call_tool(tool: defaults_tool, arguments: {})
when %r|\Aauth/|
  # Auth-only scenarios: the protocol-level checks (PRM/AS metadata, DCR, PKCE, token usage)
  # are observed by the conformance server during `connect` and the subsequent request below.
  # Listing tools forces a second authenticated MCP request so the bearer token usage check fires.
  tools = client.tools

  # `auth/scope-step-up` only fires its escalation 403 on `tools/call`, not `tools/list`,
  # so the client must actually invoke a tool to drive the second authorization request
  # the scenario asserts on.
  if scenario == "auth/scope-step-up"
    tool = tools.find { |t| t.name == "test-tool" } || tools.first
    abort("No tool exposed by conformance server for #{scenario}") unless tool
    client.call_tool(tool: tool, arguments: {})
  end
else
  abort("Unknown or unsupported scenario: #{scenario}")
end
