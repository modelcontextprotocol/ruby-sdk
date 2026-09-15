# frozen_string_literal: true

require "test_helper"
require "rack"
require "mcp/client/oauth/discovery"

module MCP
  class Server
    module Transports
      class StreamableHTTPTransportOAuthTest < ActiveSupport::TestCase
        include InitializeParamsTestHelper

        RESOURCE_METADATA_URL = "https://mcp.example.com/.well-known/oauth-protected-resource/mcp"

        class StubVerifier
          attr_reader :calls

          def initialize(tokens)
            @tokens = tokens
            @expired = []
            @calls = []
          end

          def expire(token)
            @expired << token
          end

          def verify(token)
            @calls << token
            raise OAuth::InvalidTokenError, "Token expired" if @expired.include?(token)

            @tokens[token]
          end
        end

        class ExplodingBody
          def read(*)
            raise "the request body must not be read before authentication"
          end
        end

        # A stream that records writes and whether it was closed.
        class TestStream
          def initialize
            @buffer = "".dup
            @closed = false
          end

          def write(data)
            raise IOError, "closed stream" if @closed

            @buffer << data
          end

          def flush
          end

          def close
            @closed = true
          end

          def closed?
            @closed
          end
        end

        setup do
          @server = Server.new(name: "oauth_test_server")
          @server.define_tool(name: "whoami") do |server_context:|
            subject = server_context.auth_info ? server_context.auth_info.subject.to_s : "anonymous"
            Tool::Response.new([{ type: "text", text: subject }])
          end

          @verifier = StubVerifier.new(
            "alice-token" => access_token("alice-token", subject: "alice", client_id: "client-a"),
            "bob-token" => access_token("bob-token", subject: "bob", client_id: "client-b"),
            "narrow-token" => access_token("narrow-token", subject: "alice", client_id: "client-a", scopes: ["other"]),
            "svc-a-token" => access_token("svc-a-token", subject: nil, client_id: "svc-a"),
            "svc-b-token" => access_token("svc-b-token", subject: nil, client_id: "svc-b"),
          )
          @transports = []
        end

        teardown do
          @transports.each(&:close)
        end

        test "legacy initialize without a token is rejected with a bare 401 challenge" do
          response = transport.handle_request(initialize_request)

          assert_equal 401, response[0]

          params = parse_challenge(response)

          refute params.key?("error")
          assert_equal RESOURCE_METADATA_URL, params["resource_metadata"]
          assert_equal "mcp:tools", params["scope"]
          assert_empty @verifier.calls
        end

        test "an unknown token is rejected with 401 invalid_token" do
          response = transport.handle_request(initialize_request(token: "unknown-token"))

          assert_equal 401, response[0]
          assert_equal "invalid_token", parse_challenge(response)["error"]
        end

        test "an expired token is rejected with 401" do
          @verifier.expire("alice-token")

          response = transport.handle_request(initialize_request(token: "alice-token"))

          assert_equal 401, response[0]
          assert_equal "Token expired", parse_challenge(response)["error_description"]
        end

        test "a token missing a required scope is rejected with 403 insufficient_scope" do
          response = transport.handle_request(initialize_request(token: "narrow-token"))

          assert_equal 403, response[0]

          params = parse_challenge(response)

          assert_equal "insufficient_scope", params["error"]
          assert_equal "mcp:tools", params["scope"]
          assert_equal RESOURCE_METADATA_URL, params["resource_metadata"]
        end

        test "a non-bearer authorization scheme is rejected with 400" do
          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => "Basic dXNlcjpwYXNz" },
            initialize_body,
          )

          response = transport.handle_request(request)

          assert_equal 400, response[0]
          assert_equal "invalid_request", parse_challenge(response)["error"]
        end

        test "a valid token initializes a session" do
          response = transport.handle_request(initialize_request(token: "alice-token"))

          assert_equal 200, response[0]
          assert response[1]["mcp-session-id"]
        end

        test "legacy GET and DELETE require a token" do
          the_transport = transport
          session_id = initialize_session(the_transport, token: "alice-token")

          unauthenticated_get = create_rack_request("GET", "/", { "HTTP_MCP_SESSION_ID" => session_id })

          assert_equal 401, the_transport.handle_request(unauthenticated_get)[0]

          authenticated_get = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id, "HTTP_AUTHORIZATION" => "Bearer alice-token" },
          )

          assert_equal 200, the_transport.handle_request(authenticated_get)[0]

          unauthenticated_delete = create_rack_request("DELETE", "/", { "HTTP_MCP_SESSION_ID" => session_id })

          assert_equal 401, the_transport.handle_request(unauthenticated_delete)[0]

          authenticated_delete = create_rack_request(
            "DELETE",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id, "HTTP_AUTHORIZATION" => "Bearer alice-token" },
          )

          assert_equal 200, the_transport.handle_request(authenticated_delete)[0]
        end

        test "the modern path requires a token and threads auth_info to the handler" do
          the_transport = transport

          unauthenticated = modern_rack_request(modern_body("tools/call", name: "whoami", arguments: {}))

          assert_equal 401, the_transport.handle_request(unauthenticated)[0]

          authenticated = modern_rack_request(
            modern_body("tools/call", name: "whoami", arguments: {}),
            headers: { "HTTP_AUTHORIZATION" => "Bearer alice-token" },
          )
          response = the_transport.handle_request(authenticated)

          assert_equal 200, response[0]
          assert_equal "alice", JSON.parse(response[2][0]).dig("result", "content", 0, "text")
        end

        test "subscriptions/listen requires a token" do
          body = modern_body("subscriptions/listen", toolsListChanged: true)

          response = transport.handle_request(modern_rack_request(body))

          assert_equal 401, response[0]
        end

        test "dns rebinding rejection precedes authentication" do
          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "HTTP_HOST" => "evil.example.com" },
            initialize_body,
          )

          response = transport.handle_request(request)

          assert_equal 403, response[0]
          refute response[1].key?("www-authenticate")
          assert_empty @verifier.calls
        end

        test "an unauthenticated request is rejected before the body is read" do
          env = {
            "REQUEST_METHOD" => "POST",
            "PATH_INFO" => "/",
            "CONTENT_TYPE" => "application/json",
            "HTTP_ACCEPT" => "application/json, text/event-stream",
            "rack.input" => ExplodingBody.new,
          }

          response = transport.handle_request(Rack::Request.new(env))

          assert_equal 401, response[0]
        end

        test "legacy POST threads auth_info to tool handlers in JSON response mode" do
          the_transport = transport(enable_json_response: true)
          session_id = initialize_session(the_transport, token: "alice-token")

          response = the_transport.handle_request(tool_call_request(session_id, token: "alice-token"))

          assert_equal 200, response[0]
          assert_equal "alice", JSON.parse(response[2][0]).dig("result", "content", 0, "text")
        end

        test "legacy POST threads auth_info to tool handlers on the SSE response stream" do
          the_transport = transport
          session_id = initialize_session(the_transport, token: "alice-token")

          response = the_transport.handle_request(tool_call_request(session_id, token: "alice-token"))

          assert_equal 200, response[0]

          io = StringIO.new
          response[2].call(io)
          body = JSON.parse(io.string.match(/^data: (.+)$/)[1])

          assert_equal "alice", body.dig("result", "content", 0, "text")
        end

        test "auth_info placed in the env by external middleware reaches handlers" do
          the_transport = transport_without_oauth(enable_json_response: true)
          session_id = initialize_session(the_transport)

          request = tool_call_request(session_id)
          request.env[OAuth::ENV_KEY] = access_token("external-token", subject: "external", client_id: "client-x")

          response = the_transport.handle_request(request)

          assert_equal "external", JSON.parse(response[2][0]).dig("result", "content", 0, "text")
        end

        test "a session is bound to the principal that initialized it" do
          the_transport = transport(enable_json_response: true)
          session_id = initialize_session(the_transport, token: "alice-token")

          assert_equal 404, the_transport.handle_request(ping_request(session_id, token: "bob-token"))[0]

          bob_get = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id, "HTTP_AUTHORIZATION" => "Bearer bob-token" },
          )

          assert_equal 404, the_transport.handle_request(bob_get)[0]

          bob_delete = create_rack_request(
            "DELETE",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id, "HTTP_AUTHORIZATION" => "Bearer bob-token" },
          )

          assert_equal 404, the_transport.handle_request(bob_delete)[0]
          assert_equal 200, the_transport.handle_request(ping_request(session_id, token: "alice-token"))[0]
        end

        test "the principal binding is not bypassed by a permissive session_request_validator" do
          the_transport = transport(
            enable_json_response: true,
            session_request_validator: ->(_request, _session_id) { true },
          )
          session_id = initialize_session(the_transport, token: "alice-token")

          assert_equal 404, the_transport.handle_request(ping_request(session_id, token: "bob-token"))[0]
        end

        test "client credentials sessions bind on client id" do
          the_transport = transport(enable_json_response: true)
          session_id = initialize_session(the_transport, token: "svc-a-token")

          assert_equal 404, the_transport.handle_request(ping_request(session_id, token: "svc-b-token"))[0]
          assert_equal 200, the_transport.handle_request(ping_request(session_id, token: "svc-a-token"))[0]
        end

        test "the principal binding includes the issuer" do
          @verifier = StubVerifier.new(
            "as1-token" => access_token(
              "as1-token",
              subject: "12345",
              client_id: "mcp-client",
              issuer: "https://as1.example.com",
            ),
            "as2-token" => access_token(
              "as2-token",
              subject: "12345",
              client_id: "mcp-client",
              issuer: "https://as2.example.com",
            ),
          )
          the_transport = transport(enable_json_response: true)
          session_id = initialize_session(the_transport, token: "as1-token")

          assert_equal 404, the_transport.handle_request(ping_request(session_id, token: "as2-token"))[0]
          assert_equal 200, the_transport.handle_request(ping_request(session_id, token: "as1-token"))[0]
        end

        test "a principal mismatch is indistinguishable from an unknown session" do
          the_transport = transport(enable_json_response: true)
          session_id = initialize_session(the_transport, token: "alice-token")

          mismatch = the_transport.handle_request(ping_request(session_id, token: "bob-token"))
          unknown = the_transport.handle_request(ping_request("no-such-session", token: "bob-token"))

          assert_equal 404, mismatch[0]
          assert_equal unknown[0], mismatch[0]
          assert_equal unknown[2], mismatch[2]
          refute mismatch[1].key?("www-authenticate")
        end

        test "a rejected GET does not refresh the idle timer of the session it targets" do
          the_transport = transport(enable_json_response: true, session_idle_timeout: 60)
          session_id = initialize_session(the_transport, token: "alice-token")
          last_active_before = the_transport.instance_variable_get(:@sessions)[session_id][:last_active_at]

          bob_get = create_rack_request(
            "GET",
            "/",
            { "HTTP_MCP_SESSION_ID" => session_id, "HTTP_AUTHORIZATION" => "Bearer bob-token" },
          )

          assert_equal 404, the_transport.handle_request(bob_get)[0]
          assert_equal last_active_before, the_transport.instance_variable_get(:@sessions)[session_id][:last_active_at]
        end

        test "stateless mode verifies every request independently" do
          the_transport = transport(stateless: true, enable_json_response: true)

          response = the_transport.handle_request(tool_call_request(nil, token: "alice-token"))

          assert_equal 200, response[0]
          assert_equal "alice", JSON.parse(response[2][0]).dig("result", "content", 0, "text")

          assert_equal 401, the_transport.handle_request(tool_call_request(nil))[0]
        end

        test "OPTIONS requests bypass authentication" do
          response = transport.handle_request(create_rack_request("OPTIONS", "/", {}))

          assert_equal 405, response[0]
          assert_empty @verifier.calls
        end

        test "a crashing verifier returns 500 without a challenge" do
          crashing_verifier = Object.new
          def crashing_verifier.verify(_token)
            raise "JWKS endpoint down"
          end

          reported = []
          MCP.stubs(:configuration).returns(
            MCP::Configuration.new(exception_reporter: ->(exception, context) { reported << [exception, context] }),
          )
          the_transport = transport(token_verifier: crashing_verifier)

          response = the_transport.handle_request(initialize_request(token: "alice-token"))

          assert_equal 500, response[0]
          refute response[1].key?("www-authenticate")
          assert_equal 1, reported.size
        end

        test "OAuth options without a verifier raise ArgumentError" do
          error = assert_raises(ArgumentError) do
            StreamableHTTPTransport.new(@server, required_scopes: ["mcp:tools"])
          end

          assert_includes error.message, "require token_verifier"
        end

        test "an expired token is rejected on the next request even within a live session" do
          the_transport = transport(enable_json_response: true)
          session_id = initialize_session(the_transport, token: "alice-token")

          @verifier.expire("alice-token")

          assert_equal 401, the_transport.handle_request(ping_request(session_id, token: "alice-token"))[0]
        end

        test "require_scopes! failures surface as JSON-RPC errors naming the scopes" do
          @server.define_tool(name: "admin_tool") do |server_context:|
            server_context.require_scopes!("mcp:admin")
            Tool::Response.new([{ type: "text", text: "ok" }])
          end
          the_transport = transport(enable_json_response: true)
          session_id = initialize_session(the_transport, token: "alice-token")

          body = {
            jsonrpc: "2.0",
            method: "tools/call",
            id: "admin-1",
            params: { name: "admin_tool", arguments: {} },
          }.to_json
          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
              "HTTP_AUTHORIZATION" => "Bearer alice-token",
            },
            body,
          )

          response = the_transport.handle_request(request)

          assert_equal 200, response[0]

          parsed = JSON.parse(response[2][0])

          assert_equal(-32600, parsed.dig("error", "code"))
          assert_equal "Token is missing required scopes: mcp:admin", parsed.dig("error", "data")
        end

        test "require_scopes! applies the transport's scope_matcher, so a broader scope satisfies handlers too" do
          @server.define_tool(name: "admin_tool") do |server_context:|
            server_context.require_scopes!("mcp:admin")
            Tool::Response.new([{ type: "text", text: "ok" }])
          end
          @verifier = StubVerifier.new(
            "root-token" => access_token("root-token", subject: "root", client_id: "client-r", scopes: ["mcp:all"]),
          )
          matcher = ->(required, granted) { granted.include?("mcp:all") || granted.include?(required) }
          the_transport = transport(enable_json_response: true, scope_matcher: matcher)
          session_id = initialize_session(the_transport, token: "root-token")

          body = {
            jsonrpc: "2.0",
            method: "tools/call",
            id: "admin-1",
            params: { name: "admin_tool", arguments: {} },
          }.to_json
          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
              "HTTP_AUTHORIZATION" => "Bearer root-token",
            },
            body,
          )

          response = the_transport.handle_request(request)

          assert_equal 200, response[0]

          parsed = JSON.parse(response[2][0])

          refute parsed.key?("error")
          assert_equal "ok", parsed.dig("result", "content", 0, "text")
        end

        test "a custom OAuth::Error from the verifier answers 401 instead of escaping the transport" do
          custom_error = Class.new(OAuth::Error) do
            def initialize(message = "rejected by policy")
              super(message, error_code: "custom_rejection")
            end
          end
          raising_verifier = Object.new
          raising_verifier.define_singleton_method(:verify) { |_token| raise custom_error }
          the_transport = transport(token_verifier: raising_verifier)

          response = the_transport.handle_request(initialize_request(token: "any-token"))

          assert_equal 401, response[0]
          assert_equal "invalid_token", parse_challenge(response)["error"]
        end

        test "an Authorization header with invalid UTF-8 bytes answers 401, not 500" do
          the_transport = transport
          header = "Bearer alice\xFFtoken".dup.force_encoding(Encoding::UTF_8)
          request = create_rack_request(
            "POST",
            "/",
            { "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => header },
            initialize_body,
          )

          response = the_transport.handle_request(request)

          assert_equal 401, response[0]
          assert_equal "invalid_token", parse_challenge(response)["error"]
        end

        test "a Middleware-wrapped transport carries the scope_matcher into require_scopes!" do
          @server.define_tool(name: "admin_tool") do |server_context:|
            server_context.require_scopes!("mcp:admin")
            Tool::Response.new([{ type: "text", text: "ok" }])
          end
          @verifier = StubVerifier.new(
            "root-token" => access_token("root-token", subject: "root", client_id: "client-r", scopes: ["mcp:all"]),
          )
          matcher = ->(required, granted) { granted.include?("mcp:all") || granted.include?(required) }
          app = OAuth::Middleware.new(
            transport_without_oauth(enable_json_response: true),
            token_verifier: @verifier,
            required_scopes: ["mcp:tools"],
            resource_metadata_url: RESOURCE_METADATA_URL,
            scope_matcher: matcher,
          )

          init_response = app.call(initialize_request(token: "root-token").env)

          assert_equal 200, init_response[0]

          session_id = init_response[1]["mcp-session-id"]
          body = {
            jsonrpc: "2.0",
            method: "tools/call",
            id: "admin-1",
            params: { name: "admin_tool", arguments: {} },
          }.to_json
          request = create_rack_request(
            "POST",
            "/",
            {
              "CONTENT_TYPE" => "application/json",
              "HTTP_MCP_SESSION_ID" => session_id,
              "HTTP_AUTHORIZATION" => "Bearer root-token",
            },
            body,
          )

          response = app.call(request.env)

          assert_equal 200, response[0]

          parsed = JSON.parse(response[2][0])

          refute parsed.key?("error")
          assert_equal "ok", parsed.dig("result", "content", 0, "text")
        end

        test "a GET stream is closed once the token that opened it expires, and the session survives" do
          expired = Time.now.to_i - 1
          @verifier = StubVerifier.new(
            "stale-token" => access_token("stale-token", subject: "alice", client_id: "client-a", expires_at: expired),
            "fresh-token" => access_token("fresh-token", subject: "alice", client_id: "client-a"),
          )
          the_transport = transport
          session_id = initialize_session(the_transport, token: "fresh-token")

          response = the_transport.handle_request(get_request(session_id, token: "stale-token"))

          assert_equal 200, response[0]

          stream = TestStream.new
          response[2].call(stream)

          assert wait_until { stream.closed? }, "the stream was not closed after its token expired"

          # The session is intact: its requests are verified on their own, and the stream can be reopened.
          assert_equal 200, the_transport.handle_request(ping_request(session_id, token: "fresh-token"))[0]
          assert_equal 200, the_transport.handle_request(get_request(session_id, token: "fresh-token"))[0]
        end

        test "a GET stream stays open while its token is valid" do
          the_transport = transport
          session_id = initialize_session(the_transport, token: "alice-token")

          response = the_transport.handle_request(get_request(session_id, token: "alice-token"))
          stream = TestStream.new
          response[2].call(stream)

          refute wait_until(timeout: 0.1) { stream.closed? }, "the stream was closed although its token is valid"
        end

        test "a subscriptions/listen stream is closed at the keepalive once its token expires" do
          expired = Time.now.to_i - 1
          @verifier = StubVerifier.new(
            "stale-token" => access_token("stale-token", subject: "alice", client_id: "client-a", expires_at: expired),
          )
          the_transport = transport(listen_keepalive_interval: 0.01)

          response = the_transport.handle_request(modern_rack_request(
            modern_body("subscriptions/listen", { notifications: { toolsListChanged: true } }),
            headers: { "HTTP_AUTHORIZATION" => "Bearer stale-token" },
          ))

          assert_equal 200, response[0]

          stream = TestStream.new
          response[2].call(stream)

          assert wait_until { stream.closed? }, "the listen stream was not closed after its token expired"
        end

        test "a token without an expiry still bounds the stream by max_stream_lifetime" do
          # `exp` is optional in an RFC 7662 introspection response, so without the cap such a stream would
          # outlive every later token check.
          token = access_token("no-exp", subject: "alice", client_id: "client-a")
          the_transport = transport(max_stream_lifetime: 60)

          deadline = the_transport.send(:stream_token_expiry, token)

          assert_in_delta(Time.now.to_i + 60, deadline, 1)
        end

        test "the token expiry wins when it comes before max_stream_lifetime" do
          expires_at = Time.now.to_i + 5
          token = access_token("short", subject: "alice", client_id: "client-a", expires_at: expires_at)
          the_transport = transport(max_stream_lifetime: 3600)

          assert_equal(expires_at, the_transport.send(:stream_token_expiry, token))
        end

        test "max_stream_lifetime nil leaves an expiry-less token unbounded" do
          token = access_token("no-exp", subject: "alice", client_id: "client-a")
          the_transport = transport(max_stream_lifetime: nil)

          assert_nil(the_transport.send(:stream_token_expiry, token))
        end

        test "a stream opened without a token is never capped" do
          the_transport = transport(max_stream_lifetime: 60)

          assert_nil(the_transport.send(:stream_token_expiry, nil))
        end

        test "max_stream_lifetime must be a positive number or nil" do
          assert_raises(ArgumentError) { transport(max_stream_lifetime: 0) }
          assert_raises(ArgumentError) { transport(max_stream_lifetime: -1) }
        end

        test "an expiry that is not a number is ignored while the stream is set up, leaving the cap" do
          # A custom verifier breaking the `AccessToken` contract must not raise on the request path.
          token = access_token("bad-exp", subject: "alice", client_id: "client-a", expires_at: "1234")
          the_transport = transport(max_stream_lifetime: 60)

          deadline = the_transport.send(:stream_token_expiry, token)

          assert_in_delta(Time.now.to_i + 60, deadline, 1)
        end

        private

        def access_token(token, subject:, client_id:, scopes: ["mcp:tools"], expires_at: nil, issuer: nil)
          OAuth::AccessToken.new(
            token: token,
            subject: subject,
            client_id: client_id,
            scopes: scopes,
            expires_at: expires_at,
            issuer: issuer,
          )
        end

        def get_request(session_id, token:)
          create_rack_request(
            "GET",
            "/",
            {
              "HTTP_ACCEPT" => "text/event-stream",
              "HTTP_MCP_SESSION_ID" => session_id,
              "HTTP_AUTHORIZATION" => "Bearer #{token}",
            },
          )
        end

        # Polls the block until it is truthy or the timeout elapses; returns the final outcome.
        def wait_until(timeout: 2)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          loop do
            return true if yield
            return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

            sleep(0.005)
          end
        end

        def transport(**options)
          defaults = {
            listen_keepalive_interval: nil,
            token_verifier: @verifier,
            required_scopes: ["mcp:tools"],
            resource_metadata_url: RESOURCE_METADATA_URL,
          }
          built = StreamableHTTPTransport.new(@server, **defaults.merge(options))
          @transports << built
          built
        end

        def transport_without_oauth(**options)
          built = StreamableHTTPTransport.new(@server, listen_keepalive_interval: nil, **options)
          @transports << built
          built
        end

        def initialize_body
          { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json
        end

        def initialize_request(token: nil)
          headers = { "CONTENT_TYPE" => "application/json" }
          headers["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
          create_rack_request("POST", "/", headers, initialize_body)
        end

        def initialize_session(the_transport, token: nil)
          response = the_transport.handle_request(initialize_request(token: token))

          assert_equal 200, response[0]

          response[1]["mcp-session-id"]
        end

        def tool_call_request(session_id, token: nil)
          headers = { "CONTENT_TYPE" => "application/json" }
          headers["HTTP_MCP_SESSION_ID"] = session_id if session_id
          headers["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
          body = {
            jsonrpc: "2.0",
            method: "tools/call",
            id: "call-1",
            params: { name: "whoami", arguments: {} },
          }.to_json
          create_rack_request("POST", "/", headers, body)
        end

        def ping_request(session_id, token: nil)
          headers = { "CONTENT_TYPE" => "application/json", "HTTP_MCP_SESSION_ID" => session_id }
          headers["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
          create_rack_request("POST", "/", headers, { jsonrpc: "2.0", method: "ping", id: "ping-1" }.to_json)
        end

        def modern_body(method, params)
          {
            jsonrpc: "2.0",
            method: method,
            id: 1,
            params: params.merge(
              _meta: {
                "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                "io.modelcontextprotocol/clientCapabilities": {},
              },
            ),
          }.to_json
        end

        def modern_rack_request(body_json, headers: {})
          parsed = JSON.parse(body_json)
          env_headers = {
            "CONTENT_TYPE" => "application/json",
            "HTTP_MCP_PROTOCOL_VERSION" => "2026-07-28",
            "HTTP_MCP_METHOD" => parsed["method"],
          }
          name = parsed.dig("params", "name") || parsed.dig("params", "uri")
          env_headers["HTTP_MCP_NAME"] = name if name
          create_rack_request("POST", "/", env_headers.merge(headers), body_json)
        end

        def parse_challenge(response)
          MCP::Client::OAuth::Discovery.parse_www_authenticate(response[1]["www-authenticate"])
        end

        def create_rack_request(method, path, headers, body = nil)
          default_accept = case method
          when "POST"
            { "HTTP_ACCEPT" => "application/json, text/event-stream" }
          when "GET"
            { "HTTP_ACCEPT" => "text/event-stream" }
          else
            {}
          end

          env = {
            "REQUEST_METHOD" => method,
            "PATH_INFO" => path,
            "rack.input" => StringIO.new(body.to_s),
          }.merge(default_accept).merge(headers)

          Rack::Request.new(env)
        end
      end
    end
  end
end
