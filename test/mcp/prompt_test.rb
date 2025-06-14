# typed: strict
# frozen_string_literal: true

require "test_helper"

module MCP
  class PromptTest < ActiveSupport::TestCase
    TestPrompt = Prompt.define(
      name: "test_prompt",
      description: "Test prompt",
      arguments: [
        Prompt::Argument.new(name: "test_argument", description: "Test argument", required: true),
      ],
    ) do
      Prompt::Result.new(
        description: "Hello, world!",
        messages: [
          Prompt::Message.new(role: "user", content: Content::Text.new("Hello, world!")),
          Prompt::Message.new(role: "assistant", content: Content::Text.new("Hello, friend!")),
        ],
      )
    end

    test "#call returns a Result with description and messages" do
      prompt = TestPrompt

      expected_template_result = {
        description: "Hello, world!",
        messages: [
          { role: "user", content: { text: "Hello, world!", type: "text" } },
          { role: "assistant", content: { text: "Hello, friend!", type: "text" } },
        ],
      }

      result = prompt.call({ "test_argument" => "Hello, friend!" }, server_context: { user_id: 123 })

      assert_equal expected_template_result, result.to_h
    end

    test ".define allows definition of simple prompts with a block" do
      prompt = Prompt.define(
        name: "mock_prompt",
        description: "a mock prompt for testing",
        arguments: [
          Prompt::Argument.new(name: "test_argument", description: "Test argument", required: true),
        ],
      ) do |args, server_context:|
        content = Content::Text.new(args["test_argument"] + " user: #{server_context[:user_id]}")

        Prompt::Result.new(
          description: "Hello, world!",
          messages: [
            Prompt::Message.new(role: "user", content: Content::Text.new("Hello, world!")),
            Prompt::Message.new(role: "assistant", content:),
          ],
        )
      end

      assert_equal "mock_prompt", prompt.name
      assert_equal "a mock prompt for testing", prompt.description
      assert_equal "test_argument", prompt.arguments.first.name

      expected = {
        description: "Hello, world!",
        messages: [
          { role: "user", content: { text: "Hello, world!", type: "text" } },
          { role: "assistant", content: { text: "Hello, friend! user: 123", type: "text" } },
        ],
      }

      result = prompt.call({ "test_argument" => "Hello, friend!" }, server_context: { user_id: 123 })
      assert_equal expected, result.to_h
    end
  end
end
