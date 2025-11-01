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
        mime_type: "text/plain",
      )

      @resource_template = ResourceTemplate.new(
        uri_template: "https://test_resource.invalid/{id}",
        name: "test-resource",
        title: "Test Resource",
        description: "Test resource",
        mime_type: "text/plain",
      )

      @server_name = "test_server"
      configuration = MCP::Configuration.new
      configuration.instrumentation_callback = instrumentation_helper.callback

      @server = Server.new(
        name: @server_name,
        title: "Example Server Display Name",
        version: "1.2.3",
        instructions: "Optional instructions for the client",
        tools: [@tool, @tool_that_raises],
        prompts: [@prompt],
        resources: [@resource],
        resource_templates: [@resource_template],
        configuration:,
      )
    end

    # https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/ping#behavior-requirements
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
          protocolVersion: "2025-06-18",
          capabilities: {
            prompts: { listChanged: true },
            resources: { listChanged: true },
            tools: { listChanged: true },
            logging: {},
          },
          serverInfo: {
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

    test "#tools_list_handler sets the tools/list handler" do
      @server.tools_list_handler do
        [{ name: "hammer", description: "Hammer time!" }]
      end

      request = {
        jsonrpc: "2.0",
        method: "tools/list",
        id: 1,
      }

      response = @server.handle(request)
      result = response[:result]
      assert_equal({ tools: [{ name: "hammer", description: "Hammer time!" }] }, result)
      assert_instrumentation_data({ method: "tools/list" })
    end

    test "#handle tools/call executes tool and returns result" do
      tool_name = "test_tool"
      tool_args = { arg: "value" }
      tool_response = Tool::Response.new([{ result: "success" }])

      @tool.expects(:call).with(arg: "value", server_context: nil).returns(tool_response)

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
      assert_instrumentation_data({ method: "tools/call", tool_name: })
    end

    test "#handle tools/call returns error response with isError true if required tool arguments are missing" do
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

      assert_nil response[:error], "Expected no JSON-RPC error"
      assert response[:result][:isError]
      assert_equal "text", response[:result][:content][0][:type]
      assert_equal "Missing required arguments: message", response[:result][:content][0][:text]
    end

    test "#handle_json tools/call executes tool and returns result" do
      tool_name = "test_tool"
      tool_args = { arg: "value" }
      tool_response = Tool::Response.new([{ result: "success" }])

      @tool.expects(:call).with(arg: "value", server_context: nil).returns(tool_response)

      request = JSON.generate({
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: tool_name, arguments: tool_args },
        id: 1,
      })

      raw_response = @server.handle_json(request)
      response = JSON.parse(raw_response, symbolize_names: true) if raw_response
      assert_equal tool_response.to_h, response[:result] if response
      assert_instrumentation_data({ method: "tools/call", tool_name: })
    end

    test "#handle_json tools/call executes tool and returns result, when the tool is typed with Sorbet" do
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

    test "#handle tools/call returns error response with isError true if the tool raises an error" do
      @server.configuration.exception_reporter.expects(:call).with do |exception, server_context|
        assert_not_nil exception
        assert_equal(
          {
            request: { name: "tool_that_raises", arguments: { message: "test" } },
          },
          server_context,
        )
      end

      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: {
          name: "tool_that_raises",
          arguments: { message: "test" },
        },
        id: 1,
      }

      response = @server.handle(request)

      assert_nil response[:error], "Expected no JSON-RPC error"
      assert response[:result][:isError]
      assert_equal "text", response[:result][:content][0][:type]
      assert_match(/Internal error calling tool tool_that_raises: /, response[:result][:content][0][:text])
      assert_instrumentation_data({ method: "tools/call", tool_name: "tool_that_raises" })
    end

    test "#handle_json returns error response with isError true if the tool raises an error" do
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
      assert_nil response[:error], "Expected no JSON-RPC error"
      assert response[:result][:isError]
      assert_equal "text", response[:result][:content][0][:type]
      assert_match(/Internal error calling tool tool_that_raises: /, response[:result][:content][0][:text])
      assert_instrumentation_data({ method: "tools/call", tool_name: "tool_that_raises" })
    end

    test "#handle tools/call returns error response with isError true for unknown tool" do
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
      assert_nil response[:error], "Expected no JSON-RPC error"
      assert response[:result][:isError]
      assert_equal "text", response[:result][:content][0][:type]
      assert_equal "Tool not found: unknown_tool", response[:result][:content][0][:text]
      assert_instrumentation_data({ method: "tools/call", tool_name: "unknown_tool", error: :tool_not_found })
    end

    test "#handle_json returns error response with isError true for unknown tool" do
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
      assert_nil response[:error], "Expected no JSON-RPC error"
      assert response[:result][:isError]
      assert_equal "text", response[:result][:content][0][:type]
      assert_equal "Tool not found: unknown_tool", response[:result][:content][0][:text]
    end

    test "#tools_call_handler sets the tools/call handler" do
      @server.tools_call_handler do |request|
        tool_name = request[:name]
        Tool::Response.new("#{tool_name} called successfully").to_h
      end

      request = {
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: "my_tool", arguments: {} },
        id: 1,
      }

      response = @server.handle(request)
      assert_equal({ content: "my_tool called successfully", isError: false }, response[:result])
      assert_instrumentation_data({ method: "tools/call" })
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

    test "#prompts_list_handler sets the prompts/list handler" do
      @server.prompts_list_handler do
        [{ name: "foo_prompt", description: "Foo prompt" }]
      end

      request = {
        jsonrpc: "2.0",
        method: "prompts/list",
        id: 1,
      }

      response = @server.handle(request)
      assert_equal({ prompts: [{ name: "foo_prompt", description: "Foo prompt" }] }, response[:result])
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

    test "#prompts_get_handler sets the prompts/get handler" do
      @server.prompts_get_handler do |request|
        prompt_name = request[:name]
        Prompt::Result.new(
          description: prompt_name,
          messages: [
            Prompt::Message.new(role: "user", content: Content::Text.new(request[:arguments]["foo"])),
          ],
        ).to_h
      end

      request = {
        jsonrpc: "2.0",
        method: "prompts/get",
        id: 1,
        params: { name: "foo_bar_prompt", arguments: { "foo" => "bar" } },
      }

      response = @server.handle(request)
      assert_equal(
        { description: "foo_bar_prompt", messages: [{ role: "user", content: { type: "text", text: "bar" } }] },
        response[:result],
      )
      assert_instrumentation_data({ method: "prompts/get" })
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

    test "#resources_list_handler sets the resources/list handler" do
      @server.resources_list_handler do
        [{ uri: "https://test_resource.invalid", name: "test-resource", title: "Test Resource", description: "Test resource" }]
      end

      request = {
        jsonrpc: "2.0",
        method: "resources/list",
        id: 1,
      }

      response = @server.handle(request)
      assert_equal(
        { resources: [{ uri: "https://test_resource.invalid", name: "test-resource", title: "Test Resource", description: "Test resource" }] },
        response[:result],
      )
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

    test "#resources_templates_list_handler sets the resources/templates/list handler" do
      @server.resources_templates_list_handler do
        [{ uriTemplate: "test_resource_template/{id}", name: "Test resource template", description: "a template" }]
      end

      request = {
        jsonrpc: "2.0",
        method: "resources/templates/list",
        id: 1,
      }

      response = @server.handle(request)
      assert_equal(
        {
          resourceTemplates: [
            {
              uriTemplate: "test_resource_template/{id}",
              name: "Test resource template",
              description: "a template",
            },
          ],
        },
        response[:result],
      )
      assert_instrumentation_data({ method: "resources/templates/list" })
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

      server = Server.new(name: "test_server", configuration:)

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
      assert_equal Configuration::DEFAULT_PROTOCOL_VERSION, response[:result][:protocolVersion]
    end

    test "server response does not include title when not configured" do
      server = Server.new(name: "test_server")
      request = {
        jsonrpc: "2.0",
        method: "initialize",
        id: 1,
      }

      response = server.handle(request)
      refute response[:result][:serverInfo].key?(:title)
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

    test "#define_tool adds a tool to the server" do
      @server.define_tool(
        name: "defined_tool",
        description: "Defined tool",
        input_schema: { type: "object", properties: { message: { type: "string" } }, required: ["message"] },
        meta: { foo: "bar" },
      ) do |message:|
        Tool::Response.new(message)
      end

      response = @server.handle({
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: "defined_tool", arguments: { message: "success" } },
        id: 1,
      })

      assert_equal({ content: "success", isError: false }, response[:result])
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

    test "tools/call handles missing arguments field" do
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
      assert_nil response[:error], "Expected no JSON-RPC error"
      assert response[:result][:isError]
      assert_includes response[:result][:content][0][:text], "Missing required arguments"
    end

    test "tools/call validates arguments against input schema when validate_tool_call_arguments is true" do
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
      assert_nil response[:error], "Expected no JSON-RPC error"
      assert response[:result][:isError]
      assert_includes response[:result][:content][0][:text], "Invalid arguments"
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
        def call(message:, server_context: nil)
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

    test "#notify_log_message raises RequestHandlerError when logging_message_notification is null" do
      server = Server.new(
        tools: [TestTool],
        configuration: Configuration.new(validate_tool_call_arguments: true),
      )

      response = server.handle(
        {
          jsonrpc: "2.0",
          method: "notifications/message",
          params: {
            level: "info",
            data: "test message",
          },
        },
      )

      assert_equal "2.0", response[:jsonrpc]
      assert_equal 1, response[:id]
      assert_equal(-32603, response[:error][:code])
      assert_includes response[:error][:data], "logging_message_notification must not be null"
    end

    test "#logging_level= raises RequestHandlerError when invalid log level is provided" do
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
  end
end
