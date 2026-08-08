# frozen_string_literal: true

require "rackup"
require "json"
require "securerandom"
require "set"
require "uri"
require_relative "../lib/mcp"

module Conformance
  # 1x1 red PNG pixel (matches TypeScript SDK and Python SDK)
  BASE64_1X1_PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

  # Minimal WAV file (matches TypeScript SDK and Python SDK)
  BASE64_MINIMAL_WAV = "UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAAB9AAACABAAZGF0YQIAAAA="

  # SEP-2322 MRTR fixture helpers. A retried request re-runs its handler from the start,
  # so every round reads the client's earlier answers back through these.
  module Mrtr
    module_function

    # The transport parses JSON with symbolized keys, but retries may also arrive through
    # `Server#handle` with string keys; tolerate both like the SDK's own readers.
    def read(hash, key)
      return unless hash.is_a?(Hash)

      value = hash[key.to_sym]
      value.nil? ? hash[key.to_s] : value
    end

    # The `content` of an accepted `elicitation/create` response, or `nil` for a declined,
    # malformed, or missing one (a `nil` return re-requests the input).
    def accepted_content(response)
      content = read(response, :content)
      content if read(response, :action) == "accept" && content.is_a?(Hash)
    end

    # The `text` of a `sampling/createMessage` response, or `nil` when malformed.
    def sampled_text(response)
      text = read(read(response, :content), :text)
      text if text.is_a?(String)
    end

    def parse_state(request_state)
      return unless request_state.is_a?(String)

      parsed = JSON.parse(request_state)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end
  end

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

    class TestToolWithProgress < MCP::Tool
      tool_name "test_tool_with_progress"
      description "A tool that reports progress notifications"

      class << self
        def call(server_context:, **_args)
          server_context.report_progress(0, total: 100)
          server_context.report_progress(50, total: 100)
          server_context.report_progress(100, total: 100)

          MCP::Tool::Response.new([MCP::Content::Text.new("Progress complete").to_h])
        end
      end
    end

    class TestSampling < MCP::Tool
      tool_name "test_sampling"
      description "A tool that requests LLM sampling from the client"
      input_schema(
        properties: { prompt: { type: "string" } },
        required: ["prompt"],
      )

      class << self
        def call(prompt:, server_context:)
          result = server_context.create_sampling_message(
            messages: [{ role: "user", content: { type: "text", text: prompt } }],
            max_tokens: 100,
          )
          model = result[:model] || "unknown"
          text = result.dig(:content, :text) || ""

          MCP::Tool::Response.new([MCP::Content::Text.new("LLM response: #{text} (model: #{model})").to_h])
        end
      end
    end

    class TestElicitation < MCP::Tool
      tool_name "test_elicitation"
      description "A tool that requests user input from the client"
      input_schema(
        properties: { message: { type: "string" } },
        required: ["message"],
      )

      class << self
        def call(server_context:, message:)
          result = server_context.create_form_elicitation(
            message: message,
            requested_schema: {
              type: "object",
              properties: {
                username: { type: "string", description: "User's response" },
                email: { type: "string", description: "User's email address" },
              },
              required: ["username", "email"],
            },
          )
          MCP::Tool::Response.new([MCP::Content::Text.new("User response: #{result}").to_h])
        end
      end
    end

    class TestElicitationSep1034Defaults < MCP::Tool
      tool_name "test_elicitation_sep1034_defaults"
      description "A tool that tests elicitation with default values"

      class << self
        def call(server_context:, **_args)
          result = server_context.create_form_elicitation(
            message: "Please provide your information (with defaults)",
            requested_schema: {
              type: "object",
              properties: {
                name: { type: "string", default: "John Doe" },
                age: { type: "integer", default: 30 },
                score: { type: "number", default: 95.5 },
                status: MCP::Elicitation::EnumSchema.untitled_single_select(
                  values: ["active", "inactive", "pending"], default: "active",
                ).to_h,
                verified: { type: "boolean", default: true },
              },
            },
          )
          MCP::Tool::Response.new([MCP::Content::Text.new("Elicitation result: #{result}").to_h])
        end
      end
    end

    class TestElicitationSep1330Enums < MCP::Tool
      tool_name "test_elicitation_sep1330_enums"
      description "A tool that tests elicitation with enum schemas"

      class << self
        def call(server_context:, **_args)
          # Built with the SEP-1330 builders so the conformance run exercises the same schemas
          # the SDK produces for users.
          result = server_context.create_form_elicitation(
            message: "Please select options",
            requested_schema: {
              type: "object",
              properties: {
                untitledSingle: MCP::Elicitation::EnumSchema.untitled_single_select(
                  values: ["option1", "option2", "option3"],
                ).to_h,
                titledSingle: MCP::Elicitation::EnumSchema.titled_single_select(
                  options: [
                    { value: "value1", title: "First Option" },
                    { value: "value2", title: "Second Option" },
                    { value: "value3", title: "Third Option" },
                  ],
                ).to_h,
                legacyEnum: MCP::Elicitation::EnumSchema.legacy_titled(
                  values: ["opt1", "opt2", "opt3"],
                  value_titles: ["Option One", "Option Two", "Option Three"],
                ).to_h,
                untitledMulti: MCP::Elicitation::EnumSchema.untitled_multi_select(
                  values: ["option1", "option2", "option3"],
                ).to_h,
                titledMulti: MCP::Elicitation::EnumSchema.titled_multi_select(
                  options: [
                    { value: "value1", title: "First Choice" },
                    { value: "value2", title: "Second Choice" },
                    { value: "value3", title: "Third Choice" },
                  ],
                ).to_h,
              },
            },
          )
          MCP::Tool::Response.new([MCP::Content::Text.new("Elicitation result: #{result}").to_h])
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

    class TestMissingCapability < MCP::Tool
      tool_name "test_missing_capability"
      description "A tool that requires the sampling client capability (SEP-2575)"

      class << self
        def call(server_context:, **_args)
          server_context.require_client_capability!(:sampling)

          MCP::Tool::Response.new([MCP::Content::Text.new("Sampling capability is declared").to_h])
        end
      end
    end

    class TestStreamingElicitation < MCP::Tool
      tool_name "test_streaming_elicitation"
      description "A tool whose response stream carries only notifications, never independent requests (SEP-2575)"

      class << self
        def call(server_context:, **_args)
          # No independent server-to-client request is ever written to the response stream;
          # the progress notification only goes out when the request carried a progressToken.
          server_context.report_progress(50, total: 100)

          MCP::Tool::Response.new([MCP::Content::Text.new("Streaming complete").to_h])
        end
      end
    end

    class TestInputRequiredResultElicitation < MCP::Tool
      tool_name "test_input_required_result_elicitation"
      description "A tool that asks for the user's name through an input_required result (SEP-2322)"

      class << self
        def call(server_context:, **_args)
          content = Mrtr.accepted_content(server_context.input_response("user_name"))
          name = content && Mrtr.read(content, :name)

          unless name.is_a?(String)
            return MCP::Server::InputRequiredResult.new(
              input_requests: {
                user_name: {
                  method: "elicitation/create",
                  params: {
                    message: "What is your name?",
                    requestedSchema: {
                      type: "object",
                      properties: { name: { type: "string" } },
                      required: ["name"],
                    },
                  },
                },
              },
            )
          end

          MCP::Tool::Response.new([MCP::Content::Text.new("Hello, #{name}!").to_h])
        end
      end
    end

    class TestInputRequiredResultSampling < MCP::Tool
      tool_name "test_input_required_result_sampling"
      description "A tool that asks for an LLM completion through an input_required result (SEP-2322)"

      class << self
        def call(server_context:, **_args)
          text = Mrtr.sampled_text(server_context.input_response("sample_request"))

          unless text
            return MCP::Server::InputRequiredResult.new(
              input_requests: {
                sample_request: {
                  method: "sampling/createMessage",
                  params: {
                    messages: [{ role: "user", content: { type: "text", text: "What is the capital of France?" } }],
                    maxTokens: 100,
                  },
                },
              },
            )
          end

          MCP::Tool::Response.new([MCP::Content::Text.new("Sampled: #{text}").to_h])
        end
      end
    end

    class TestInputRequiredResultListRoots < MCP::Tool
      tool_name "test_input_required_result_list_roots"
      description "A tool that asks for the client's roots through an input_required result (SEP-2322)"

      class << self
        def call(server_context:, **_args)
          roots = Mrtr.read(server_context.input_response("roots_request"), :roots)

          unless roots.is_a?(Array)
            return MCP::Server::InputRequiredResult.new(
              input_requests: { roots_request: { method: "roots/list" } },
            )
          end

          uris = roots.filter_map { |root| Mrtr.read(root, :uri) }
          MCP::Tool::Response.new([MCP::Content::Text.new("Roots: #{uris.join(", ")}").to_h])
        end
      end
    end

    class TestInputRequiredResultRequestState < MCP::Tool
      tool_name "test_input_required_result_request_state"
      description "A tool whose input_required result carries an opaque requestState (SEP-2322)"

      class << self
        def call(server_context:, **_args)
          state = Mrtr.parse_state(server_context.request_state)
          confirmed = Mrtr.accepted_content(server_context.input_response("confirm"))

          if state && state["kind"] == "request-state" && confirmed
            return MCP::Tool::Response.new([MCP::Content::Text.new("state-ok: requestState validated").to_h])
          end

          MCP::Server::InputRequiredResult.new(
            input_requests: {
              confirm: {
                method: "elicitation/create",
                params: {
                  message: "Confirm to continue",
                  requestedSchema: {
                    type: "object",
                    properties: { ok: { type: "boolean" } },
                  },
                },
              },
            },
            request_state: JSON.generate({ kind: "request-state", nonce: SecureRandom.hex(8) }),
          )
        end
      end
    end

    class TestInputRequiredResultMultipleInputs < MCP::Tool
      tool_name "test_input_required_result_multiple_inputs"
      description "A tool that embeds elicitation, sampling, and roots/list inputs in one input_required result (SEP-2322)"

      class << self
        def call(server_context:, **_args)
          content = Mrtr.accepted_content(server_context.input_response("user_name"))
          name = content && Mrtr.read(content, :name)
          greeting = Mrtr.sampled_text(server_context.input_response("greeting"))
          roots = Mrtr.read(server_context.input_response("client_roots"), :roots)

          if name.is_a?(String) && greeting && roots.is_a?(Array)
            return MCP::Tool::Response.new(
              [MCP::Content::Text.new("#{greeting} #{name} (#{roots.length} roots)").to_h],
            )
          end

          MCP::Server::InputRequiredResult.new(
            input_requests: {
              user_name: {
                method: "elicitation/create",
                params: {
                  message: "What is your name?",
                  requestedSchema: {
                    type: "object",
                    properties: { name: { type: "string" } },
                    required: ["name"],
                  },
                },
              },
              greeting: {
                method: "sampling/createMessage",
                params: {
                  messages: [{ role: "user", content: { type: "text", text: "Write a one-word greeting" } }],
                  maxTokens: 50,
                },
              },
              client_roots: { method: "roots/list" },
            },
            request_state: JSON.generate({ kind: "multiple-inputs" }),
          )
        end
      end
    end

    class TestInputRequiredResultMultiRound < MCP::Tool
      tool_name "test_input_required_result_multi_round"
      description "A tool that needs two elicitation rounds before completing (SEP-2322)"

      class << self
        def call(server_context:, **_args)
          state = Mrtr.parse_state(server_context.request_state)

          case state && state["round"]
          when 1
            content = Mrtr.accepted_content(server_context.input_response("user_name"))
            name = content && Mrtr.read(content, :name)
            return second_round(name) if name.is_a?(String)
          when 2
            content = Mrtr.accepted_content(server_context.input_response("favorite_color"))
            color = content && Mrtr.read(content, :color)
            if color.is_a?(String)
              return MCP::Tool::Response.new([MCP::Content::Text.new("#{state["name"]} likes #{color}").to_h])
            end
          end

          first_round
        end

        private

        def first_round
          MCP::Server::InputRequiredResult.new(
            input_requests: {
              user_name: {
                method: "elicitation/create",
                params: {
                  message: "What is your name?",
                  requestedSchema: {
                    type: "object",
                    properties: { name: { type: "string" } },
                    required: ["name"],
                  },
                },
              },
            },
            request_state: JSON.generate({ round: 1 }),
          )
        end

        def second_round(name)
          MCP::Server::InputRequiredResult.new(
            input_requests: {
              favorite_color: {
                method: "elicitation/create",
                params: {
                  message: "What is your favorite color?",
                  requestedSchema: {
                    type: "object",
                    properties: { color: { type: "string" } },
                    required: ["color"],
                  },
                },
              },
            },
            request_state: JSON.generate({ round: 2, name: name }),
          )
        end
      end
    end

    class TestInputRequiredResultTamperedState < MCP::Tool
      tool_name "test_input_required_result_tampered_state"
      description "A tool whose sealed requestState rejects tampered echoes (SEP-2322)"

      class << self
        # A tampered `requestState` never reaches this handler: the server-level unsealing rejects it with -32602
        # before dispatch, so the tool body is a plain MRTR flow.
        def call(server_context:, **_args)
          state = Mrtr.parse_state(server_context.request_state)
          confirmed = Mrtr.accepted_content(server_context.input_response("confirm"))

          if state && state["kind"] == "tamper-check" && confirmed
            return MCP::Tool::Response.new([MCP::Content::Text.new("requestState integrity verified").to_h])
          end

          MCP::Server::InputRequiredResult.new(
            input_requests: {
              confirm: {
                method: "elicitation/create",
                params: {
                  message: "Confirm to continue",
                  requestedSchema: {
                    type: "object",
                    properties: { ok: { type: "boolean" } },
                  },
                },
              },
            },
            request_state: JSON.generate({ kind: "tamper-check", nonce: SecureRandom.hex(8) }),
          )
        end
      end
    end

    class TestInputRequiredResultCapabilities < MCP::Tool
      tool_name "test_input_required_result_capabilities"
      description "A tool that only embeds input requests the client's declared capabilities can fulfill (SEP-2322)"

      class << self
        def call(server_context:, **_args)
          capabilities = server_context.client_capabilities || {}
          elicited = Mrtr.accepted_content(server_context.input_response("elicit_input"))
          sampled = Mrtr.sampled_text(server_context.input_response("sample_input"))

          requests = {}
          if Mrtr.read(capabilities, :elicitation) && !elicited
            requests[:elicit_input] = {
              method: "elicitation/create",
              params: {
                message: "Provide a value",
                requestedSchema: {
                  type: "object",
                  properties: { value: { type: "string" } },
                },
              },
            }
          end
          if Mrtr.read(capabilities, :sampling) && !sampled
            requests[:sample_input] = {
              method: "sampling/createMessage",
              params: {
                messages: [{ role: "user", content: { type: "text", text: "Say hello" } }],
                maxTokens: 50,
              },
            }
          end

          if requests.empty?
            MCP::Tool::Response.new(
              [MCP::Content::Text.new("Inputs: elicit=#{!elicited.nil?}, sample=#{!sampled.nil?}").to_h],
            )
          else
            MCP::Server::InputRequiredResult.new(input_requests: requests)
          end
        end
      end
    end

    class TestLoggingTool < MCP::Tool
      tool_name "test_logging_tool"
      description "A tool that logs only for requests opting in via the _meta logLevel (SEP-2575)"

      class << self
        def call(server_context:, **_args)
          # On modern requests the notification is dropped unless `io.modelcontextprotocol/logLevel` authorized it,
          # so the call itself is unconditional.
          server_context.notify_log_message(data: "Log level honored", level: "info", logger: "conformance")

          MCP::Tool::Response.new([MCP::Content::Text.new("Logging evaluated").to_h])
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

    class TestInputRequiredResultPrompt < MCP::Prompt
      prompt_name "test_input_required_result_prompt"
      description "A prompt that asks for user context through an input_required result (SEP-2322)"

      class << self
        def template(_args, server_context: nil)
          content = server_context && Mrtr.accepted_content(server_context.input_response("user_context"))
          context = content && Mrtr.read(content, :context)

          unless context.is_a?(String)
            return MCP::Server::InputRequiredResult.new(
              input_requests: {
                user_context: {
                  method: "elicitation/create",
                  params: {
                    message: "Provide context for the prompt",
                    requestedSchema: {
                      type: "object",
                      properties: { context: { type: "string" } },
                      required: ["context"],
                    },
                  },
                },
              },
            )
          end

          MCP::Prompt::Result.new(
            messages: [
              MCP::Prompt::Message.new(
                role: "user",
                content: MCP::Content::Text.new("Context: #{context}"),
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
      transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)
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
          Tools::TestMissingCapability,
          Tools::TestInputRequiredResultElicitation,
          Tools::TestInputRequiredResultSampling,
          Tools::TestInputRequiredResultListRoots,
          Tools::TestInputRequiredResultRequestState,
          Tools::TestInputRequiredResultMultipleInputs,
          Tools::TestInputRequiredResultMultiRound,
          Tools::TestInputRequiredResultTamperedState,
          Tools::TestInputRequiredResultCapabilities,
          Tools::TestStreamingElicitation,
          Tools::TestLoggingTool,
        ],
        prompts: [
          Prompts::TestSimplePrompt,
          Prompts::TestPromptWithArguments,
          Prompts::TestPromptWithEmbeddedResource,
          Prompts::TestPromptWithImage,
          Prompts::TestInputRequiredResultPrompt,
        ],
        resources: resources,
        resource_templates: resource_templates,
        # A per-boot random key is enough for conformance: every MRTR round trip completes
        # within one server process, and sealing keeps the fixture's `requestState` values
        # tamper-evident without any tool-level verification code.
        request_state_security: MCP::Server::RequestStateSecurity.new(key: SecureRandom.bytes(32)),
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

    def configure_handlers(server)
      server.logging_message_notification = MCP::LoggingMessageNotification.new(level: "debug")
      server.server_context = server

      configure_resources_read_handler(server)
      configure_subscription_handlers(server)
      configure_completion_handler(server)
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
          # Per SEP-2164, an unknown URI answers with -32602 carrying the URI in `error.data`;
          # an empty `contents` array is forbidden.
          raise MCP::Server::ResourceNotFoundError.new(uri, params)
        end
      end
    end

    def configure_completion_handler(server)
      server.completion_handler do |params|
        ref = params[:ref]
        argument = params[:argument]
        value = argument[:value].to_s

        case ref[:type]
        when "ref/prompt"
          case ref[:name]
          when "test_prompt_with_arguments"
            candidates = case argument[:name]
            when "arg1"
              ["value1", "value2", "value3"]
            when "arg2"
              ["optionA", "optionB", "optionC"]
            else
              []
            end
            values = candidates.select { |v| v.start_with?(value) }
            { completion: { values: values, hasMore: false } }
          else
            { completion: { values: [], hasMore: false } }
          end
        else
          { completion: { values: [], hasMore: false } }
        end
      end
    end

    def configure_subscription_handlers(server)
      subscribed_uris = Set.new

      server.resources_subscribe_handler do |params|
        subscribed_uris.add(params[:uri].to_s)
      end

      server.resources_unsubscribe_handler do |params|
        subscribed_uris.delete(params[:uri].to_s)
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
