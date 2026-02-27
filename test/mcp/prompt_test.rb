# frozen_string_literal: true

require "test_helper"

module MCP
  class PromptTest < ActiveSupport::TestCase
    class TestPrompt < Prompt
      description "Test prompt"
      icons [{ mimeType: "image/png", sizes: ["48x48", "96x96"], src: "https://example.com", theme: "light" }]
      arguments [
        Prompt::Argument.new(name: "test_argument", description: "Test argument", required: true),
      ]

      class << self
        def template(args, server_context:)
          Prompt::Result.new(
            description: "Hello, world!",
            messages: [
              Prompt::Message.new(role: "user", content: Content::Text.new("Hello, world!")),
              Prompt::Message.new(role: "assistant", content: Content::Text.new("Hello, friend!")),
            ],
          )
        end
      end
    end

    test "#template returns a Result with description and messages" do
      prompt = TestPrompt

      expected_template_result = {
        description: "Hello, world!",
        messages: [
          { role: "user", content: { text: "Hello, world!", type: "text" } },
          { role: "assistant", content: { text: "Hello, friend!", type: "text" } },
        ],
      }

      result = prompt.template({ "test_argument" => "Hello, friend!" }, server_context: { user_id: 123 })

      assert_equal expected_template_result, result.to_h
    end

    test "allows declarative definition of prompts as classes" do
      class MockPrompt < Prompt
        prompt_name "my_mock_prompt"
        description "a mock prompt for testing"
        icons [{ mimeType: "image/png", sizes: ["48x48", "96x96"], src: "https://example.com", theme: "light" }]
        arguments [
          Prompt::Argument.new(name: "test_argument", description: "Test argument", required: true),
        ]

        class << self
          def template(args, server_context:)
            Prompt::Result.new(
              description: "Hello, world!",
              messages: [
                Prompt::Message.new(role: "user", content: Content::Text.new("Hello, world!")),
                Prompt::Message.new(role: "assistant", content: Content::Text.new(args["test_argument"])),
              ],
            )
          end
        end
      end

      prompt = MockPrompt

      assert_equal "my_mock_prompt", prompt.name_value
      assert_equal "a mock prompt for testing", prompt.description
      assert_equal([{ mimeType: "image/png", sizes: ["48x48", "96x96"], src: "https://example.com", theme: "light" }], prompt.icons)
      assert_equal "test_argument", prompt.arguments.first.name
      assert_equal "Test argument", prompt.arguments.first.description
      assert prompt.arguments.first.required

      expected_template_result = {
        description: "Hello, world!",
        messages: [
          { role: "user", content: { text: "Hello, world!", type: "text" } },
          { role: "assistant", content: { text: "Hello, friend!", type: "text" } },
        ],
      }

      result = prompt.template({ "test_argument" => "Hello, friend!" }, server_context: { user_id: 123 })
      assert_equal expected_template_result, result.to_h
    end

    test "defaults to class name as prompt name" do
      class DefaultNamePrompt < Prompt
        description "a mock prompt for testing"
        arguments [
          Prompt::Argument.new(name: "test_argument", description: "Test argument", required: true),
        ]

        class << self
          def template(args, server_context:)
            Prompt::Result.new(
              description: "Hello, world!",
              messages: [
                Prompt::Message.new(role: "user", content: Content::Text.new("Hello, world!")),
                Prompt::Message.new(role: "assistant", content: Content::Text.new(args["test_argument"])),
              ],
            )
          end
        end
      end

      prompt = DefaultNamePrompt

      assert_equal "default_name_prompt", prompt.name_value
      assert_equal "a mock prompt for testing", prompt.description
      assert_equal "test_argument", prompt.arguments.first.name
    end

    test ".define allows definition of simple prompts with a block" do
      prompt = Prompt.define(
        name: "mock_prompt",
        title: "Mock Prompt",
        description: "a mock prompt for testing",
        icons: [{ mimeType: "image/png", sizes: ["48x48", "96x96"], src: "https://example.com", theme: "light" }],
        arguments: [
          Prompt::Argument.new(
            name: "test_argument",
            title: "Test argument title",
            description: "This is a test argument description",
            required: true,
          ),
        ],
        meta: { foo: "bar" },
      ) do |args, server_context:|
        content = Content::Text.new(args["test_argument"] + " user: #{server_context[:user_id]}")

        Prompt::Result.new(
          description: "Hello, world!",
          messages: [
            Prompt::Message.new(role: "user", content: Content::Text.new("Hello, world!")),
            Prompt::Message.new(role: "assistant", content: content),
          ],
        )
      end

      assert_equal "mock_prompt", prompt.name_value
      assert_equal "a mock prompt for testing", prompt.description
      assert_equal([{ mimeType: "image/png", sizes: ["48x48", "96x96"], src: "https://example.com", theme: "light" }], prompt.icons)
      assert_equal "test_argument", prompt.arguments.first.name
      assert_equal "Test argument title", prompt.arguments.first.title
      assert_equal "This is a test argument description", prompt.arguments.first.description
      assert prompt.arguments.first.required
      assert_equal({ foo: "bar" }, prompt.meta_value)

      expected = {
        description: "Hello, world!",
        messages: [
          { role: "user", content: { text: "Hello, world!", type: "text" } },
          { role: "assistant", content: { text: "Hello, friend! user: 123", type: "text" } },
        ],
      }

      result = prompt.template({ "test_argument" => "Hello, friend!" }, server_context: { user_id: 123 })
      assert_equal expected, result.to_h
    end

    test "#to_h returns a hash with name, title, description, arguments, and meta" do
      class FullPrompt < Prompt
        prompt_name "test_prompt"
        description "Test prompt description"
        title "Test Prompt title"
        arguments [
          Prompt::Argument.new(name: "test_argument", description: "Test argument", required: true),
        ]
        meta({ test: "meta" })
      end

      expected = {
        name: "test_prompt",
        title: "Test Prompt title",
        description: "Test prompt description",
        arguments: [
          { name: "test_argument", description: "Test argument", required: true },
        ],
        _meta: { test: "meta" },
      }

      assert_equal expected, FullPrompt.to_h
    end

    test "#to_h omits arguments key when arguments are not declared" do
      class NoArgumentsPrompt < Prompt
        description "No arguments prompt"
      end
      prompt = NoArgumentsPrompt

      expected = {
        name: "no_arguments_prompt",
        description: "No arguments prompt",
      }

      assert_equal expected, prompt.to_h
    end

    test "#validate_arguments! does not raise when arguments are not declared" do
      prompt_class = Class.new(Prompt) do
        prompt_name "no_args_prompt"
        description "A prompt with no arguments"
        # NOTE: no `arguments` declaration at all
      end

      assert_nothing_raised do
        prompt_class.validate_arguments!({})
      end
    end

    test "#validate_arguments! handles nil args" do
      prompt_class = Class.new(Prompt) do
        prompt_name "no_args_prompt"
        description "A prompt with no arguments"
      end

      assert_nothing_raised do
        prompt_class.validate_arguments!(nil)
      end
    end

    test "#validate_arguments! does not raise when arguments is explicitly set to nil" do
      prompt_class = Class.new(Prompt) do
        prompt_name "nil_args_prompt"
        description "A prompt with nil arguments"
        arguments nil
      end

      assert_nothing_raised do
        prompt_class.validate_arguments!({})
      end
    end

    test "#to_h omits arguments key when arguments is empty" do
      prompt = Prompt.define(
        name: "no_args_prompt",
        description: "a prompt without arguments",
        arguments: [],
      )

      refute prompt.to_h.key?(:arguments)
    end

    test "#to_h does not have `:icons` key when icons is empty" do
      prompt = Prompt.define(
        name: "prompt_without_icons",
        description: "a prompt without icons",
      )

      refute prompt.to_h.key?(:icons)
    end

    test "#to_h does not have `:icons` key when icons is nil" do
      prompt = Prompt.define(
        name: "prompt_without_icons",
        description: "a prompt without icons",
        icons: nil,
      )

      refute prompt.to_h.key?(:icons)
    end
  end
end
