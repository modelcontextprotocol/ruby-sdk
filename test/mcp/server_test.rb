# frozen_string_literal: true

require "test_helper"

module MCP
  class ServerTest < ActiveSupport::TestCase
    include InstrumentationTestHelper
    setup do
      @tool = Tool.define(
        name: "test_tool",
        title: "Test tool",
        description: "A test tool",
        meta: { foo: "bar" },
      )

      @tool_that_raises = Tool.define(
        name: "tool_that_raises",
        title: "Tool that raises",
        description: "A tool that raises",
        input_schema: { type: "object", properties: { message: { type: "string" } }, required: ["message"] },
      ) { raise StandardError, "Tool error" }

      @tool_with_no_args = Tool.define(
        name: "tool_with_no_args",
        title: "Tool with no args",
        description: "This tool performs specific functionality...",
        annotations: {
          read_only_hint: true,
        },
      ) do
        Tool::Response.new([{ type: "text", content: "OK" }])
      end

      @prompt = Prompt.define(
        name: "test_prompt",
        title: "Test Prompt",
        description: "Test prompt",
        arguments: [
          Prompt::Argument.new(name: "test_argument", description: "Test argument", required: true),
        ],
      ) do
        Prompt::Result.new(
          description: "Hello, world!",
          messages: [
            Prompt::Message.new(role: "user", content: Content::Text.new("Hello, world!")),
          ],
        )
      end

      @resource = Resource.new(
        uri: "https://test_resource.invalid",
        name: "test-resource",
        title: "Test Resource",
        description: "Test resource",
        icons: [{ mimeType: "image/png", sizes: ["48x48", "96x96"], src: "https://example.com", theme: "light" }],
        mime_type: "text/plain",
      )

      @resource_template = ResourceTemplate.new(
        uri_template: "https://test_resource.invalid/{id}",
        name: "test-resource",
        title: "Test Resource",
        description: "Test resource",
        icons: [{ mimeType: "image/png", sizes: ["48x48", "96x96"], src: "https://example.com", theme: "light" }],
        mime_type: "text/plain",
      )

      @server_name = "test_server"
      configuration = MCP::Configuration.new
      configuration.instrumentation_callback = instrumentation_helper.callback

      @server = Server.new(
        description: "Test server",
        icons: [{ mimeType: "image/png", sizes: ["48x48", "96x96"], src: "https://example.com", theme: "light" }],
        name: @server_name,
        title: "Example Server Display Name",
        version: "1.2.3",
        instructions: "Optional instructions for the client",
        tools: [@tool, @tool_that_raises],
        prompts: [@prompt],
        resources: [@resource],
        resource_templates: [@resource_template],
        configuration: configuration,
      )
    end

    # https://modelcontextprotocol.io/specification/latest/basic/utilities/ping#behavior-requirements
    test "#handle ping request returns empty response" do
      request = {
        jsonrpc: "2.0",
        method: "ping",
        id: "123",
      }

      response = @server.handle(request)
      assert_equal(
        {
          jsonrpc: "2.0",
          id: "123",
          result: {},
        },
        response,
      )
      assert_instrumentation_data({ method: "ping" })
    end

    test "#handle_json ping request returns empty response" do
      request = JSON.generate({
        jsonrpc: "2.0",
        method: "ping",
        id: "123",
      })

      response = JSON.parse(@server.handle_json(request), symbolize_names: true)
      assert_equal(
        {
          jsonrpc: "2.0",
          id: "123",
          result: {},
        },
        response,
      )
      assert_instrumentation_data({ method: "ping" })
    end

    test "#handle initialize request returns protocol info, server info, and capabilities" do
      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
      }

      response = @server.handle(request)
      refute_nil response

      expected_result = {
        jsonrpc: "2.0",
        id: 1,
        result: {
          protocolVersion: Configuration::LATEST_STABLE_PROTOCOL_VERSION,
          capabilities: {
            prompts: { listChanged: true },
            resources: { listChanged: true },
            tools: { listChanged: true },
            logging: {},
          },
          serverInfo: {
            description: "Test server",
            icons: [{ mimeType: "image/png", sizes: ["48x48", "96x96"], src: "https://example.com", theme: "light" }],
            name: @server_name,
            title: "Example Server Display Name",
            version: "1.2.3",
          },
          instructions: "Optional instructions for the client",
        },
      }

      assert_equal expected_result, response
      assert_instrumentation_data({ method: "initialize" })
    end

    test "#handle initialize request with clientInfo includes client in instrumentation data" do
      client_info = { name: "test_client", version: "1.0.0" }
      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: {
          clientInfo: client_info,
        },
      }

      @server.handle(request)
      assert_instrumentation_data({ method: "initialize", client: client_info })
    end

    test "instrumentation data includes client info for subsequent requests after initialize" do
      client_info = { name: "test_client", version: "1.0.0" }
      initialize_request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: {
          clientInfo: client_info,
        },
      }
      @server.handle(initialize_request)

      ping_request = {
        jsonrpc: "2.0",
        method: "ping",
        id: 2,
      }
      @server.handle(ping_request)
      assert_instrumentation_data({ method: "ping", client: client_info })
    end

    test "instrumentation data does not include client key when no clientInfo provided" do
      request = {
        jsonrpc: "2.0",
        method: "ping",
        id: 1,
      }

      @server.handle(request)
      assert_instrumentation_data({ method: "ping" })
    end

    test "unsupported method instrumentation includes client from session" do
      session = ServerSession.new(server: @server, transport: mock)
      session.store_client_info(client: { name: "session-client", version: "1.0" })

      request = {
        jsonrpc: "2.0",
        method: "does/not/exist",
        id: 1,
      }

      @server.handle(request, session: session)
      assert_instrumentation_data({ method: "unsupported_method", client: { name: "session-client", version: "1.0" } })
    end

    test "#handle returns nil for notification requests" do
      request = {
        jsonrpc: "2.0",
        method: "some_notification",
      }

      assert_nil @server.handle(request)
      assert_instrumentation_data({ method: "unsupported_method" })
    end

    test "#handle notifications/initialized returns nil response" do
      request = {
        jsonrpc: "2.0",
        method: "notifications/initialized",
      }

      assert_nil @server.handle(request)
      assert_instrumentation_data({ method: "notifications/initialized" })
    end

    test "#handle_json notifications/initialized returns nil response" do
      request = JSON.generate({
        jsonrpc: "2.0",
        method: "notifications/initialized",
      })

      assert_nil @server.handle_json(request)
      assert_instrumentation_data({ method: "notifications/initialized" })
    end

    test "#handle tools/list returns available tools" do
      request = {
        jsonrpc: "2.0",
        method: "tools/list",
        id: 1,
      }

      response = @server.handle(request)
      result = response[:result]
      assert_kind_of Array, result[:tools]
      assert_equal "test_tool", result[:tools][0][:name]
      assert_equal "Test tool", result[:tools][0][:title]
      assert_equal "A test tool", result[:tools][0][:description]
      assert_equal({ type: "object" }, result[:tools][0][:inputSchema])
      assert_equal({ foo: "bar" }, result[:tools][0][:_meta])
      assert_instrumentation_data({ method: "tools/list" })
    end

    test "#handle_json tools/list returns available tools" do
      request = JSON.generate({
        jsonrpc: "2.0",
        method: "tools/list",
        id: 1,
      })

      response = JSON.parse(@server.handle_json(request), symbolize_names: true)
      result = response[:result]
      assert_kind_of Array, result[:tools]
      assert_equal "test_tool", result[:tools][0][:name]
      assert_equal "Test tool", result[:tools][0][:title]
      assert_equal "A test tool", result[:tools][0][:description]
      assert_equal({ foo: "bar" }, result[:tools][0][:_meta])
    end

    test "#handle tools/call executes tool and returns result" do
      tool_name = "test_tool"
      tool_args = { arg: "value" }
      tool_response = Tool::Response.new([{ result: "success" }])

      if RUBY_VERSION >= "3.1"
        # Ruby 3.1+: Mocha stub preserves `method.parameters` info.
        @tool.expects(:call).with(arg: "value", server_context: is_a(ServerContext)).returns(tool_response)
      else
        # Ruby 3.0: Mocha stub changes `method.parameters`, so `accepts_server_context?` returns false.
        @tool.expects(:call).with(arg: "value").returns(tool_response)
      end

      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: {
          name: tool_name,
          arguments: tool_args,
        },
        id: 1,
      }

      response = @server.handle(request)
      assert_equal tool_response.to_h, response[:result]
      assert_instrumentation_data({ method: "tools/call", tool_name: tool_name, tool_arguments: tool_args })
    end

    test "#handle tools/call returns protocol error in JSON-RPC format if required tool arguments are missing" do
      tool_with_required_argument = Tool.define(
        name: "test_tool",
        title: "Test tool",
        description: "A test tool",
        input_schema: { properties: { message: { type: "string" } }, required: ["message"] },
      ) do |message: nil|
        Tool::Response.new("success #{message}")
      end

      server = Server.new(
        name: "test_server",
        tools: [tool_with_required_argument],
      )

      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: "test_tool", arguments: {} },
        id: 1,
      }

      response = server.handle(request)

      assert_nil response[:result]
      assert_equal(-32602, response[:error][:code])
      assert_equal "Invalid params", response[:error][:message]
      assert_includes response[:error][:data], "Missing required arguments: message"
    end

    test "#handle_json tools/call executes tool and returns result" do
      tool_name = "test_tool"
      tool_args = { arg: "value" }
      tool_response = Tool::Response.new([{ result: "success" }])

      if RUBY_VERSION >= "3.1"
        # Ruby 3.1+: Mocha stub preserves `method.parameters` info.
        @tool.expects(:call).with(arg: "value", server_context: is_a(ServerContext)).returns(tool_response)
      else
        # Ruby 3.0: Mocha stub changes `method.parameters`, so `accepts_server_context?` returns false.
        @tool.expects(:call).with(arg: "value").returns(tool_response)
      end

      request = JSON.generate({
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: tool_name, arguments: tool_args },
        id: 1,
      })

      raw_response = @server.handle_json(request)
      response = JSON.parse(raw_response, symbolize_names: true) if raw_response
      assert_equal tool_response.to_h, response[:result] if response
      assert_instrumentation_data({ method: "tools/call", tool_name: tool_name, tool_arguments: { arg: "value" } })
    end

    test "#handle_json tools/call executes tool and returns result, when the tool is typed with Sorbet" do
      skip "Sorbet is not available" unless defined?(T::Sig)

      class TypedTestTool < Tool
        tool_name "test_tool"
        description "a test tool for testing"
        input_schema({ properties: { message: { type: "string" } }, required: ["message"] })

        class << self
          extend T::Sig

          sig { params(message: String, server_context: T.nilable(T.untyped)).returns(Tool::Response) }
          def call(message:, server_context: nil)
            Tool::Response.new([{ type: "text", content: "OK" }])
          end
        end
      end

      request = JSON.generate({
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: "test_tool", arguments: { message: "Hello, world!" } },
        id: 1,
      })

      server = Server.new(
        name: @server_name,
        tools: [TypedTestTool],
        prompts: [@prompt],
        resources: [@resource],
        resource_templates: [@resource_template],
      )

      raw_response = server.handle_json(request)
      response = JSON.parse(raw_response, symbolize_names: true) if raw_response

      assert_equal({ content: [{ type: "text", content: "OK" }], isError: false }, response[:result])
    end

    test "#handle tools/call returns protocol error in JSON-RPC format if the tool raises an uncaught exception" do
      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: {
          name: "tool_that_raises",
          arguments: { message: "test" },
        },
        id: 1,
      }

      @server.configuration.exception_reporter.expects(:call).with do |exception, server_context|
        refute_kind_of MCP::Server::RequestHandlerError, exception
        assert_equal({ request: request }, server_context)
      end

      response = @server.handle(request)

      assert_nil response[:result]
      assert_equal(-32603, response[:error][:code])
      assert_equal "Internal error", response[:error][:message]
      assert_match(/Internal error calling tool tool_that_raises: /, response[:error][:data])
      assert_instrumentation_data({ method: "tools/call", tool_name: "tool_that_raises", tool_arguments: { message: "test" }, error: :internal_error })
    end

    test "registers tools with the same class name in different namespaces" do
      module Foo
        class Example < Tool
        end
      end

      module Bar
        class Example < Tool
        end
      end

      error = assert_raises(MCP::ToolNotUnique) { Server.new(tools: [Foo::Example, Bar::Example]) }
      assert_equal(<<~MESSAGE, error.message)
        Tool names should be unique. Use `tool_name` to assign unique names to:
        example
      MESSAGE
    end

    test "registers tools with the same tool name" do
      module Baz
        class Example < Tool
          tool_name "foo"
        end
      end

      module Qux
        class Example < Tool
          tool_name "foo"
        end
      end

      error = assert_raises(MCP::ToolNotUnique) { Server.new(tools: [Baz::Example, Qux::Example]) }
      assert_equal(<<~MESSAGE, error.message)
        Tool names should be unique. Use `tool_name` to assign unique names to:
        foo
      MESSAGE
    end

    test "#handle_json returns protocol error in JSON-RPC format if the tool raises an uncaught exception" do
      request = JSON.generate({
        jsonrpc: "2.0",
        method: "tools/call",
        params: {
          name: "tool_that_raises",
          arguments: { message: "test" },
        },
        id: 1,
      })

      response = JSON.parse(@server.handle_json(request), symbolize_names: true)
      assert_nil response[:result]
      assert_equal(-32603, response[:error][:code])
      assert_equal "Internal error", response[:error][:message]
      assert_match(/Internal error calling tool tool_that_raises: /, response[:error][:data])
      assert_instrumentation_data({ method: "tools/call", tool_name: "tool_that_raises", tool_arguments: { message: "test" }, error: :internal_error })
    end

    test "#handle tools/call returns protocol error in JSON-RPC format if input_schema raises an error during validation" do
      tool = Tool.define(
        name: "tool_with_faulty_schema",
        title: "Tool with faulty schema",
        description: "A tool with a faulty schema",
        input_schema: { type: "object", properties: { message: { type: "string" } }, required: ["message"] },
      ) { Tool::Response.new("success") }

      tool.input_schema.expects(:missing_required_arguments?).raises(RuntimeError, "Unexpected schema error")

      server = Server.new(name: "test_server", tools: [tool])

      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: {
          name: "tool_with_faulty_schema",
          arguments: { message: "test" },
        },
        id: 1,
      }

      response = server.handle(request)

      assert_nil response[:result]
      assert_equal(-32603, response[:error][:code])
      assert_equal "Internal error", response[:error][:message]
      assert_match(/Internal error calling tool tool_with_faulty_schema: Unexpected schema error/, response[:error][:data])
    end

    test "#handle tools/call returns JSON-RPC error for unknown tool" do
      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: {
          name: "unknown_tool",
          arguments: { message: "test" },
        },
        id: 1,
      }

      response = @server.handle(request)
      assert_nil response[:result]
      assert_equal(-32602, response[:error][:code])
      assert_equal "Invalid params", response[:error][:message]
      assert_includes response[:error][:data], "Tool not found: unknown_tool"
      assert_instrumentation_data({ method: "tools/call", tool_name: "unknown_tool", error: :invalid_params })
    end

    test "#handle_json returns JSON-RPC error for unknown tool" do
      request = JSON.generate({
        jsonrpc: "2.0",
        method: "tools/call",
        params: {
          name: "unknown_tool",
          arguments: {},
        },
        id: 1,
      })

      response = JSON.parse(@server.handle_json(request), symbolize_names: true)
      assert_nil response[:result]
      assert_equal(-32602, response[:error][:code])
      assert_equal "Invalid params", response[:error][:message]
      assert_includes response[:error][:data], "Tool not found: unknown_tool"
    end

    test "#handle prompts/list returns list of prompts" do
      request = {
        jsonrpc: "2.0",
        method: "prompts/list",
        id: 1,
      }

      response = @server.handle(request)
      assert_equal({ prompts: [@prompt.to_h] }, response[:result])
      assert_instrumentation_data({ method: "prompts/list" })
    end

    test "#handle prompts/get returns templated prompt" do
      request = {
        jsonrpc: "2.0",
        method: "prompts/get",
        id: 1,
        params: {
          name: "test_prompt",
          arguments: { test_argument: "Hello, friend!" },
        },
      }

      expected_result = {
        description: "Hello, world!",
        messages: [
          { role: "user", content: { text: "Hello, world!", type: "text" } },
        ],
      }

      response = @server.handle(request)
      assert_equal(expected_result, response[:result])
      assert_instrumentation_data({ method: "prompts/get", prompt_name: "test_prompt" })
    end

    test "#handle prompts/get returns error if prompt is not found" do
      request = {
        jsonrpc: "2.0",
        method: "prompts/get",
        id: 1,
        params: {
          name: "unknown_prompt",
          arguments: {},
        },
      }

      response = @server.handle(request)
      assert_equal("Prompt not found unknown_prompt", response[:error][:data])
      assert_instrumentation_data({ method: "prompts/get", error: :prompt_not_found })
    end

    test "#handle prompts/get returns error if prompt arguments are invalid" do
      request = {
        jsonrpc: "2.0",
        method: "prompts/get",
        id: 1,
        params: {
          name: "test_prompt",
          arguments: { "unknown_argument" => "Hello, friend!" },
        },
      }

      response = @server.handle(request)
      assert_equal "Missing required arguments: test_argument", response[:error][:data]
      assert_instrumentation_data({
        method: "prompts/get",
        prompt_name: "test_prompt",
        error: :missing_required_arguments,
      })
    end

    test "#handle resources/list returns a list of resources" do
      request = {
        jsonrpc: "2.0",
        method: "resources/list",
        id: 1,
      }

      response = @server.handle(request)
      assert_equal({ resources: [@resource.to_h] }, response[:result])
      assert_instrumentation_data({ method: "resources/list" })
    end

    test "#handle resources/read returns an empty array of contents by default" do
      request = {
        jsonrpc: "2.0",
        method: "resources/read",
        id: 1,
        params: {
          uri: "https://test_resource.invalid",
        },
      }

      response = @server.handle(request)
      assert_equal({ contents: [] }, response[:result])
      assert_instrumentation_data({ method: "resources/read", resource_uri: "https://test_resource.invalid" })
    end

    test "#resources_read_handler sets the resources/read handler" do
      @server.resources_read_handler do |request|
        {
          uri: request[:uri],
          mimeType: "text/plain",
          text: "Lorem ipsum dolor sit amet",
        }
      end

      request = {
        jsonrpc: "2.0",
        method: "resources/read",
        id: 1,
        params: {
          uri: "https://test_resource.invalid/my_resource",
        },
      }

      response = @server.handle(request)
      assert_equal(
        { contents: { uri: "https://test_resource.invalid/my_resource", mimeType: "text/plain", text: "Lorem ipsum dolor sit amet" } },
        response[:result],
      )
    end

    test "#handle resources/templates/list returns a list of resource templates" do
      request = {
        jsonrpc: "2.0",
        method: "resources/templates/list",
        id: 1,
      }

      response = @server.handle(request)
      assert_equal(
        {
          resourceTemplates: [@resource_template.to_h],
        },
        response[:result],
      )
      assert_instrumentation_data({ method: "resources/templates/list" })
    end

    test "#configure_logging_level returns empty hash on success" do
      response = @server.handle(
        {
          jsonrpc: "2.0",
          id: 1,
          method: "logging/setLevel",
          params: {
            level: "info",
          },
        },
      )

      assert_equal "2.0", response[:jsonrpc]
      assert_equal 1, response[:id]
      assert_equal({}, response[:result])
      refute response.key?(:error)
    end

    test "#configure_logging_level returns an error object when invalid log level is provided" do
      server = Server.new(
        tools: [TestTool],
        configuration: Configuration.new(validate_tool_call_arguments: true),
      )

      response = server.handle(
        {
          jsonrpc: "2.0",
          id: 1,
          method: "logging/setLevel",
          params: {
            level: "invalid_level",
          },
        },
      )

      assert_equal "2.0", response[:jsonrpc]
      assert_equal 1, response[:id]
      assert_equal(-32602, response[:error][:code])
      assert_includes response[:error][:data], "Invalid log level invalid_level"
    end

    test "#configure_logging_level returns an error object when server has not logging capability" do
      server = Server.new(
        tools: [TestTool],
        configuration: Configuration.new(validate_tool_call_arguments: true),
        capabilities: {
          tools: { listChanged: true },
          prompts: { listChanged: true },
          resources: { listChanged: true },
        },
      )

      response = server.handle(
        {
          jsonrpc: "2.0",
          id: 1,
          method: "logging/setLevel",
          params: {
            level: "debug",
          },
        },
      )

      assert_equal "2.0", response[:jsonrpc]
      assert_equal 1, response[:id]
      assert_equal(-32603, response[:error][:code])
      assert_includes response[:error][:data], "Server does not support logging"
    end

    test "#handle method with missing required top-level capability returns an error" do
      @server.capabilities = {}

      response = @server.handle({ jsonrpc: "2.0", method: "prompts/list", id: 1 })
      assert_equal "Server does not support prompts (required for prompts/list)", response[:error][:data]

      response = @server.handle({ jsonrpc: "2.0", method: "resources/list", id: 1 })
      assert_equal "Server does not support resources (required for resources/list)", response[:error][:data]
    end

    test "#handle method with missing required nested capability returns an error" do
      @server.capabilities = { resources: {} }
      response = @server.handle({ jsonrpc: "2.0", method: "resources/subscribe", id: 1 })
      assert_equal "Server does not support resources.subscribe (required for resources/subscribe)",
        response[:error][:data]
    end

    test "#handle unknown method returns method not found error" do
      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "unknown_method",
      }

      response = @server.handle(request)

      assert_equal "Method not found", response[:error][:message]
      assert_equal "unknown_method", response[:error][:data]
      assert_instrumentation_data({ method: "unsupported_method" })
    end

    test "#handle handles custom methods" do
      @server.define_custom_method(method_name: "add") do |params|
        params[:a] + params[:b]
      end

      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "add",
        params: { a: 1, b: 2 },
      }

      response = @server.handle(request)
      assert_equal 3, response[:result]
      assert_instrumentation_data({ method: "add" })
    end

    test "#handle handles custom notifications" do
      @server.define_custom_method(method_name: "notify") do
        nil
      end

      request = {
        jsonrpc: "2.0",
        method: "notify",
      }

      response = @server.handle(request)
      assert_nil response
      assert_instrumentation_data({ method: "notify" })
    end

    test "#handle tools/call invokes around_request with correct data" do
      call_log = []
      data_before = nil
      data_after = nil

      configuration = MCP::Configuration.new
      configuration.instrumentation_callback = instrumentation_helper.callback
      configuration.around_request = ->(data, &request_handler) {
        data_before = data.dup
        call_log << :before
        request_handler.call
        call_log << :after
        data_after = data.dup
      }

      tool = Tool.define(name: "around_test_tool", description: "Test") do |arg:|
        Tool::Response.new([{ type: "text", text: arg }])
      end

      server = Server.new(name: "test_server", tools: [tool], configuration: configuration)

      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: "around_test_tool", arguments: { arg: "hello" } },
        id: 1,
      }

      server.handle(request)

      assert_equal([:before, :after], call_log)
      assert_equal("tools/call", data_before[:method])
      assert_nil(data_before[:tool_name])
      assert_equal("around_test_tool", data_after[:tool_name])
      assert_equal({ arg: "hello" }, data_after[:tool_arguments])
    end

    test "#handle around_request and instrumentation_callback coexist" do
      around_called = false
      callback_data = nil

      configuration = MCP::Configuration.new
      configuration.around_request = ->(_data, &request_handler) {
        around_called = true
        request_handler.call
      }
      configuration.instrumentation_callback = ->(data) {
        callback_data = data.dup
      }

      server = Server.new(name: "test_server", configuration: configuration)

      request = {
        jsonrpc: "2.0",
        method: "ping",
        id: 1,
      }

      server.handle(request)

      assert(around_called)
      assert_equal("ping", callback_data[:method])
      assert(callback_data[:duration])
    end

    test "#handle reports exception and sets error when around_request raises" do
      reported_exception = nil
      reported_context = nil
      callback_data = nil

      configuration = MCP::Configuration.new
      configuration.exception_reporter = ->(e, server_context) {
        reported_exception = e
        reported_context = server_context
      }
      configuration.instrumentation_callback = ->(data) { callback_data = data.dup }
      configuration.around_request = ->(_data, &_request_handler) { raise "around_request failure" }

      server = Server.new(name: "test_server", configuration: configuration)

      request = {
        jsonrpc: "2.0",
        method: "ping",
        id: 1,
      }

      response = server.handle(request)

      assert_equal("around_request failure", reported_exception.message)
      assert_equal({ request: request }, reported_context)
      assert_equal(:internal_error, callback_data[:error])
      assert_equal(JsonRpcHandler::ErrorCode::INTERNAL_ERROR, response[:error][:code])
    end

    test "#handle does not double-report exception_reporter when a tool handler raises" do
      report_count = 0
      configuration = MCP::Configuration.new
      configuration.exception_reporter = ->(_e, _server_context) { report_count += 1 }

      failing_tool = Tool.define(name: "failing_tool", description: "Always fails") do
        raise "tool failure"
      end

      server = Server.new(name: "test_server", tools: [failing_tool], configuration: configuration)

      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: "failing_tool", arguments: {} },
        id: 1,
      }

      server.handle(request)

      assert_equal(1, report_count)
    end

    test "#handle reports both exceptions when around_request ensure raises after tool failure" do
      reported = []
      configuration = MCP::Configuration.new
      configuration.exception_reporter = ->(e, _server_context) { reported << e.message }
      configuration.around_request = ->(_data, &request_handler) do
        request_handler.call
      ensure
        raise "around ensure boom"
      end

      failing_tool = Tool.define(name: "failing_tool", description: "Always fails") do
        raise "tool failure"
      end

      server = Server.new(name: "test_server", tools: [failing_tool], configuration: configuration)

      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: "failing_tool", arguments: {} },
        id: 1,
      }

      response = server.handle(request)

      assert_equal(["tool failure", "around ensure boom"], reported)
      assert_equal(JsonRpcHandler::ErrorCode::INTERNAL_ERROR, response[:error][:code])
      assert_equal("around ensure boom", response[:error][:data])
    end

    test "#handle reports the same exception object reused across requests on every call" do
      reported = []
      configuration = MCP::Configuration.new
      configuration.exception_reporter = ->(e, _server_context) { reported << e }

      shared_error = RuntimeError.new("reused")
      shared_tool = Tool.define(name: "shared_failing_tool", description: "Always fails") do
        raise shared_error
      end

      server = Server.new(name: "test_server", tools: [shared_tool], configuration: configuration)

      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: "shared_failing_tool", arguments: {} },
        id: 1,
      }

      server.handle(request)
      server.handle(request)

      assert_equal(2, reported.size)
      assert_same(shared_error, reported[0])
      assert_same(shared_error, reported[1])
    end

    test "#handle reports frozen exceptions raised by tool handlers without wrapping them" do
      reported = []
      configuration = MCP::Configuration.new
      configuration.exception_reporter = ->(e, _server_context) { reported << e }

      frozen_error = RuntimeError.new("frozen failure").freeze
      frozen_tool = Tool.define(name: "frozen_tool", description: "Raises frozen") do
        raise frozen_error
      end

      server = Server.new(name: "test_server", tools: [frozen_tool], configuration: configuration)

      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: "frozen_tool", arguments: {} },
        id: 1,
      }

      response = server.handle(request)

      assert_equal([frozen_error], reported)
      assert_includes(response[:error][:data], "frozen failure")
    end

    test "#handle still reports via exception_reporter when around_request swallows the tool failure" do
      reported = []
      configuration = MCP::Configuration.new
      configuration.exception_reporter = ->(e, _server_context) { reported << e.message }
      configuration.around_request = ->(_data, &request_handler) do
        request_handler.call
      rescue StandardError
        { swallowed: true }
      end

      failing_tool = Tool.define(name: "failing_tool", description: "Always fails") do
        raise "tool failure"
      end

      server = Server.new(name: "test_server", tools: [failing_tool], configuration: configuration)

      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: "failing_tool", arguments: {} },
        id: 1,
      }

      response = server.handle(request)

      assert_equal(["tool failure"], reported)
      assert_equal({ swallowed: true }, response[:result])
    end

    test "#handle concurrent requests on a shared server report exceptions independently" do
      reported = Queue.new
      configuration = MCP::Configuration.new
      configuration.exception_reporter = ->(e, _server_context) { reported << e.message }

      failing_tool = Tool.define(name: "concurrent_tool", description: "Raises per-thread") do |i:|
        raise "thread #{i}"
      end

      server = Server.new(name: "test_server", tools: [failing_tool], configuration: configuration)

      threads = 10.times.map do |i|
        Thread.new do
          server.handle({
            jsonrpc: "2.0",
            method: "tools/call",
            params: { name: "concurrent_tool", arguments: { i: i } },
            id: i,
          })
        end
      end
      threads.each(&:join)

      messages = []
      messages << reported.pop until reported.empty?

      assert_equal(10.times.map { |i| "thread #{i}" }.sort, messages.sort)
    end

    test "#define_custom_method raises an error if the method is already defined" do
      assert_raises(Server::MethodAlreadyDefinedError) do
        @server.define_custom_method(method_name: "tools/call") do
          nil
        end
      end
    end

    test "the global configuration is used if no configuration is passed to the server" do
      server = Server.new(name: "test_server")
      assert_equal MCP.configuration.instrumentation_callback,
        server.configuration.instrumentation_callback
      assert_equal MCP.configuration.exception_reporter,
        server.configuration.exception_reporter
    end

    test "the server configuration takes precedence over the global configuration" do
      configuration = MCP::Configuration.new
      local_callback = ->(data) { puts "Local callback #{data.inspect}" }
      local_exception_reporter = ->(exception, server_context) {
        puts "Local exception reporter #{exception.inspect} #{server_context.inspect}"
      }
      configuration.instrumentation_callback = local_callback
      configuration.exception_reporter = local_exception_reporter

      server = Server.new(name: "test_server", configuration: configuration)

      assert_equal local_callback, server.configuration.instrumentation_callback
      assert_equal local_exception_reporter, server.configuration.exception_reporter
    end

    test "server uses default protocol version when not configured" do
      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
      }

      response = @server.handle(request)
      assert_equal Configuration::LATEST_STABLE_PROTOCOL_VERSION, response[:result][:protocolVersion]
    end

    test "server response does not include optional parameters when configured" do
      server = Server.new(title: "Example Server Display Name", name: "test_server", website_url: "https://example.com")
      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
      }

      response = server.handle(request)
      server_info = response[:result][:serverInfo]

      assert_equal("Example Server Display Name", server_info[:title])
      assert_equal("https://example.com", server_info[:websiteUrl])
    end

    test "server response does not include optional parameters when not configured" do
      server = Server.new(name: "test_server")
      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
      }

      response = server.handle(request)
      refute response[:result][:serverInfo].key?(:title)
      refute response[:result][:serverInfo].key?(:website_url)
    end

    test "server response does not include icons when icons is empty" do
      server = Server.new(name: "test_server")
      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
      }
      response = server.handle(request)

      refute response[:result][:serverInfo].key?(:icons)
    end

    test "server response does not include icons when icons is nil" do
      server = Server.new(name: "test_server", icons: nil)
      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
      }
      response = server.handle(request)

      refute response[:result][:serverInfo].key?(:icons)
    end

    test "server response includes icons when icons is present" do
      server = Server.new(
        name: "test_server",
        icons: [Icon.new(mime_type: "image/png", sizes: ["48x48"], src: "https://example.com", theme: "light")],
      )
      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
      }
      response = server.handle(request)
      expected_icons = [{ mimeType: "image/png", sizes: ["48x48"], src: "https://example.com", theme: "light" }]

      assert_equal expected_icons, response[:result][:serverInfo][:icons]
    end

    test "server uses default version when not configured" do
      server = Server.new(name: "test_server")
      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
      }

      response = server.handle(request)
      assert_equal Server::DEFAULT_VERSION, response[:result][:serverInfo][:version]
    end

    test "server uses instructions when not configured" do
      server = Server.new(name: "test_server")
      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
      }

      response = server.handle(request)
      refute response[:result].key?(:instructions)
    end

    test "server uses description when configured with protocol version 2025-11-25" do
      configuration = Configuration.new(protocol_version: "2025-11-25")
      server = Server.new(description: "This is the MCP server used during tests.", name: "test_server", configuration: configuration)
      assert_equal("This is the MCP server used during tests.", server.description)
    end

    test "raises error if description is used with protocol version 2025-06-18" do
      configuration = Configuration.new(protocol_version: "2025-06-18")

      exception = assert_raises(ArgumentError) do
        Server.new(description: "This is the MCP server used during tests.", name: "test_server", configuration: configuration)
      end
      assert_equal("Error occurred in server_info. `description` is not supported in protocol version 2025-06-18 or earlier", exception.message)
    end

    test "server uses instructions when configured with protocol version 2025-03-26" do
      configuration = Configuration.new(protocol_version: "2025-03-26")
      server = Server.new(name: "test_server", instructions: "The server instructions.", configuration: configuration)
      assert_equal("The server instructions.", server.instructions)
    end

    test "raises error if instructions are used with protocol version 2024-11-05" do
      configuration = Configuration.new(protocol_version: "2024-11-05")

      exception = assert_raises(ArgumentError) do
        Server.new(name: "test_server", instructions: "The server instructions.", configuration: configuration)
      end
      assert_equal("`instructions` supported by protocol version 2025-03-26 or higher", exception.message)
    end

    test "server uses annotations when configured with protocol version 2025-03-26" do
      configuration = Configuration.new(protocol_version: "2025-03-26")
      server = Server.new(name: "test_server", configuration: configuration)
      server.define_tool(
        name: "defined_tool",
        annotations: { title: "test server" },
      )
      assert_equal({ destructiveHint: true, idempotentHint: false, openWorldHint: true, readOnlyHint: false, title: "test server" }, server.tools.first[1].annotations.to_h)
    end

    test "raises error if annotations are used with protocol version 2024-11-05" do
      configuration = Configuration.new(protocol_version: "2024-11-05")
      exception = assert_raises(ArgumentError) do
        server = Server.new(name: "test_server", configuration: configuration)
        server.define_tool(
          name: "defined_tool",
          annotations: { title: "test server" },
        )
      end
      assert_equal("Error occurred in defined_tool. `annotations` are supported by protocol version 2025-03-26 or higher", exception.message)
    end

    test "raises error if `title` of `server_info` is used with protocol version 2025-03-26" do
      configuration = Configuration.new(protocol_version: "2025-03-26")

      exception = assert_raises(ArgumentError) do
        Server.new(name: "test_server", title: "Example Server Display Name", configuration: configuration)
      end
      assert_equal("Error occurred in server_info. `title` or `website_url` are not supported in protocol version 2025-03-26 or earlier", exception.message)
    end

    test "raises error if `website_url` of `server_info` is used with protocol version 2025-03-26" do
      configuration = Configuration.new(protocol_version: "2025-03-26")

      exception = assert_raises(ArgumentError) do
        Server.new(name: "test_server", website_url: "https://example.com", configuration: configuration)
      end
      assert_equal("Error occurred in server_info. `title` or `website_url` are not supported in protocol version 2025-03-26 or earlier", exception.message)
    end

    test "raises error if `title` of tool is used with protocol version 2025-03-26" do
      configuration = Configuration.new(protocol_version: "2025-03-26")
      server = Server.new(name: "test_server", configuration: configuration)

      exception = assert_raises(ArgumentError) do
        server.define_tool(
          title: "Test tool",
        )
      end
      assert_equal("Error occurred in Test tool. `title` is not supported in protocol version 2025-03-26 or earlier", exception.message)
    end

    test "raises error if `title` of prompt is used with protocol version 2025-03-26" do
      configuration = Configuration.new(protocol_version: "2025-03-26")
      server = Server.new(name: "test_server", configuration: configuration)

      exception = assert_raises(ArgumentError) do
        server.define_prompt(
          title: "Test prompt",
        )
      end
      assert_equal("Error occurred in Test prompt. `title` is not supported in protocol version 2025-03-26 or earlier", exception.message)
    end

    test "raises error if `title` of resource is used with protocol version 2025-03-26" do
      configuration = Configuration.new(protocol_version: "2025-03-26")

      resource = Resource.new(
        uri: "https://test_resource.invalid",
        name: "test-resource",
        title: "Test resource",
      )
      exception = assert_raises(ArgumentError) do
        Server.new(name: "test_server", resources: [resource], configuration: configuration)
      end
      assert_equal("Error occurred in Test resource. `title` is not supported in protocol version 2025-03-26 or earlier", exception.message)
    end

    test "allows `$ref` in tool input schema with protocol version 2025-11-25" do
      tool = Tool.define(
        name: "ref_tool",
        description: "Tool with $ref",
        input_schema: {
          type: "object",
          "$defs": { address: { type: "object", properties: { city: { type: "string" } } } },
          properties: { address: { "$ref": "#/$defs/address" } },
        },
      )
      configuration = Configuration.new(protocol_version: "2025-11-25")

      assert_nothing_raised do
        Server.new(name: "test_server", tools: [tool], configuration: configuration)
      end
    end

    test "raises error if `$ref` in tool input schema is used with protocol version 2025-06-18" do
      tool = Tool.define(
        name: "ref_tool",
        description: "Tool with $ref",
        input_schema: {
          type: "object",
          "$defs": { address: { type: "object", properties: { city: { type: "string" } } } },
          properties: { address: { "$ref": "#/$defs/address" } },
        },
      )
      configuration = Configuration.new(protocol_version: "2025-06-18")

      exception = assert_raises(ArgumentError) do
        Server.new(name: "test_server", tools: [tool], configuration: configuration)
      end
      assert_equal(
        "Error occurred in ref_tool. `$ref` in input schemas is supported by protocol version 2025-11-25 or higher",
        exception.message,
      )
    end

    test "raises error if `title` of resource template is used with protocol version 2025-03-26" do
      configuration = Configuration.new(protocol_version: "2025-03-26")

      resource = Resource.new(
        uri: "https://test_resource.invalid",
        name: "test-resource",
        title: "Test resource template",
      )
      exception = assert_raises(ArgumentError) do
        Server.new(name: "test_server", resources: [resource], configuration: configuration)
      end
      assert_equal("Error occurred in Test resource template. `title` is not supported in protocol version 2025-03-26 or earlier", exception.message)
    end

    test "#define_tool adds a tool to the server" do
      @server.define_tool(
        name: "defined_tool",
        description: "Defined tool",
        input_schema: { type: "object", properties: { message: { type: "string" } }, required: ["message"] },
        output_schema: { type: "object", properties: { response: { type: "string" } }, required: ["response"] },
        meta: { foo: "bar" },
      ) do |message:|
        Tool::Response.new({ "response" => message })
      end

      stored_tool = @server.instance_variable_get(:@tools)["defined_tool"]
      assert_not_nil(stored_tool)
      assert_equal(MCP::Tool::OutputSchema.new({ type: "object", properties: { response: { type: "string" } }, required: ["response"] }), stored_tool.output_schema)

      response = @server.handle({
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: "defined_tool", arguments: { message: "success" } },
        id: 1,
      })

      assert_equal({ content: { "response" => "success" }, isError: false }, response[:result])
    end

    test "#define_tool adds a tool with duplicated tool name to the server" do
      error = assert_raises(MCP::ToolNotUnique) do
        @server.define_tool(
          name: "test_tool", # NOTE: Already registered tool name
          description: "Defined tool",
          input_schema: { type: "object", properties: { message: { type: "string" } }, required: ["message"] },
          meta: { foo: "bar" },
        ) do |message:|
          Tool::Response.new(message)
        end
      end
      assert_match(/\ATool names should be unique. Use `tool_name` to assign unique names to/, error.message)
    end

    test "#define_tool call definition allows tool arguments and server context" do
      @server.server_context = { user_id: "123" }

      @server.define_tool(
        name: "defined_tool",
        description: "Defined tool",
        input_schema: { type: "object", properties: { message: { type: "string" } }, required: ["message"] },
      ) do |message:, server_context:|
        Tool::Response.new("success #{message} #{server_context[:user_id]}")
      end

      response = @server.handle({
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: "defined_tool", arguments: { message: "hello" } },
        id: 1,
      })

      assert_equal({ content: "success hello 123", isError: false }, response[:result])
    end

    test "#define_prompt adds a tool to the server" do
      @server.define_prompt(name: "defined_prompt", description: "Defined prompt", arguments: []) do
        Prompt::Result.new(
          description: "a prompt description",
          messages: [Prompt::Message.new(role: "user", content: Content::Text.new("a prompt message"))],
        )
      end

      response = @server.handle({
        jsonrpc: "2.0",
        method: "prompts/get",
        params: { name: "defined_prompt", arguments: {} },
        id: 1,
      })

      assert_equal(
        {
          description: "a prompt description",
          messages: [{ role: "user", content: { text: "a prompt message", type: "text" } }],
        },
        response[:result],
      )
    end

    test "server protocol version can be overridden via configuration" do
      custom_version = "2025-03-26"
      configuration = Configuration.new(protocol_version: custom_version)
      server = Server.new(name: "test_server", configuration: configuration)

      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
      }

      response = server.handle(request)
      assert_equal custom_version, response[:result][:protocolVersion]
    end

    test "server negotiates protocol version when client requests a supported version" do
      server = Server.new(name: "test_server")

      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: {
          protocolVersion: "2025-06-18",
        },
      }

      response = server.handle(request)
      assert_equal "2025-06-18", response[:result][:protocolVersion]
    end

    test "server falls back to default version when client requests unsupported version" do
      server = Server.new(name: "test_server")

      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: {
          protocolVersion: "1999-01-01",
        },
      }

      response = server.handle(request)
      assert_equal Configuration::LATEST_STABLE_PROTOCOL_VERSION, response[:result][:protocolVersion]
    end

    test "server removes description and icons from server_info when negotiating to 2025-06-18" do
      server = Server.new(
        name: "test_server",
        description: "A test server",
        icons: [Icon.new(src: "https://example.com/icon.png")],
      )

      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: {
          protocolVersion: "2025-06-18",
        },
      }

      response = server.handle(request)
      assert_equal "2025-06-18", response[:result][:protocolVersion]
      refute response[:result][:serverInfo].key?(:description)
      refute response[:result][:serverInfo].key?(:icons)
    end

    test "server removes title and websiteUrl when negotiating to 2025-03-26" do
      server = Server.new(name: "test_server", title: "Test Server", website_url: "https://example.com")

      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: {
          protocolVersion: "2025-03-26",
        },
      }

      response = server.handle(request)
      assert_equal "2025-03-26", response[:result][:protocolVersion]
      refute response[:result][:serverInfo].key?(:title)
      refute response[:result][:serverInfo].key?(:websiteUrl)
    end

    test "server removes instructions when negotiating to 2024-11-05" do
      server = Server.new(name: "test_server", instructions: "Some instructions")

      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
        params: {
          protocolVersion: "2024-11-05",
        },
      }

      response = server.handle(request)
      assert_equal "2024-11-05", response[:result][:protocolVersion]
      refute response[:result].key?(:instructions)
    end

    test "tools/call returns protocol error in JSON-RPC format for missing arguments" do
      server = Server.new(
        tools: [TestTool],
        configuration: Configuration.new(validate_tool_call_arguments: true),
      )

      response = server.handle(
        {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: {
            name: "test_tool",
          },
        },
      )

      assert_equal "2.0", response[:jsonrpc]
      assert_equal 1, response[:id]
      assert_nil response[:result]
      assert_equal(-32602, response[:error][:code])
      assert_equal "Invalid params", response[:error][:message]
      assert_includes response[:error][:data], "Missing required arguments"
    end

    test "tools/call returns protocol error in JSON-RPC format for invalid arguments when validate_tool_call_arguments is true" do
      server = Server.new(
        tools: [TestTool],
        configuration: Configuration.new(validate_tool_call_arguments: true),
      )

      response = server.handle(
        {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: {
            name: "test_tool",
            arguments: { message: 123 },
          },
        },
      )

      assert_equal "2.0", response[:jsonrpc]
      assert_equal 1, response[:id]
      assert_nil response[:result]
      assert_equal(-32602, response[:error][:code])
      assert_equal "Invalid params", response[:error][:message]
      assert_includes response[:error][:data], "Invalid arguments"
    end

    test "tools/call skips argument validation when validate_tool_call_arguments is false" do
      server = Server.new(
        tools: [TestTool],
        configuration: Configuration.new(validate_tool_call_arguments: false),
      )

      response = server.handle(
        {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: {
            name: "test_tool",
            arguments: { message: 123 },
          },
        },
      )

      assert_equal "2.0", response[:jsonrpc]
      assert_equal 1, response[:id]
      assert response[:result], "Expected result key in response"
      assert_equal "text", response[:result][:content][0][:type]
      assert_equal "OK", response[:result][:content][0][:content]
    end

    test "tools/call validates arguments with complex types" do
      server = Server.new(
        tools: [ComplexTypesTool],
        configuration: Configuration.new(validate_tool_call_arguments: true),
      )

      response = server.handle(
        {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: {
            name: "complex_types_tool",
            arguments: {
              numbers: [1, 2, 3],
              strings: ["a", "b", "c"],
              objects: [{ name: "test" }],
            },
          },
        },
      )

      assert_equal "2.0", response[:jsonrpc]
      assert_equal 1, response[:id]
      assert response[:result], "Expected result key in response"
      assert_equal "text", response[:result][:content][0][:type]
      assert_equal "OK", response[:result][:content][0][:content]
    end

    test "tools/call allows additional properties by default" do
      server = Server.new(
        tools: [TestTool],
        configuration: Configuration.new(validate_tool_call_arguments: true),
      )

      response = server.handle(
        {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: {
            name: "test_tool",
            arguments: {
              message: "Hello, world!",
              other_property: "I am allowed",
            },
          },
        },
      )

      assert_equal "2.0", response[:jsonrpc]
      assert_equal 1, response[:id]
      assert response[:result], "Expected result key in response"
      assert_equal "text", response[:result][:content][0][:type]
      assert_equal "OK", response[:result][:content][0][:content]
    end

    test "tools/call returns protocol error in JSON-RPC format when additionalProperties set to false" do
      server = Server.new(
        tools: [TestToolWithAdditionalPropertiesSetToFalse],
        configuration: Configuration.new(validate_tool_call_arguments: true),
      )

      response = server.handle(
        {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: {
            name: "test_tool_with_additional_properties_set_to_false",
            arguments: {
              message: "Hello, world!",
              extra: 123,
            },
          },
        },
      )

      assert_equal "2.0", response[:jsonrpc]
      assert_equal 1, response[:id]
      assert_nil response[:result]
      assert_equal(-32602, response[:error][:code])
      assert_equal "Invalid params", response[:error][:message]
      assert_includes response[:error][:data], "Invalid arguments"
    end

    test "#handle completion/complete returns default completion result" do
      prompt = Prompt.define(name: "test") {}
      server = Server.new(
        name: "test_server",
        prompts: [prompt],
        capabilities: { completions: {} },
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1 })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/prompt", name: "test" },
          argument: { name: "arg", value: "val" },
        },
      })

      assert_equal(
        {
          jsonrpc: "2.0",
          id: 2,
          result: { completion: { values: [], hasMore: false } },
        },
        response,
      )
    end

    test "#handle completion/complete with custom handler for ref/prompt" do
      prompt = Prompt.define(
        name: "code_review",
        arguments: [Prompt::Argument.new(name: "language", required: true)],
      ) {}
      server = Server.new(
        name: "test_server",
        prompts: [prompt],
        capabilities: { completions: {} },
      )

      server.completion_handler do |_params|
        { completion: { values: ["python", "pytorch", "pyside"], total: 10, hasMore: true } }
      end

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1 })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/prompt", name: "code_review" },
          argument: { name: "language", value: "py" },
        },
      })

      assert_equal(
        {
          jsonrpc: "2.0",
          id: 2,
          result: { completion: { values: ["python", "pytorch", "pyside"], total: 10, hasMore: true } },
        },
        response,
      )
    end

    test "#handle completion/complete with custom handler for ref/resource" do
      template = ResourceTemplate.new(
        uri_template: "file:///{path}",
        name: "file",
      )
      server = Server.new(
        name: "test_server",
        resource_templates: [template],
        capabilities: { completions: {} },
      )

      server.completion_handler do |_params|
        { completion: { values: ["file:///src", "file:///spec"], hasMore: false } }
      end

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1 })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/resource", uri: "file:///{path}" },
          argument: { name: "path", value: "s" },
        },
      })

      assert_equal(
        {
          jsonrpc: "2.0",
          id: 2,
          result: { completion: { values: ["file:///src", "file:///spec"], hasMore: false } },
        },
        response,
      )
    end

    test "#handle completion/complete passes context arguments to handler" do
      prompt = Prompt.define(
        name: "code_review",
        arguments: [
          Prompt::Argument.new(name: "language", required: true),
          Prompt::Argument.new(name: "framework", required: false),
        ],
      ) {}
      server = Server.new(
        name: "test_server",
        prompts: [prompt],
        capabilities: { completions: {} },
      )

      received_params = nil
      server.completion_handler do |params|
        received_params = params
        { completion: { values: ["flask"], hasMore: false } }
      end

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1 })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/prompt", name: "code_review" },
          argument: { name: "framework", value: "fla" },
          context: { arguments: { language: "python" } },
        },
      })

      assert_equal({ language: "python" }, received_params.dig(:context, :arguments))
    end

    test "#handle completion/complete truncates values exceeding 100 items" do
      prompt = Prompt.define(name: "test") {}
      server = Server.new(
        name: "test_server",
        prompts: [prompt],
        capabilities: { completions: {} },
      )

      server.completion_handler do |_params|
        { completion: { values: (1..150).map(&:to_s), hasMore: false } }
      end

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1 })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/prompt", name: "test" },
          argument: { name: "arg", value: "" },
        },
      })

      completion = response[:result][:completion]
      assert_equal 100, completion[:values].length
      assert_equal "1", completion[:values].first
      assert_equal "100", completion[:values].last
      assert(completion[:hasMore])
      assert_equal 150, completion[:total]
    end

    test "#handle completion/complete returns error for nonexistent prompt" do
      server = Server.new(
        name: "test_server",
        capabilities: { completions: {} },
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1 })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/prompt", name: "nonexistent" },
          argument: { name: "arg", value: "val" },
        },
      })

      assert_equal(-32_602, response[:error][:code])
    end

    test "#handle completion/complete returns error for nonexistent resource template" do
      server = Server.new(
        name: "test_server",
        capabilities: { completions: {} },
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1 })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/resource", uri: "unknown://template" },
          argument: { name: "arg", value: "val" },
        },
      })

      assert_equal(-32_602, response[:error][:code])
    end

    test "#handle completion/complete returns error for invalid ref type" do
      server = Server.new(
        name: "test_server",
        capabilities: { completions: {} },
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1 })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/invalid" },
          argument: { name: "arg", value: "val" },
        },
      })

      assert_equal(-32_602, response[:error][:code])
    end

    test "#handle completion/complete returns error for missing ref" do
      server = Server.new(
        name: "test_server",
        capabilities: { completions: {} },
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1 })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: {},
          argument: { name: "arg", value: "val" },
        },
      })

      assert_equal(-32_602, response[:error][:code])
    end

    test "#handle completion/complete with custom handler for ref/resource with resource URI" do
      resource = Resource.new(
        uri: "file:///README.md",
        name: "readme",
      )
      server = Server.new(
        name: "test_server",
        resources: [resource],
        capabilities: { completions: {} },
      )

      server.completion_handler do |_params|
        { completion: { values: ["file:///README.md"], hasMore: false } }
      end

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1 })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/resource", uri: "file:///README.md" },
          argument: { name: "path", value: "R" },
        },
      })

      assert_equal(
        {
          jsonrpc: "2.0",
          id: 2,
          result: { completion: { values: ["file:///README.md"], hasMore: false } },
        },
        response,
      )
    end

    test "#handle completion/complete returns error for missing argument" do
      prompt = Prompt.define(name: "test") {}
      server = Server.new(
        name: "test_server",
        prompts: [prompt],
        capabilities: { completions: {} },
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1 })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/prompt", name: "test" },
        },
      })

      assert_equal(-32_602, response[:error][:code])
    end

    test "#handle completion/complete returns error for missing argument value" do
      prompt = Prompt.define(name: "test") {}
      server = Server.new(
        name: "test_server",
        prompts: [prompt],
        capabilities: { completions: {} },
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1 })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/prompt", name: "test" },
          argument: { name: "arg" },
        },
      })

      assert_equal(-32_602, response[:error][:code])
    end

    test "#handle completion/complete returns default when handler returns nil" do
      prompt = Prompt.define(name: "test") {}
      server = Server.new(
        name: "test_server",
        prompts: [prompt],
        capabilities: { completions: {} },
      )

      server.completion_handler do |_params|
        nil
      end

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1 })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/prompt", name: "test" },
          argument: { name: "arg", value: "" },
        },
      })

      assert_equal(
        {
          jsonrpc: "2.0",
          id: 2,
          result: { completion: { values: [], hasMore: false } },
        },
        response,
      )
    end

    test "#handle completion/complete with string-keyed handler result" do
      prompt = Prompt.define(name: "test") {}
      server = Server.new(
        name: "test_server",
        prompts: [prompt],
        capabilities: { completions: {} },
      )

      server.completion_handler do |_params|
        { "completion" => { "values" => ["alpha", "beta"], "hasMore" => true } }
      end

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1 })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/prompt", name: "test" },
          argument: { name: "arg", value: "" },
        },
      })

      assert_equal ["alpha", "beta"], response[:result][:completion][:values]
      assert response[:result][:completion][:hasMore]
    end

    test "#handle completion/complete returns invalid params for non-Hash params" do
      server = Server.new(
        name: "test_server",
        prompts: [],
        capabilities: { completions: {} },
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1 })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: "invalid",
      })

      assert_equal(-32602, response[:error][:code])
    end

    test "#handle completion/complete returns error when completions capability is not declared" do
      server = Server.new(
        name: "test_server",
        prompts: [],
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1 })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "completion/complete",
        params: {
          ref: { type: "ref/prompt", name: "test" },
          argument: { name: "arg", value: "" },
        },
      })

      assert response[:error]
      assert_includes response[:error][:data], "completions"
    end

    test "#handle resources/subscribe returns empty result" do
      server = Server.new(
        name: "test_server",
        capabilities: { resources: { subscribe: true } },
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1 })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "resources/subscribe",
        params: { uri: "https://example.com/resource" },
      })

      assert_equal(
        {
          jsonrpc: "2.0",
          id: 2,
          result: {},
        },
        response,
      )
    end

    test "#handle resources/unsubscribe returns empty result" do
      server = Server.new(
        name: "test_server",
        capabilities: { resources: { subscribe: true } },
      )

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1 })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "resources/unsubscribe",
        params: { uri: "https://example.com/resource" },
      })

      assert_equal(
        {
          jsonrpc: "2.0",
          id: 2,
          result: {},
        },
        response,
      )
    end

    test "#handle resources/subscribe with custom handler calls the handler" do
      server = Server.new(
        name: "test_server",
        capabilities: { resources: { subscribe: true } },
      )

      received_params = nil
      server.resources_subscribe_handler do |params|
        received_params = params
        {}
      end

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1 })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "resources/subscribe",
        params: { uri: "https://example.com/resource" },
      })

      assert_equal(
        {
          jsonrpc: "2.0",
          id: 2,
          result: {},
        },
        response,
      )
      assert_equal "https://example.com/resource", received_params[:uri]
    end

    test "#handle resources/unsubscribe with custom handler calls the handler" do
      server = Server.new(
        name: "test_server",
        capabilities: { resources: { subscribe: true } },
      )

      received_params = nil
      server.resources_unsubscribe_handler do |params|
        received_params = params
        {}
      end

      server.handle({ jsonrpc: "2.0", method: "initialize", id: 1 })
      server.handle({ jsonrpc: "2.0", method: "notifications/initialized" })

      response = server.handle({
        jsonrpc: "2.0",
        id: 2,
        method: "resources/unsubscribe",
        params: { uri: "https://example.com/resource" },
      })

      assert_equal(
        {
          jsonrpc: "2.0",
          id: 2,
          result: {},
        },
        response,
      )
      assert_equal "https://example.com/resource", received_params[:uri]
    end

    test "tools/call with no args" do
      server = Server.new(tools: [@tool_with_no_args])

      response = server.handle(
        {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: {
            name: "tool_with_no_args",
          },
        },
      )

      assert_equal "2.0", response[:jsonrpc]
      assert_equal 1, response[:id]
      assert response[:result], "Expected result key in response"
      assert_equal "text", response[:result][:content][0][:type]
      assert_equal "OK", response[:result][:content][0][:content]
    end

    class TestTool < Tool
      tool_name "test_tool"
      description "a test tool for testing"
      input_schema({ properties: { message: { type: "string" } }, required: ["message"] })

      class << self
        def call(server_context: nil, **kwargs)
          Tool::Response.new([{ type: "text", content: "OK" }])
        end
      end
    end

    class TestToolWithAdditionalPropertiesSetToFalse < Tool
      tool_name "test_tool_with_additional_properties_set_to_false"
      description "a test tool with additionalProperties set to false for testing"
      input_schema({ properties: { message: { type: "string" } }, required: ["message"], additionalProperties: false })

      class << self
        def call(server_context: nil, **kwargs)
          Tool::Response.new([{ type: "text", content: "OK" }])
        end
      end
    end

    class ComplexTypesTool < Tool
      tool_name "complex_types_tool"
      description "a test tool with complex types"
      input_schema({
        properties: {
          numbers: { type: "array", items: { type: "number" } },
          strings: { type: "array", items: { type: "string" } },
          objects: {
            type: "array",
            items: {
              type: "object",
              properties: {
                name: { type: "string" },
              },
              required: ["name"],
            },
          },
        },
        required: ["numbers", "strings", "objects"],
      })

      class << self
        def call(numbers:, strings:, objects:, server_context: nil)
          Tool::Response.new([{ type: "text", content: "OK" }])
        end
      end
    end

    test "server_context_with_meta uses accessor method, not ivar directly" do
      subclass = Class.new(Server) do
        def server_context
          { custom: "from_accessor" }
        end
      end

      server = subclass.new(name: "test", tools: [])

      received_context = nil
      server.define_tool(name: "ctx_tool") do |server_context:|
        received_context = server_context
        Tool::Response.new([{ type: "text", text: "ok" }])
      end

      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        id: 1,
        params: { name: "ctx_tool", arguments: {} },
      }

      server.handle(request)
      assert_equal "from_accessor", received_context[:custom]
    end

    test "#handle tools/list returns paginated results when page_size is set" do
      tool_a = Tool.define(name: "tool_a", title: "Tool A", description: "Tool A")
      tool_b = Tool.define(name: "tool_b", title: "Tool B", description: "Tool B")
      tool_c = Tool.define(name: "tool_c", title: "Tool C", description: "Tool C")

      server = Server.new(
        name: "pagination_test",
        tools: [tool_a, tool_b, tool_c],
        page_size: 2,
      )

      first_request = { jsonrpc: "2.0", method: "tools/list", id: 1 }
      first_response = server.handle(first_request)
      first_result = first_response[:result]

      assert_equal 2, first_result[:tools].size
      assert_equal "tool_a", first_result[:tools][0][:name]
      assert_equal "tool_b", first_result[:tools][1][:name]
      assert_not_nil first_result[:nextCursor]

      second_request = { jsonrpc: "2.0", method: "tools/list", id: 2, params: { cursor: first_result[:nextCursor] } }
      second_response = server.handle(second_request)
      second_result = second_response[:result]

      assert_equal 1, second_result[:tools].size
      assert_equal "tool_c", second_result[:tools][0][:name]
      # Final page omits the nextCursor key entirely (not just sets it to nil).
      refute second_result.key?(:nextCursor)
    end

    test "#handle tools/list returns all tools when page_size is not set" do
      response = @server.handle({ jsonrpc: "2.0", method: "tools/list", id: 1 })
      result = response[:result]

      assert_kind_of Array, result[:tools]
      assert_nil result[:nextCursor]
    end

    test "#handle tools/list returns error for invalid cursor" do
      server = Server.new(name: "pagination_test", tools: [@tool], page_size: 1)

      request = { jsonrpc: "2.0", method: "tools/list", id: 1, params: { cursor: "!!!invalid!!!" } }
      response = server.handle(request)

      assert_not_nil response[:error]
      assert_equal(-32602, response[:error][:code])
    end

    test "#handle prompts/list returns paginated results when page_size is set" do
      prompt_a = Prompt.define(name: "prompt_a", title: "Prompt A", description: "A") { Prompt::Result.new(description: "A", messages: []) }
      prompt_b = Prompt.define(name: "prompt_b", title: "Prompt B", description: "B") { Prompt::Result.new(description: "B", messages: []) }

      server = Server.new(name: "pagination_test", prompts: [prompt_a, prompt_b], page_size: 1)

      first_response = server.handle({ jsonrpc: "2.0", method: "prompts/list", id: 1 })
      first_result = first_response[:result]

      assert_equal 1, first_result[:prompts].size
      assert_equal "prompt_a", first_result[:prompts][0][:name]
      assert_not_nil first_result[:nextCursor]

      second_response = server.handle({ jsonrpc: "2.0", method: "prompts/list", id: 2, params: { cursor: first_result[:nextCursor] } })
      second_result = second_response[:result]

      assert_equal 1, second_result[:prompts].size
      assert_equal "prompt_b", second_result[:prompts][0][:name]
      assert_nil second_result[:nextCursor]
    end

    test "#handle resources/list returns paginated results when page_size is set" do
      resource_a = Resource.new(uri: "https://a.invalid", name: "a", description: "A", mime_type: "text/plain")
      resource_b = Resource.new(uri: "https://b.invalid", name: "b", description: "B", mime_type: "text/plain")

      server = Server.new(name: "pagination_test", resources: [resource_a, resource_b], page_size: 1)

      first_response = server.handle({ jsonrpc: "2.0", method: "resources/list", id: 1 })
      first_result = first_response[:result]

      assert_equal 1, first_result[:resources].size
      assert_equal "a", first_result[:resources][0][:name]
      assert_not_nil first_result[:nextCursor]

      second_response = server.handle({ jsonrpc: "2.0", method: "resources/list", id: 2, params: { cursor: first_result[:nextCursor] } })
      second_result = second_response[:result]

      assert_equal 1, second_result[:resources].size
      assert_equal "b", second_result[:resources][0][:name]
      assert_nil second_result[:nextCursor]
    end

    test "Server.new raises ArgumentError when page_size is zero" do
      assert_raises(ArgumentError) do
        Server.new(name: "test", page_size: 0)
      end
    end

    test "Server.new raises ArgumentError when page_size is negative" do
      assert_raises(ArgumentError) do
        Server.new(name: "test", page_size: -1)
      end
    end

    test "Server.new raises ArgumentError when page_size is non-Integer" do
      assert_raises(ArgumentError) do
        Server.new(name: "test", page_size: "10")
      end
    end

    test "page_size= raises ArgumentError for invalid values" do
      server = Server.new(name: "test")

      assert_raises(ArgumentError) { server.page_size = 0 }
      assert_raises(ArgumentError) { server.page_size = -1 }
      assert_raises(ArgumentError) { server.page_size = "5" }

      server.page_size = nil
      server.page_size = 10
      assert_equal 10, server.page_size
    end

    test "#handle tools/list returns -32602 for non-Hash params" do
      server = Server.new(name: "test", tools: [@tool], page_size: 1)

      request = { jsonrpc: "2.0", method: "tools/list", id: 1, params: [1, 2, 3] }
      response = server.handle(request)

      assert_not_nil response[:error]
      assert_equal(-32602, response[:error][:code])
    end

    test "#handle_json tools/list returns -32602 for numeric cursor (spec requires string)" do
      server = Server.new(name: "test", tools: [@tool], page_size: 1)

      request_json = '{"jsonrpc":"2.0","method":"tools/list","id":1,"params":{"cursor":0}}'
      response = JSON.parse(server.handle_json(request_json), symbolize_names: true)

      assert_not_nil response[:error]
      assert_equal(-32602, response[:error][:code])
    end

    test "#handle resources/templates/list returns paginated results when page_size is set" do
      template_a = ResourceTemplate.new(uri_template: "https://a.invalid/{id}", name: "a", description: "A", mime_type: "text/plain")
      template_b = ResourceTemplate.new(uri_template: "https://b.invalid/{id}", name: "b", description: "B", mime_type: "text/plain")

      server = Server.new(name: "pagination_test", resource_templates: [template_a, template_b], page_size: 1)

      first_response = server.handle({ jsonrpc: "2.0", method: "resources/templates/list", id: 1 })
      first_result = first_response[:result]

      assert_equal 1, first_result[:resourceTemplates].size
      assert_equal "a", first_result[:resourceTemplates][0][:name]
      assert_not_nil first_result[:nextCursor]

      second_response = server.handle({ jsonrpc: "2.0", method: "resources/templates/list", id: 2, params: { cursor: first_result[:nextCursor] } })
      second_result = second_response[:result]

      assert_equal 1, second_result[:resourceTemplates].size
      assert_equal "b", second_result[:resourceTemplates][0][:name]
      assert_nil second_result[:nextCursor]
    end
  end
end
