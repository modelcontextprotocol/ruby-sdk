# frozen_string_literal: true

require "test_helper"
require "rack"

module MCP
  class Server
    module Transports
      # The server side of SEP-2243 custom headers: the `Mcp-Param-*` headers of a modern `tools/call` are checked
      # against the body before the tool runs.
      class StreamableHTTPMcpParamTest < ActiveSupport::TestCase
        include InitializeParamsTestHelper

        setup do
          @server = Server.new(name: "test_server", tools: [], prompts: [], resources: [])
          @server.define_tool(
            name: "regional",
            input_schema: {
              properties: {
                region: { type: "string", "x-mcp-header": "Region" },
                priority: { type: "integer", "x-mcp-header": "Priority" },
                verbose: { type: "boolean", "x-mcp-header": "Verbose" },
                options: { type: "object", properties: { zone: { type: "string", "x-mcp-header": "Zone" } } },
              },
            },
          ) do |**args|
            seen = [args[:region], args[:priority], args[:verbose], args[:options]&.dig(:zone)]
            Tool::Response.new([{ type: "text", text: seen.inspect }])
          end
          @transport = StreamableHTTPTransport.new(@server, listen_keepalive_interval: nil)
        end

        teardown do
          @transport.close
        end

        test "a header agreeing with the body passes and the tool runs with the body value" do
          response = call_tool({ region: "us-west1" }, { "HTTP_MCP_PARAM_REGION" => "us-west1" })

          assert_equal '["us-west1", nil, nil, nil]', result_text(response)
        end

        test "a Base64 sentinel header is decoded before the comparison" do
          response = call_tool({ region: " padded " }, { "HTTP_MCP_PARAM_REGION" => "=?base64?IHBhZGRlZCA=?=" })

          assert_equal '[" padded ", nil, nil, nil]', result_text(response)
        end

        test "a header disagreeing with the body is refused without echoing either value" do
          response = call_tool({ region: "us-west1" }, { "HTTP_MCP_PARAM_REGION" => "us-east1" })

          assert_header_mismatch response, "Mcp-Param-Region header does not match the `region` argument"
          refute_includes response[2][0], "us-west1"
          refute_includes response[2][0], "us-east1"
        end

        test "a body value without its header is refused" do
          response = call_tool({ region: "us-west1" }, {})

          assert_header_mismatch response, "Mcp-Param-Region header is missing but the request body carries a `region` argument"
        end

        test "a header whose argument is null or absent in the body is refused" do
          absent = call_tool({}, { "HTTP_MCP_PARAM_REGION" => "us-west1" })
          null = call_tool({ region: nil }, { "HTTP_MCP_PARAM_REGION" => "us-west1" })

          [absent, null].each do |response|
            assert_header_mismatch response, "Mcp-Param-Region header is present but the request body carries no `region` argument"
          end
        end

        test "malformed Base64 sentinels are refused" do
          ["=?base64?SGVsbG8?=", "=?base64?SGVs!!!bG8=?=", "=?base64?SGVsbG9=?=", "=?base64?/w==?="].each do |value|
            response = call_tool({ region: "Hello" }, { "HTTP_MCP_PARAM_REGION" => value })

            assert_header_mismatch response, "Mcp-Param-Region header carries a malformed Base64 value"
          end
        end

        test "values without the full sentinel are taken literally" do
          { "SGVsbG8=" => "SGVsbG8=", "=?base64?SGVsbG8=" => "=?base64?SGVsbG8=", "=?base64?=" => "=?base64?=" }.each do |header, body|
            response = call_tool({ region: body }, { "HTTP_MCP_PARAM_REGION" => header })

            assert_equal "[#{body.inspect}, nil, nil, nil]", result_text(response)
          end
        end

        test "a header holding a byte outside the field-value set is refused even when it equals the body" do
          non_ascii = (+"caf\xC3\xA9").force_encoding(Encoding::UTF_8)

          { non_ascii => non_ascii, non_ascii.b => non_ascii, "a\x01b" => "a\x01b" }.each do |header, body|
            response = call_tool({ region: body }, { "HTTP_MCP_PARAM_REGION" => header })

            assert_header_mismatch response, "Mcp-Param-Region header holds a character that is not allowed in a field value"
          end
        end

        test "two declarations that fold onto one Rack key must both agree with that key" do
          @server.define_tool(
            name: "folded",
            input_schema: {
              properties: {
                a: { type: "string", "x-mcp-header": "Region-A" },
                b: { type: "string", "x-mcp-header": "Region_A" },
              },
            },
          ) do |**args|
            Tool::Response.new([{ type: "text", text: [args[:a], args[:b]].inspect }])
          end

          response = call_tool({ a: "x", b: "x" }, { "HTTP_MCP_PARAM_REGION_A" => "x" }, name: "folded")

          assert_equal '["x", "x"]', result_text(response)

          response = call_tool({ a: "x", b: "y" }, { "HTTP_MCP_PARAM_REGION_A" => "x" }, name: "folded")

          assert_header_mismatch response, "Mcp-Param-Region_A header does not match the `b` argument"
        end

        test "integer and boolean parameters compare by their header rendering" do
          assert_equal '[nil, 42, nil, nil]', result_text(call_tool({ priority: 42 }, { "HTTP_MCP_PARAM_PRIORITY" => "42" }))
          assert_equal '[nil, 42, nil, nil]', result_text(call_tool({ priority: 42 }, { "HTTP_MCP_PARAM_PRIORITY" => "42.0" }))
          assert_equal '[nil, nil, true, nil]', result_text(call_tool({ verbose: true }, { "HTTP_MCP_PARAM_VERBOSE" => "true" }))

          assert_header_mismatch(
            call_tool({ priority: 42 }, { "HTTP_MCP_PARAM_PRIORITY" => "43" }),
            "Mcp-Param-Priority header does not match the `priority` argument",
          )
          assert_header_mismatch(
            call_tool({ verbose: true }, { "HTTP_MCP_PARAM_VERBOSE" => "True" }),
            "Mcp-Param-Verbose header does not match the `verbose` argument",
          )
        end

        test "a nested declaration reads the value at its property path" do
          response = call_tool({ options: { zone: "b" } }, { "HTTP_MCP_PARAM_ZONE" => "b" })

          assert_equal '[nil, nil, nil, "b"]', result_text(response)

          response = call_tool({ options: { zone: "b" } }, { "HTTP_MCP_PARAM_ZONE" => "c" })

          assert_header_mismatch response, "Mcp-Param-Zone header does not match the `options.zone` argument"
        end

        test "headers for parameters without a declaration are ignored" do
          response = call_tool({ region: "us-west1" }, { "HTTP_MCP_PARAM_REGION" => "us-west1", "HTTP_MCP_PARAM_OTHER" => "x" })

          assert_equal '["us-west1", nil, nil, nil]', result_text(response)
        end

        test "a tool whose declarations are invalid is not validated" do
          @server.define_tool(
            name: "dup",
            input_schema: {
              properties: {
                a: { type: "string", "x-mcp-header": "Same" },
                b: { type: "string", "x-mcp-header": "same" },
              },
            },
          ) do |**args|
            Tool::Response.new([{ type: "text", text: args[:a].to_s }])
          end

          response = call_tool({ a: "one" }, { "HTTP_MCP_PARAM_SAME" => "two" }, name: "dup")

          assert_equal "one", result_text(response)
        end

        test "an unknown tool is left to the dispatcher" do
          response = call_tool({ region: "x" }, { "HTTP_MCP_PARAM_REGION" => "y" }, name: "nope")

          assert_equal 400, response[0]
          assert_equal JsonRpcHandler::ErrorCode::INVALID_PARAMS, JSON.parse(response[2][0]).dig("error", "code")
        end

        test "the handshake lifecycle has no custom headers to check" do
          init_request = create_rack_request(
            "POST",
            { "CONTENT_TYPE" => "application/json" },
            { jsonrpc: "2.0", method: "initialize", id: "init", params: initialize_params }.to_json,
          )
          session_id = @transport.handle_request(init_request)[1]["mcp-session-id"]

          response = @transport.handle_request(create_rack_request(
            "POST",
            { "CONTENT_TYPE" => "application/json", "HTTP_MCP_SESSION_ID" => session_id, "HTTP_MCP_PARAM_REGION" => "us-east1" },
            { jsonrpc: "2.0", id: 7, method: "tools/call", params: { name: "regional", arguments: { region: "us-west1" } } }.to_json,
          ))

          assert_equal 200, response[0]
          assert_equal "text/event-stream", response[1]["content-type"]
          io = StringIO.new
          response[2].call(io)
          assert_includes io.string, '[\"us-west1\", nil, nil, nil]'
        end

        test "tools/list advertises the x-mcp-header annotations the server validates against" do
          body = { jsonrpc: "2.0", id: 1, method: "tools/list", params: { _meta: envelope } }.to_json
          response = @transport.handle_request(create_rack_request(
            "POST",
            { "CONTENT_TYPE" => "application/json", "HTTP_MCP_PROTOCOL_VERSION" => "2026-07-28", "HTTP_MCP_METHOD" => "tools/list" },
            body,
          ))

          assert_equal 200, response[0]
          tool = JSON.parse(response[2][0]).dig("result", "tools").find { |entry| entry["name"] == "regional" }
          assert_equal "Region", tool.dig("inputSchema", "properties", "region", "x-mcp-header")
          assert_equal "Zone", tool.dig("inputSchema", "properties", "options", "properties", "zone", "x-mcp-header")
        end

        private

        def call_tool(arguments, headers, name: "regional")
          body = {
            jsonrpc: "2.0",
            id: 7,
            method: "tools/call",
            params: { name: name, arguments: arguments, _meta: envelope },
          }.to_json
          base = {
            "CONTENT_TYPE" => "application/json",
            "HTTP_MCP_PROTOCOL_VERSION" => "2026-07-28",
            "HTTP_MCP_METHOD" => "tools/call",
            "HTTP_MCP_NAME" => name,
          }

          @transport.handle_request(create_rack_request("POST", base.merge(headers), body))
        end

        def envelope
          {
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientInfo": { name: "modern_client", version: "2.0" },
            "io.modelcontextprotocol/clientCapabilities": {},
          }
        end

        def result_text(response)
          assert_equal 200, response[0]
          assert_equal "application/json", response[1]["content-type"]

          JSON.parse(response[2][0]).dig("result", "content", 0, "text")
        end

        def assert_header_mismatch(response, message)
          assert_equal 400, response[0]
          body = JSON.parse(response[2][0])
          assert_equal ErrorCodes::HEADER_MISMATCH, body.dig("error", "code")
          assert_equal "Header mismatch: #{message}", body.dig("error", "message")
          assert_equal 7, body["id"]
        end

        def create_rack_request(method, headers, body)
          env = {
            "REQUEST_METHOD" => method,
            "PATH_INFO" => "/",
            "HTTP_ACCEPT" => "application/json, text/event-stream",
            "rack.input" => StringIO.new(body.to_s),
          }.merge(headers)

          Rack::Request.new(env)
        end
      end
    end
  end
end
