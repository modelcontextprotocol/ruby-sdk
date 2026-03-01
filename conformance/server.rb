# frozen_string_literal: true

require "rackup"
require "json"
require "uri"
require_relative "../lib/mcp"

module Conformance
  # 1x1 red PNG pixel (matches TypeScript SDK and Python SDK)
  BASE64_1X1_PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

  # Minimal WAV file (matches TypeScript SDK and Python SDK)
  BASE64_MINIMAL_WAV = "UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAAB9AAACABAAZGF0YQIAAAA="

  module Tools
    class TestSimpleText < MCP::Tool
      tool_name "test_simple_text"
      description "A tool that returns simple text content"

      class << self
        def call(**_args)
          MCP::Tool::Response.new([MCP::Content::Text.new("This is a simple text response for testing.").to_h])
        end
      end
    end

    class TestImageContent < MCP::Tool
      tool_name "test_image_content"
      description "A tool that returns image content"

      class << self
        def call(**_args)
          MCP::Tool::Response.new([MCP::Content::Image.new(BASE64_1X1_PNG, "image/png").to_h])
        end
      end
    end

    class TestAudioContent < MCP::Tool
      tool_name "test_audio_content"
      description "A tool that returns audio content"

      class << self
        def call(**_args)
          MCP::Tool::Response.new([MCP::Content::Audio.new(BASE64_MINIMAL_WAV, "audio/wav").to_h])
        end
      end
    end

    class TestEmbeddedResource < MCP::Tool
      tool_name "test_embedded_resource"
      description "A tool that returns embedded resource content"

      class << self
        def call(**_args)
          text_contents = MCP::Resource::TextContents.new(
            uri: "test://embedded-resource",
            mime_type: "text/plain",
            text: "This is an embedded resource content.",
          )
          MCP::Tool::Response.new([MCP::Content::EmbeddedResource.new(text_contents).to_h])
        end
      end
    end

    class TestMultipleContentTypes < MCP::Tool
      tool_name "test_multiple_content_types"
      description "A tool that returns multiple content types"

      class << self
        def call(**_args)
          MCP::Tool::Response.new([
            MCP::Content::Text.new("Multiple content types test:").to_h,
            MCP::Content::Image.new(BASE64_1X1_PNG, "image/png").to_h,
            MCP::Content::EmbeddedResource.new(
              MCP::Resource::TextContents.new(
                uri: "test://mixed-content-resource",
                mime_type: "application/json",
                text: '{"test":"data","value":123}',
              ),
            ).to_h,
          ])
        end
      end
    end

    class TestErrorHandling < MCP::Tool
      tool_name "test_error_handling"
      description "A tool that intentionally returns an error for testing"

      class << self
        def call(**_args)
          MCP::Tool::Response.new(
            [MCP::Content::Text.new("This tool intentionally returns an error for testing").to_h],
            error: true,
          )
        end
      end
    end

    class JsonSchema202012Tool < MCP::Tool
      tool_name "json_schema_2020_12_tool"
      description "Tool with JSON Schema 2020-12 features"
      input_schema(
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$defs": {
          address: {
            type: "object",
            properties: {
              street: { type: "string" },
              city: { type: "string" },
            },
          },
        },
        properties: {
          name: { type: "string" },
          address: { "$ref": "#/$defs/address" },
        },
        additionalProperties: false,
      )

      class << self
        def call(**_args)
          MCP::Tool::Response.new([MCP::Content::Text.new("Processed with JSON Schema 2020-12").to_h])
        end
      end
    end

    class TestToolWithLogging < MCP::Tool
      tool_name "test_tool_with_logging"
      description "A tool that sends log messages during execution"

      class << self
        def call(server_context:, **_args)
          server_context.notify_log_message(data: "Tool execution started", level: "info", logger: "test_logger")
          sleep(0.05) # Required by the conformance test to verify clients handle interleaved notifications (same as TypeScript SDK).
          server_context.notify_log_message(data: "Tool processing data", level: "info", logger: "test_logger")
          sleep(0.05) # Same as above.
          server_context.notify_log_message(data: "Tool execution completed", level: "info", logger: "test_logger")
          MCP::Tool::Response.new([MCP::Content::Text.new("Logging complete (3 messages sent)").to_h])
        end
      end
    end

    # test_tool_with_progress: the actual progress dispatch is in `tools_call_handler`
    class TestToolWithProgress < MCP::Tool
      tool_name "test_tool_with_progress"
      description "A tool that reports progress notifications"

      class << self
        def call(**_args)
          MCP::Tool::Response.new([MCP::Content::Text.new("Progress complete").to_h])
        end
      end
    end

    # TODO: Implement when `Transport` supports server-to-client requests.
    class TestSampling < MCP::Tool
      tool_name "test_sampling"
      description "A tool that requests LLM sampling from the client"
      input_schema(
        properties: { prompt: { type: "string" } },
        required: ["prompt"],
      )

      class << self
        def call(prompt:)
          MCP::Tool::Response.new(
            [MCP::Content::Text.new("Sampling not supported in this SDK version").to_h],
            error: true,
          )
        end
      end
    end

    # TODO: Implement when `Transport` supports server-to-client requests.
    class TestElicitation < MCP::Tool
      tool_name "test_elicitation"
      description "A tool that requests user input from the client"
      input_schema(
        properties: { message: { type: "string" } },
        required: ["message"],
      )

      class << self
        def call(message:)
          MCP::Tool::Response.new(
            [MCP::Content::Text.new("Elicitation not supported in this SDK version").to_h],
            error: true,
          )
        end
      end
    end

    # TODO: Implement when `Transport` supports server-to-client requests.
    class TestElicitationSep1034Defaults < MCP::Tool
      tool_name "test_elicitation_sep1034_defaults"
      description "A tool that tests elicitation with default values"

      class << self
        def call(**_args)
          MCP::Tool::Response.new(
            [MCP::Content::Text.new("Elicitation not supported in this SDK version").to_h],
            error: true,
          )
        end
      end
    end

    # TODO: Implement when `Transport` supports server-to-client requests.
    class TestElicitationSep1330Enums < MCP::Tool
      tool_name "test_elicitation_sep1330_enums"
      description "A tool that tests elicitation with enum schemas"

      class << self
        def call(**_args)
          MCP::Tool::Response.new(
            [MCP::Content::Text.new("Elicitation not supported in this SDK version").to_h],
            error: true,
          )
        end
      end
    end

    class TestReconnection < MCP::Tool
      tool_name "test_reconnection"
      description "A tool that triggers SSE stream closure to test client reconnection behavior"

      class << self
        def call(**_args)
          MCP::Tool::Response.new([MCP::Content::Text.new("Reconnection test completed").to_h])
        end
      end
    end
  end

  module Prompts
    class TestSimplePrompt < MCP::Prompt
      prompt_name "test_simple_prompt"
      description "A simple prompt for testing with no arguments"

      class << self
        def template(_args, server_context: nil)
          MCP::Prompt::Result.new(
            messages: [
              MCP::Prompt::Message.new(
                role: "user",
                content: MCP::Content::Text.new("This is a simple prompt for testing."),
              ),
            ],
          )
        end
      end
    end

    class TestPromptWithArguments < MCP::Prompt
      prompt_name "test_prompt_with_arguments"
      description "A prompt with required arguments for testing"
      arguments [
        MCP::Prompt::Argument.new(name: "arg1", description: "First test argument", required: true),
        MCP::Prompt::Argument.new(name: "arg2", description: "Second test argument", required: true),
      ]

      class << self
        def template(args, server_context: nil)
          arg1 = args.dig(:arg1) || args.dig("arg1") || ""
          arg2 = args.dig(:arg2) || args.dig("arg2") || ""
          MCP::Prompt::Result.new(
            messages: [
              MCP::Prompt::Message.new(
                role: "user",
                content: MCP::Content::Text.new("Prompt with arguments: arg1='#{arg1}', arg2='#{arg2}'"),
              ),
            ],
          )
        end
      end
    end

    class TestPromptWithEmbeddedResource < MCP::Prompt
      prompt_name "test_prompt_with_embedded_resource"
      description "A prompt with an embedded resource for testing"
      arguments [
        MCP::Prompt::Argument.new(name: "resourceUri", description: "URI of the resource to embed", required: true),
      ]

      class << self
        def template(args, server_context: nil)
          resource_uri = args.dig(:resourceUri) || args.dig("resourceUri") || "test://example-resource"
          MCP::Prompt::Result.new(
            messages: [
              MCP::Prompt::Message.new(
                role: "user",
                content: MCP::Content::EmbeddedResource.new(
                  MCP::Resource::TextContents.new(
                    uri: resource_uri,
                    mime_type: "text/plain",
                    text: "Embedded resource content for testing.",
                  ),
                ),
              ),
              MCP::Prompt::Message.new(
                role: "user",
                content: MCP::Content::Text.new("Please process the embedded resource above."),
              ),
            ],
          )
        end
      end
    end

    class TestPromptWithImage < MCP::Prompt
      prompt_name "test_prompt_with_image"
      description "A prompt with image content for testing"

      class << self
        def template(_args, server_context: nil)
          MCP::Prompt::Result.new(
            messages: [
              MCP::Prompt::Message.new(
                role: "user",
                content: MCP::Content::Image.new(BASE64_1X1_PNG, "image/png"),
              ),
              MCP::Prompt::Message.new(
                role: "user",
                content: MCP::Content::Text.new("Please analyze the image above."),
              ),
            ],
          )
        end
      end
    end
  end

  class Server
    DEFAULT_PORT = 9292

    class DnsRebindingProtection
      LOCALHOST_PATTERNS = /\A(localhost|127\.0\.0\.1|\[::1\]|::1)(:\d+)?\z/i.freeze

      def initialize(app)
        @app = app
      end

      def call(env)
        host = env["HTTP_HOST"] || env["SERVER_NAME"] || ""

        unless localhost?(host)
          return [
            403,
            { "Content-Type" => "application/json" },
            [{ error: "Forbidden: DNS rebinding protection - invalid Host header '#{host}'" }.to_json],
          ]
        end

        origin = env["HTTP_ORIGIN"]
        if origin && !origin.empty?
          begin
            origin_host = URI.parse(origin).host.to_s
            unless localhost?(origin_host)
              return [
                403,
                { "Content-Type" => "application/json" },
                [{ error: "Forbidden: DNS rebinding protection - invalid Origin '#{origin}'" }.to_json],
              ]
            end
          rescue URI::InvalidURIError
            return [
              403,
              { "Content-Type" => "application/json" },
              [{ error: "Forbidden: invalid Origin header" }.to_json],
            ]
          end
        end

        @app.call(env)
      end

      private

      def localhost?(host)
        host.empty? || host.match?(LOCALHOST_PATTERNS)
      end
    end

    def initialize(port: DEFAULT_PORT)
      @port = port
    end

    def start
      server = build_server
      transport = build_transport(server)
      configure_handlers(server)
      rack_app = build_rack_app(transport)

      puts <<~MESSAGE
        MCP Conformance Server starting on http://localhost:#{@port}/mcp
        Use Ctrl-C to stop
      MESSAGE

      Rackup::Handler.get("puma").run(rack_app, Port: @port, Host: "localhost", Silent: true)
    end

    private

    def build_server
      MCP::Server.new(
        name: "ruby-sdk-conformance-server",
        version: MCP::VERSION,
        tools: [
          Tools::TestSimpleText,
          Tools::TestImageContent,
          Tools::TestAudioContent,
          Tools::TestEmbeddedResource,
          Tools::TestMultipleContentTypes,
          Tools::TestErrorHandling,
          Tools::JsonSchema202012Tool,
          Tools::TestToolWithLogging,
          Tools::TestToolWithProgress,
          Tools::TestSampling,
          Tools::TestElicitation,
          Tools::TestElicitationSep1034Defaults,
          Tools::TestElicitationSep1330Enums,
          Tools::TestReconnection,
        ],
        prompts: [
          Prompts::TestSimplePrompt,
          Prompts::TestPromptWithArguments,
          Prompts::TestPromptWithEmbeddedResource,
          Prompts::TestPromptWithImage,
        ],
        resources: resources,
        resource_templates: resource_templates,
        capabilities: {
          tools: { listChanged: true },
          prompts: { listChanged: true },
          resources: { listChanged: true, subscribe: true },
          logging: {},
          completions: {},
        },
      )
    end

    def resources
      [
        MCP::Resource.new(
          uri: "test://static-text",
          name: "static-text",
          description: "A static text resource for testing",
          mime_type: "text/plain",
        ),
        MCP::Resource.new(
          uri: "test://static-binary",
          name: "static-binary",
          description: "A static binary (PNG) resource for testing",
          mime_type: "image/png",
        ),
        MCP::Resource.new(
          uri: "test://watched-resource",
          name: "watched-resource",
          description: "A resource for subscription testing",
          mime_type: "text/plain",
        ),
      ]
    end

    def resource_templates
      [
        MCP::ResourceTemplate.new(
          uri_template: "test://template/{id}/data",
          name: "template-resource",
          description: "A parameterized resource template for testing",
          mime_type: "application/json",
        ),
      ]
    end

    def build_transport(server)
      transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)
      server.transport = transport
      transport
    end

    def configure_handlers(server)
      server.logging_message_notification = MCP::LoggingMessageNotification.new(level: "debug")
      server.server_context = server

      configure_resources_read_handler(server)
    end

    def configure_resources_read_handler(server)
      server.resources_read_handler do |params|
        uri = params[:uri].to_s

        case uri
        when "test://static-text"
          [
            MCP::Resource::TextContents.new(
              text: "This is the content of the static text resource.",
              uri: uri,
              mime_type: "text/plain",
            ).to_h,
          ]
        when "test://static-binary"
          [
            MCP::Resource::BlobContents.new(
              data: BASE64_1X1_PNG,
              uri: uri,
              mime_type: "image/png",
            ).to_h,
          ]
        when %r{\Atest://template/(.+)/data\z}
          id = Regexp.last_match(1)
          content = { id: id, templateTest: true, data: "Data for ID: #{id}" }.to_json

          [
            MCP::Resource::TextContents.new(
              text: content,
              uri: uri,
              mime_type: "application/json",
            ).to_h,
          ]
        else
          []
        end
      end
    end

    def build_rack_app(transport)
      mcp_app = proc do |env|
        request = Rack::Request.new(env)

        if request.path_info == "/health"
          [200, { "Content-Type" => "application/json" }, ['{"status":"ok"}']]
        elsif request.path_info == "/mcp" || request.path_info == "/"
          transport.handle_request(request)
        else
          [404, { "Content-Type" => "application/json" }, ['{"error":"Not found"}']]
        end
      end

      Rack::Builder.new do
        use(DnsRebindingProtection)
        run(mcp_app)
      end
    end
  end
end
