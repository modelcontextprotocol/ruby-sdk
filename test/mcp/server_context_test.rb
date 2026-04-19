# frozen_string_literal: true

require "test_helper"

module MCP
  class ServerContextTest < ActiveSupport::TestCase
    test "ServerContext delegates method calls to the underlying context" do
      context = { user: "test_user" }
      progress = Progress.new(notification_target: mock, progress_token: nil)

      server_context = ServerContext.new(context, progress: progress, notification_target: mock)

      assert_equal "test_user", server_context[:user]
    end

    test "ServerContext respond_to? returns true for methods on the underlying context" do
      context = { user: "test_user" }
      progress = Progress.new(notification_target: mock, progress_token: nil)

      server_context = ServerContext.new(context, progress: progress, notification_target: mock)

      assert_respond_to server_context, :[]
      assert_respond_to server_context, :keys
    end

    test "ServerContext respond_to? returns false for methods not on the underlying context" do
      context = { user: "test_user" }
      progress = Progress.new(notification_target: mock, progress_token: nil)

      server_context = ServerContext.new(context, progress: progress, notification_target: mock)

      refute_respond_to server_context, :nonexistent_method
    end

    test "ServerContext raises NoMethodError for methods not on the underlying context" do
      context = { user: "test_user" }
      progress = Progress.new(notification_target: mock, progress_token: nil)

      server_context = ServerContext.new(context, progress: progress, notification_target: mock)

      assert_raises(NoMethodError) { server_context.nonexistent_method }
    end

    test "ServerContext#list_roots delegates to notification_target" do
      notification_target = mock
      notification_target.expects(:list_roots).with(
        related_request_id: nil,
      ).returns({ roots: [{ uri: "file:///project", name: "Project" }] })

      context = mock
      progress = Progress.new(notification_target: notification_target, progress_token: nil)

      server_context = ServerContext.new(context, progress: progress, notification_target: notification_target)

      result = server_context.list_roots

      assert_equal [{ uri: "file:///project", name: "Project" }], result[:roots]
    end

    test "ServerContext#list_roots raises NoMethodError when notification_target does not respond" do
      notification_target = mock
      context = mock
      progress = Progress.new(notification_target: notification_target, progress_token: nil)

      server_context = ServerContext.new(context, progress: progress, notification_target: notification_target)

      assert_raises(NoMethodError) { server_context.list_roots }
    end

    test "ServerContext#create_sampling_message delegates to notification_target over context" do
      notification_target = mock
      notification_target.expects(:create_sampling_message).with(
        messages: [{ role: "user", content: { type: "text", text: "Hello" } }],
        max_tokens: 100,
        related_request_id: nil,
      ).returns({ role: "assistant", content: { type: "text", text: "Hi" } })

      context = mock
      progress = Progress.new(notification_target: notification_target, progress_token: nil)

      server_context = ServerContext.new(context, progress: progress, notification_target: notification_target)

      result = server_context.create_sampling_message(
        messages: [{ role: "user", content: { type: "text", text: "Hello" } }],
        max_tokens: 100,
      )

      assert_equal "Hi", result[:content][:text]
    end

    test "ServerContext#create_sampling_message falls back to context when notification_target does not respond" do
      notification_target = mock
      context = mock
      context.expects(:create_sampling_message).with(
        messages: [{ role: "user", content: { type: "text", text: "Hello" } }],
        max_tokens: 100,
        related_request_id: nil,
      ).returns({ role: "assistant", content: { type: "text", text: "Fallback" } })

      progress = Progress.new(notification_target: notification_target, progress_token: nil)

      server_context = ServerContext.new(context, progress: progress, notification_target: notification_target)

      result = server_context.create_sampling_message(
        messages: [{ role: "user", content: { type: "text", text: "Hello" } }],
        max_tokens: 100,
      )

      assert_equal "Fallback", result[:content][:text]
    end

    test "ServerContext#create_form_elicitation delegates to notification_target" do
      notification_target = mock
      notification_target.expects(:create_form_elicitation).with(
        message: "Please provide your name",
        requested_schema: { type: "object", properties: { name: { type: "string" } } },
        related_request_id: nil,
      ).returns(action: "accept", content: { name: "test_user" })

      context = mock
      progress = Progress.new(notification_target: notification_target, progress_token: nil)

      server_context = ServerContext.new(context, progress: progress, notification_target: notification_target)

      result = server_context.create_form_elicitation(
        message: "Please provide your name",
        requested_schema: { type: "object", properties: { name: { type: "string" } } },
      )

      assert_equal "accept", result[:action]
    end

    test "ServerContext#create_url_elicitation delegates to notification_target" do
      notification_target = mock
      notification_target.expects(:create_url_elicitation).with(
        message: "Please authorize",
        url: "https://example.com/oauth",
        elicitation_id: "abc-123",
        related_request_id: nil,
      ).returns(action: "accept")

      context = mock
      progress = Progress.new(notification_target: notification_target, progress_token: nil)

      server_context = ServerContext.new(context, progress: progress, notification_target: notification_target)

      result = server_context.create_url_elicitation(
        message: "Please authorize",
        url: "https://example.com/oauth",
        elicitation_id: "abc-123",
      )

      assert_equal "accept", result[:action]
    end

    test "ServerContext#notify_elicitation_complete delegates to notification_target" do
      notification_target = mock
      notification_target.expects(:notify_elicitation_complete).with(elicitation_id: "abc-123")

      context = mock
      progress = Progress.new(notification_target: notification_target, progress_token: nil)

      server_context = ServerContext.new(context, progress: progress, notification_target: notification_target)

      server_context.notify_elicitation_complete(elicitation_id: "abc-123")
    end

    test "ServerContext delegates to custom object context" do
      context = Object.new
      def context.custom_method
        "custom_value"
      end
      progress = Progress.new(notification_target: mock, progress_token: nil)

      server_context = ServerContext.new(context, progress: progress, notification_target: mock)

      assert_equal "custom_value", server_context.custom_method
    end

    test "ServerContext#report_progress works with nil context" do
      progress = mock
      progress.expects(:report).with(50, total: 100, message: nil).once

      server_context = ServerContext.new(nil, progress: progress, notification_target: mock)
      server_context.report_progress(50, total: 100)
    end

    test "ServerContext#notify_log_message is a no-op when notification_target is nil" do
      progress = Progress.new(notification_target: nil, progress_token: nil)
      server_context = ServerContext.new(nil, progress: progress, notification_target: nil)

      assert_nothing_raised { server_context.notify_log_message(data: "test", level: "info") }
    end

    test "ServerContext#notify_resources_updated delegates to notification_target" do
      notification_target = mock
      notification_target.expects(:notify_resources_updated).with(uri: "test://resource-1").once

      progress = Progress.new(notification_target: notification_target, progress_token: nil)
      server_context = ServerContext.new(nil, progress: progress, notification_target: notification_target)

      server_context.notify_resources_updated(uri: "test://resource-1")
    end

    test "ServerContext#notify_resources_updated is a no-op when notification_target is nil" do
      progress = Progress.new(notification_target: nil, progress_token: nil)
      server_context = ServerContext.new(nil, progress: progress, notification_target: nil)

      assert_nothing_raised { server_context.notify_resources_updated(uri: "test://resource-1") }
    end

    # Tool without server_context parameter
    class SimpleToolWithoutContext < Tool
      tool_name "simple_without_context"
      description "A tool that doesn't use server_context"
      input_schema({ properties: { message: { type: "string" } }, required: ["message"] })

      class << self
        def call(message:)
          Tool::Response.new([
            { type: "text", content: "SimpleToolWithoutContext: #{message}" },
          ])
        end
      end
    end

    # Tool with optional server_context parameter
    class ToolWithOptionalContext < Tool
      tool_name "tool_with_optional_context"
      description "A tool with optional server_context"
      input_schema({ properties: { message: { type: "string" } }, required: ["message"] })

      class << self
        def call(message:, server_context: nil)
          user = server_context.respond_to?(:[]) ? server_context[:user] : nil
          context_info = user ? "with context: #{user}" : "no context"
          Tool::Response.new([
            { type: "text", content: "ToolWithOptionalContext: #{message} (#{context_info})" },
          ])
        end
      end
    end

    # Tool with required server_context parameter
    class ToolWithRequiredContext < Tool
      tool_name "tool_with_required_context"
      description "A tool that requires server_context"
      input_schema({ properties: { message: { type: "string" } }, required: ["message"] })

      class << self
        def call(message:, server_context:)
          Tool::Response.new([
            { type: "text", content: "ToolWithRequiredContext: #{message} for user #{server_context[:user]}" },
          ])
        end
      end
    end

    setup do
      @server_with_context = Server.new(
        name: "test_server",
        tools: [SimpleToolWithoutContext, ToolWithOptionalContext, ToolWithRequiredContext],
        server_context: { user: "test_user" },
      )

      @server_without_context = Server.new(
        name: "test_server_no_context",
        tools: [SimpleToolWithoutContext, ToolWithOptionalContext],
      )
    end

    test "tool without server_context parameter works when server has context" do
      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "simple_without_context",
          arguments: { message: "Hello" },
        },
      }

      response = @server_with_context.handle(request)

      assert response[:result]
      assert_equal "SimpleToolWithoutContext: Hello", response[:result][:content][0][:content]
    end

    test "tool with optional server_context receives context when server has it" do
      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "tool_with_optional_context",
          arguments: { message: "Hello" },
        },
      }

      response = @server_with_context.handle(request)

      assert response[:result]
      assert_equal "ToolWithOptionalContext: Hello (with context: test_user)",
        response[:result][:content][0][:content]
    end

    test "tool with optional server_context works when server has no context" do
      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "tool_with_optional_context",
          arguments: { message: "Hello" },
        },
      }

      response = @server_without_context.handle(request)

      assert response[:result]
      assert_equal "ToolWithOptionalContext: Hello (no context)",
        response[:result][:content][0][:content]
    end

    test "tool with required server_context receives context" do
      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "tool_with_required_context",
          arguments: { message: "Hello" },
        },
      }

      response = @server_with_context.handle(request)

      assert response[:result]
      assert_equal "ToolWithRequiredContext: Hello for user test_user",
        response[:result][:content][0][:content]
    end

    test "tool with required server_context returns protocol error in JSON-RPC format when server has no context" do
      server_no_context = Server.new(
        name: "test_server_no_context",
        tools: [ToolWithRequiredContext],
      )

      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "tool_with_required_context",
          arguments: { message: "Hello" },
        },
      }

      response = server_no_context.handle(request)

      assert_nil response[:result]
      assert_equal(-32603, response[:error][:code])
      assert_equal "Internal error", response[:error][:message]
      assert_match(/Internal error calling tool tool_with_required_context: /, response[:error][:data])
    end

    test "call_tool_with_args correctly detects server_context parameter presence" do
      # Tool without server_context
      refute SimpleToolWithoutContext.method(:call).parameters.any? { |_type, name| name == :server_context }

      # Tool with optional server_context
      assert ToolWithOptionalContext.method(:call).parameters.any? { |_type, name| name == :server_context }

      # Tool with required server_context
      assert ToolWithRequiredContext.method(:call).parameters.any? { |_type, name| name == :server_context }
    end

    test "tools can use splat kwargs to accept any arguments including server_context" do
      class FlexibleTool < Tool
        tool_name "flexible_tool"

        class << self
          def call(**kwargs)
            message = kwargs[:message]
            context = kwargs[:server_context]

            Tool::Response.new([
              {
                type: "text",
                content: "FlexibleTool: #{message} (context: #{context ? "present" : "absent"})",
              },
            ])
          end
        end
      end

      server = Server.new(
        name: "test_server",
        tools: [FlexibleTool],
        server_context: { user: "test_user" },
      )

      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "flexible_tool",
          arguments: { message: "Hello" },
        },
      }

      response = server.handle(request)

      assert response[:result]
      assert_equal "FlexibleTool: Hello (context: present)",
        response[:result][:content][0][:content]
    end

    # Prompt tests

    # Prompt without server_context parameter
    class SimplePromptWithoutContext < Prompt
      prompt_name "simple_prompt_without_context"
      description "A prompt that doesn't use server_context"
      arguments [Prompt::Argument.new(name: "message", required: true)]

      class << self
        def template(args)
          Prompt::Result.new(
            messages: [
              Prompt::Message.new(
                role: "user",
                content: Content::Text.new("SimplePromptWithoutContext: #{args[:message]}"),
              ),
            ],
          )
        end
      end
    end

    # Prompt with optional server_context parameter
    class PromptWithOptionalContext < Prompt
      prompt_name "prompt_with_optional_context"
      description "A prompt with optional server_context"
      arguments [Prompt::Argument.new(name: "message", required: true)]

      class << self
        def template(args, server_context: nil)
          user = server_context.respond_to?(:[]) ? server_context[:user] : nil
          context_info = user ? "with context: #{user}" : "no context"
          Prompt::Result.new(
            messages: [
              Prompt::Message.new(
                role: "user",
                content: Content::Text.new("PromptWithOptionalContext: #{args[:message]} (#{context_info})"),
              ),
            ],
          )
        end
      end
    end

    # Prompt with required server_context parameter
    class PromptWithRequiredContext < Prompt
      prompt_name "prompt_with_required_context"
      description "A prompt that requires server_context"
      arguments [Prompt::Argument.new(name: "message", required: true)]

      class << self
        def template(args, server_context:)
          Prompt::Result.new(
            messages: [
              Prompt::Message.new(
                role: "user",
                content: Content::Text.new(
                  "PromptWithRequiredContext: #{args[:message]} for user #{server_context[:user]}",
                ),
              ),
            ],
          )
        end
      end
    end

    test "prompt without server_context parameter works when server has context" do
      server = Server.new(
        name: "test_server",
        prompts: [SimplePromptWithoutContext],
        server_context: { user: "test_user" },
      )

      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "prompts/get",
        params: {
          name: "simple_prompt_without_context",
          arguments: { message: "Hello" },
        },
      }

      response = server.handle(request)

      assert response[:result]
      assert_equal "SimplePromptWithoutContext: Hello", response[:result][:messages][0][:content][:text]
    end

    test "prompt with optional server_context receives context when server has it" do
      server = Server.new(
        name: "test_server",
        prompts: [PromptWithOptionalContext],
        server_context: { user: "test_user" },
      )

      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "prompts/get",
        params: {
          name: "prompt_with_optional_context",
          arguments: { message: "Hello" },
        },
      }

      response = server.handle(request)

      assert response[:result]
      assert_equal "PromptWithOptionalContext: Hello (with context: test_user)",
        response[:result][:messages][0][:content][:text]
    end

    test "prompt with optional server_context works when server has no context" do
      server = Server.new(
        name: "test_server",
        prompts: [PromptWithOptionalContext],
      )

      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "prompts/get",
        params: {
          name: "prompt_with_optional_context",
          arguments: { message: "Hello" },
        },
      }

      response = server.handle(request)

      assert response[:result]
      assert_equal "PromptWithOptionalContext: Hello (no context)",
        response[:result][:messages][0][:content][:text]
    end

    test "prompt with required server_context receives context" do
      server = Server.new(
        name: "test_server",
        prompts: [PromptWithRequiredContext],
        server_context: { user: "test_user" },
      )

      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "prompts/get",
        params: {
          name: "prompt_with_required_context",
          arguments: { message: "Hello" },
        },
      }

      response = server.handle(request)

      assert response[:result]
      assert_equal "PromptWithRequiredContext: Hello for user test_user",
        response[:result][:messages][0][:content][:text]
    end

    test "prompts can use splat kwargs to accept any arguments including server_context" do
      class FlexiblePrompt < Prompt
        prompt_name "flexible_prompt"
        arguments [Prompt::Argument.new(name: "message", required: true)]

        class << self
          def template(args, **kwargs)
            message = args[:message]
            context = kwargs[:server_context]

            Prompt::Result.new(
              messages: [
                Prompt::Message.new(
                  role: "user",
                  content: Content::Text.new("FlexiblePrompt: #{message} (context: #{context ? "present" : "absent"})"),
                ),
              ],
            )
          end
        end
      end

      server = Server.new(
        name: "test_server",
        prompts: [FlexiblePrompt],
        server_context: { user: "test_user" },
      )

      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "prompts/get",
        params: {
          name: "flexible_prompt",
          arguments: { message: "Hello" },
        },
      }

      response = server.handle(request)

      assert response[:result]
      assert_equal "FlexiblePrompt: Hello (context: present)",
        response[:result][:messages][0][:content][:text]
    end

    test "tool receives _meta when provided in request params" do
      class ToolWithMeta < Tool
        tool_name "tool_with_meta"
        description "A tool that uses _meta"
        input_schema({ properties: { message: { type: "string" } }, required: ["message"] })

        class << self
          def call(message:, server_context:)
            meta_info = server_context.dig(:_meta, :provider, :metadata)
            Tool::Response.new([
              { type: "text", content: "Message: #{message}, Metadata: #{meta_info}" },
            ])
          end
        end
      end

      server = Server.new(
        name: "test_server",
        tools: [ToolWithMeta],
      )

      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "tool_with_meta",
          arguments: { message: "Hello" },
          _meta: {
            provider: {
              metadata: "test_value",
            },
          },
        },
      }

      response = server.handle(request)

      assert response[:result]
      assert_equal "Message: Hello, Metadata: test_value",
        response[:result][:content][0][:content]
    end

    test "_meta is nested within server_context" do
      class ToolWithNestedMeta < Tool
        tool_name "tool_with_nested_meta"
        description "A tool that uses nested _meta"
        input_schema({ properties: { message: { type: "string" } }, required: ["message"] })

        class << self
          def call(message:, server_context:)
            user = server_context[:user]
            session_id = server_context.dig(:_meta, :session_id)
            Tool::Response.new([
              { type: "text", content: "User: #{user}, Session: #{session_id}, Message: #{message}" },
            ])
          end
        end
      end

      server = Server.new(
        name: "test_server",
        tools: [ToolWithNestedMeta],
        server_context: { user: "test_user", original_field: "value" },
      )

      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "tool_with_nested_meta",
          arguments: { message: "Hello" },
          _meta: {
            session_id: "abc123",
          },
        },
      }

      response = server.handle(request)

      assert response[:result]
      assert_equal "User: test_user, Session: abc123, Message: Hello",
        response[:result][:content][0][:content]
    end

    test "_meta preserves original server_context" do
      class ToolPreservesContext < Tool
        tool_name "tool_preserves_context"
        description "A tool that checks context preservation"

        class << self
          def call(server_context:)
            priority = server_context[:priority]
            meta_priority = server_context.dig(:_meta, :priority)
            Tool::Response.new([
              { type: "text", content: "Context priority: #{priority}, Meta priority: #{meta_priority}" },
            ])
          end
        end
      end

      server = Server.new(
        name: "test_server",
        tools: [ToolPreservesContext],
        server_context: { priority: "low" },
      )

      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "tool_preserves_context",
          arguments: {},
          _meta: {
            priority: "high",
          },
        },
      }

      response = server.handle(request)

      assert response[:result]
      assert_equal "Context priority: low, Meta priority: high", response[:result][:content][0][:content]
    end

    test "prompt receives _meta when provided in request params" do
      class PromptWithMeta < Prompt
        prompt_name "prompt_with_meta"
        description "A prompt that uses _meta"
        arguments [Prompt::Argument.new(name: "message", required: true)]

        class << self
          def template(args, server_context:)
            meta_info = server_context.dig(:_meta, :request_id)
            Prompt::Result.new(
              messages: [
                Prompt::Message.new(
                  role: "user",
                  content: Content::Text.new("Message: #{args[:message]}, Request ID: #{meta_info}"),
                ),
              ],
            )
          end
        end
      end

      server = Server.new(
        name: "test_server",
        prompts: [PromptWithMeta],
      )

      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "prompts/get",
        params: {
          name: "prompt_with_meta",
          arguments: { message: "Hello" },
          _meta: {
            request_id: "req_12345",
          },
        },
      }

      response = server.handle(request)

      assert response[:result]
      assert_equal "Message: Hello, Request ID: req_12345",
        response[:result][:messages][0][:content][:text]
    end

    test "non-Hash server_context is preserved when _meta is present" do
      server_obj = Object.new
      def server_obj.custom_method
        "custom_value"
      end

      tool_class = Class.new(Tool) do
        tool_name "tool_with_non_hash_context"

        define_singleton_method(:call) do |server_context:, **_args|
          Tool::Response.new([
            { type: "text", content: "custom: #{server_context.custom_method}" },
          ])
        end
      end

      server = Server.new(
        name: "test_server",
        tools: [tool_class],
        server_context: server_obj,
      )

      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "tool_with_non_hash_context",
          arguments: {},
          _meta: { progressToken: "token-1" },
        },
      }

      response = server.handle(request)

      assert response[:result]
      assert_equal "custom: custom_value", response[:result][:content][0][:content]
    end

    test "_meta is nested within server_context for prompts" do
      class PromptWithNestedContext < Prompt
        prompt_name "prompt_with_nested_context"
        description "A prompt that uses nested context"
        arguments [Prompt::Argument.new(name: "message", required: true)]

        class << self
          def template(args, server_context:)
            user = server_context[:user]
            trace_id = server_context.dig(:_meta, :trace_id)
            Prompt::Result.new(
              messages: [
                Prompt::Message.new(
                  role: "user",
                  content: Content::Text.new("User: #{user}, Trace: #{trace_id}, Message: #{args[:message]}"),
                ),
              ],
            )
          end
        end
      end

      server = Server.new(
        name: "test_server",
        prompts: [PromptWithNestedContext],
        server_context: { user: "prompt_user" },
      )

      request = {
        jsonrpc: "2.0",
        id: 1,
        method: "prompts/get",
        params: {
          name: "prompt_with_nested_context",
          arguments: { message: "World" },
          _meta: {
            trace_id: "trace_xyz789",
          },
        },
      }

      response = server.handle(request)

      assert response[:result]
      assert_equal "User: prompt_user, Trace: trace_xyz789, Message: World",
        response[:result][:messages][0][:content][:text]
    end
  end
end
