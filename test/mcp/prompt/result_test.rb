# frozen_string_literal: true

require "test_helper"

module MCP
  class Prompt
    class ResultTest < ActiveSupport::TestCase
      test "#to_h returns description and messages" do
        result = Prompt::Result.new(
          description: "a prompt",
          messages: [Prompt::Message.new(role: "user", content: Content::Text.new("hi"))],
        )

        hash = result.to_h

        assert_equal "a prompt", hash[:description]
        assert_equal 1, hash[:messages].size
      end

      test "#to_h includes _meta when present" do
        meta = { "application/vnd.ant.mcp-app" => { "csp" => "default-src 'self'" } }
        result = Prompt::Result.new(
          description: "a prompt",
          messages: [Prompt::Message.new(role: "user", content: Content::Text.new("hi"))],
          meta: meta,
        )

        assert_equal meta, result.to_h[:_meta]
      end

      test "#to_h omits _meta when nil" do
        result = Prompt::Result.new(
          description: "a prompt",
          messages: [Prompt::Message.new(role: "user", content: Content::Text.new("hi"))],
        )

        refute result.to_h.key?(:_meta)
      end
    end
  end
end
