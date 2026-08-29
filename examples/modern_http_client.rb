# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "mcp"
require "json"

# Client example for the 2026-07-28 modern lifecycle (SEP-2575), which replaces the `initialize` handshake
# and per-session state with sessionless, self-contained requests.
class MCPModernHTTPClient
  def initialize(base_url = "http://localhost:9494")
    @transport = MCP::Client::HTTP.new(url: base_url)
    @client = MCP::Client.new(transport: @transport)
  end

  # `server/discover` (SEP-2575) is sessionless capability discovery that works before, or instead of, `connect`.
  def discover
    puts "=== Discovering server capabilities (server/discover) ==="
    result = @client.discover
    puts <<~MESSAGE
      Supported versions: #{result.supported_versions.inspect}
      Server: #{result.server_info}
      Cache hints: ttlMs=#{result.ttl_ms}, cacheScope=#{result.cache_scope} (SEP-2549)
      Instructions: #{result.instructions}
    MESSAGE

    result
  end

  # The handler answers `elicitation/create` requests embedded in SEP-2322 `input_required` results; once registered,
  # `call_tool` resumes those results automatically.
  # Register it before `connect` so the connection never needs a server-to-client route.
  def register_elicitation_handler
    @client.on_elicitation do |params|
      puts "  Server asked: #{params["message"]}"

      { action: "accept", content: MCP::Client::Elicitation.apply_defaults(params["requestedSchema"]) }
    end
  end

  # `mode: :modern` requires the modern lifecycle and fails on legacy-only servers;
  # the default `:auto` probes `server/discover` first and falls back to the legacy `initialize` handshake.
  # The `elicitation` capability must be declared before the server may embed elicitation requests.
  def connect
    puts "=== Adopting the modern lifecycle ==="
    result = @client.connect(
      client_info: { name: "modern-http-client", version: "1.0" },
      capabilities: { elicitation: {} },
      mode: :modern,
    )
    puts <<~MESSAGE
      Modern connection: #{@transport.modern?}
      Protocol version: #{@client.protocol_version}
    MESSAGE

    result
  end

  # Modern requests are self-contained: the SDK stamps the `_meta` envelope (protocol version,
  # client info, capabilities) and the Mcp-Method and Mcp-Name headers on every request automatically.
  def list_tools
    puts "=== Listing tools ==="
    page = @client.list_tools
    page.tools.each { |tool| puts "  - #{tool.name}: #{tool.description}" }
    puts "Cache hints: ttlMs=#{page.ttl_ms}, cacheScope=#{page.cache_scope}"

    page
  end

  def call_tool(name, arguments)
    puts "=== Calling tool: #{name} ==="
    response = @client.call_tool(name: name, arguments: arguments)
    puts <<~MESSAGE
      resultType: #{response.dig("result", "resultType")}
      Response: #{response.dig("result", "content", 0, "text")}
    MESSAGE

    response
  end

  # The modern lifecycle removed `initialize`, `ping`, `logging/setLevel`, and resource subscriptions (SEP-2575);
  # calling one is an error.
  def ping
    puts "=== Calling removed method: ping ==="
    @client.ping
  rescue MCP::Client::RequestHandlerError => e
    puts "ping was removed by the modern lifecycle (SEP-2575): #{e.message}"
  end

  def close
    # No session exists on a modern connection; this only clears local state.
    @transport.close
  end
end

puts <<~MESSAGE
  MCP Modern Lifecycle Client (2026-07-28)
  Make sure the server is running (ruby examples/modern_http_server.rb)
  #{"=" * 60}
MESSAGE

client = MCPModernHTTPClient.new

begin
  # Probe the server before adopting a lifecycle.
  client.discover

  # Answer the elicitation requests the server embeds in its results.
  client.register_elicitation_handler

  # Adopt the modern lifecycle.
  client.connect

  # List available tools.
  client.list_tools

  # Call a plain single round-trip tool.
  client.call_tool("greet", { name: "MCP" })

  # Call a multi round-trip tool (SEP-2322): the driver fulfills the embedded elicitation via the handler registered above
  # and re-issues the call with `inputResponses` plus the echoed `requestState`. Without a handler, `call_tool` raises
  # `MCP::Client::InputRequiredError` for manual driving via the `input_responses:` / `request_state:` keywords.
  client.call_tool("deploy", { app: "storefront" })

  # Call a method the modern lifecycle removed.
  client.ping
rescue => e
  puts <<~MESSAGE
    Error: #{e.message}
    #{e.backtrace.join("\n")}
  MESSAGE
ensure
  client.close
end
