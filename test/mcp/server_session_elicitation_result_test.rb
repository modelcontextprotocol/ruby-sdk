# frozen_string_literal: true

require "test_helper"

module MCP
  class ServerSessionElicitationResultTest < ActiveSupport::TestCase
    SCHEMA = {
      type: "object",
      properties: {
        replicas: { type: "integer", minimum: 1 },
        verbose: { type: "boolean" },
        environment: { type: "string", enum: ["staging", "production"] },
      },
      required: ["replicas", "verbose", "environment"],
      additionalProperties: false,
    }.freeze
    CONTENT = { replicas: 2, verbose: false, environment: "staging" }.freeze

    class ReplyTransport
      attr_accessor :reply

      def send_request(_method, _params = nil, **_kwargs)
        @reply
      end
    end

    setup do
      @server = Server.new(name: "elicitation_test")
      @transport = ReplyTransport.new
      @session = ServerSession.new(server: @server, transport: @transport)
      @session.store_client_info(client: { name: "test_client" }, capabilities: { elicitation: { form: {}, url: {} } })
    end

    test "accepted form content must match the requested types, required fields and enums" do
      invalid_contents = [
        CONTENT.merge(replicas: "lots"),
        CONTENT.merge(replicas: 1.5),
        CONTENT.merge(replicas: 0),
        CONTENT.merge(verbose: "false"),
        CONTENT.merge(environment: "unlisted"),
        CONTENT.reject { |key, _| key == :environment },
        CONTENT.merge(unexpected: true),
        false,
        0,
        "invalid",
        [],
      ]
      invalid_contents.each do |content|
        @transport.reply = { action: "accept", content: content }

        error = assert_raises(Server::ValidationError, content.inspect) { create_form }

        assert_match(/\AResponse validation failed: Invalid result:/, error.message)
      end
    end

    test "accepted form replies may omit content or return null even when properties are required" do
      replies = [
        { action: "accept" },
        { "action" => "accept" },
        { action: "accept", content: nil },
        { "action" => "accept", "content" => nil },
      ]
      replies.each do |reply|
        @transport.reply = reply

        assert_same(reply, create_form)
        assert_same(reply, create_form(schema: { type: "object", properties: {} }))
      end
    end

    test "accepted empty form content is checked against required properties" do
      @transport.reply = { action: "accept", content: {} }

      assert_raises(Server::ValidationError) { create_form }
      assert_same(@transport.reply, create_form(schema: { type: "object", properties: {} }))
    end

    test "a valid accepted form reply is returned unchanged" do
      @transport.reply = { action: "accept", content: CONTENT, _meta: { source: "test" } }

      assert_same(@transport.reply, create_form)
    end

    test "SEP-1330 enum builder content is accepted" do
      options = [{ value: "x", title: "X" }]
      schema = {
        type: "object",
        properties: {
          single: Elicitation::EnumSchema.untitled_single_select(values: ["x"]).to_h,
          titled_single: Elicitation::EnumSchema.titled_single_select(options: options).to_h,
          multi: Elicitation::EnumSchema.untitled_multi_select(values: ["x"]).to_h,
          titled_multi: Elicitation::EnumSchema.titled_multi_select(options: options).to_h,
        },
        required: ["single", "titled_single", "multi", "titled_multi"],
      }
      @transport.reply = { action: "accept", content: { single: "x", titled_single: "x", multi: ["x"], titled_multi: ["x"] } }

      assert_same(@transport.reply, create_form(schema: schema))
    end

    test "string-keyed schemas and replies are supported" do
      @transport.reply = { "action" => "accept", "content" => { "replicas" => 2, "verbose" => false, "environment" => "staging" } }
      schema = JSON.parse(JSON.generate(SCHEMA))

      assert_same(@transport.reply, create_form(schema: schema))
      @transport.reply["content"]["replicas"] = "lots"

      assert_raises(Server::ValidationError) { create_form(schema: schema) }
    end

    test "form and URL replies must be objects with a known action" do
      [nil, [], "accept", {}, { action: nil }, { action: 1 }, { action: "approve-everything" }].each do |reply|
        @transport.reply = reply

        [:create_form, :create_url].each do |request|
          error = assert_raises(Server::ValidationError, reply.inspect) { send(request) }

          detail = reply.is_a?(Hash) ? "invalid `action`" : "invalid `result`"
          assert_equal("Response validation failed: #{detail}", error.message)
        end
      end
    end

    test "transport errors are not converted to validation errors" do
      transport_error = Server::RequestTimeoutError.new("timed out", request_id: "el-1", timeout: 10)
      @transport.stubs(:send_request).raises(transport_error)

      assert_same(transport_error, assert_raises(Server::RequestTimeoutError) { create_form })
    end

    test "decline and cancel do not require or validate form content" do
      ["decline", "cancel"].each do |action|
        [{ action: action }, { action: action, content: { replicas: "ignored" } }].each do |reply|
          @transport.reply = reply

          assert_same(reply, create_form)
          assert_same(reply, create_url)
        end
      end
    end

    test "URL acceptance does not require form content" do
      @transport.reply = { action: "accept" }

      assert_same(@transport.reply, create_url)
    end

    test "fulfilling an embedded form request validates its accepted content" do
      @transport.reply = { action: "accept", content: CONTENT.merge(environment: "unlisted") }

      assert_raises(Server::ValidationError) do
        @session.fulfill_input_request(Methods::ELICITATION_CREATE, { requestedSchema: SCHEMA }, related_request_id: 1)
      end
    end

    test "fulfilling a string-keyed embedded form request validates its accepted content" do
      @transport.reply = { action: "accept", content: CONTENT.merge(replicas: "lots") }

      assert_raises(Server::ValidationError) do
        @session.fulfill_input_request(Methods::ELICITATION_CREATE, { "mode" => "form", "requestedSchema" => SCHEMA }, related_request_id: 1)
      end
    end

    test "fulfilling an embedded URL request validates its action" do
      @transport.reply = { action: "approve-everything" }

      assert_raises(Server::ValidationError) do
        @session.fulfill_input_request(Methods::ELICITATION_CREATE, { mode: "url" }, related_request_id: 1)
      end
    end

    test "fulfilling a valid embedded request returns its reply unchanged" do
      @transport.reply = { action: "accept", content: CONTENT }

      result = @session.fulfill_input_request(Methods::ELICITATION_CREATE, { mode: "form", requestedSchema: SCHEMA }, related_request_id: 1)

      assert_same(@transport.reply, result)
    end

    test "fulfilling other request methods does not validate them as elicitation results" do
      @transport.reply = { roots: [] }

      assert_same(@transport.reply, @session.fulfill_input_request(Methods::ROOTS_LIST, nil, related_request_id: 1))
    end

    test "the legacy shim does not replay invalid form content into the handler" do
      calls = 0
      delivered = nil
      @server.define_tool(name: "collect") do |server_context:|
        calls += 1
        if server_context.input_responses
          delivered = server_context.input_response("settings")
          Tool::Response.new([{ type: "text", text: "received" }])
        else
          Server::InputRequiredResult.new(
            input_requests: {
              "settings" => { method: Methods::ELICITATION_CREATE, params: { mode: "form", message: "Settings?", requestedSchema: SCHEMA } },
            },
          )
        end
      end
      @transport.reply = { action: "accept", content: CONTENT.merge(replicas: "lots") }

      response = @session.handle({ jsonrpc: "2.0", id: 1, method: Methods::TOOLS_CALL, params: { name: "collect", arguments: {} } })

      assert_equal(1, calls)
      assert_nil(delivered)
      assert_equal(JsonRpcHandler::ErrorCode::INTERNAL_ERROR, response.dig(:error, :code))
    end

    private

    def create_form(schema: SCHEMA)
      @session.create_form_elicitation(message: "Settings?", requested_schema: schema, related_request_id: 1)
    end

    def create_url
      @session.create_url_elicitation(message: "Authorize?", url: "https://example.com/authorize", elicitation_id: "el-1", related_request_id: 1)
    end
  end
end
