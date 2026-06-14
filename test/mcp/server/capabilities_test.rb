# frozen_string_literal: true

require "test_helper"

module MCP
  class Server
    class CapabilitiesTest < ActiveSupport::TestCase
      test "to_h omits everything by default" do
        assert_empty(Capabilities.new.to_h)
      end

      test "constructor accepts a capabilities hash" do
        capabilities = Capabilities.new(
          completions: {},
          logging: {},
          prompts: { listChanged: true },
          resources: { listChanged: true, subscribe: true },
          tools: { listChanged: true },
        )

        assert_equal(
          {
            completions: {},
            logging: {},
            prompts: { listChanged: true },
            resources: { listChanged: true, subscribe: true },
            tools: { listChanged: true },
          },
          capabilities.to_h,
        )
      end

      test "constructor accepts extensions" do
        capabilities = Capabilities.new(
          tools: {},
          extensions: { "com.example/feature" => { enabled: true } },
        )

        assert_equal({ "com.example/feature" => { enabled: true } }, capabilities.to_h[:extensions])
      end

      test "support_extensions merges repeated declarations" do
        capabilities = Capabilities.new
        capabilities.support_extensions("com.example/feature" => { enabled: true })
        capabilities.support_extensions("io.modelcontextprotocol/tasks" => {})

        assert_equal(
          { "com.example/feature" => { enabled: true }, "io.modelcontextprotocol/tasks" => {} },
          capabilities.to_h[:extensions],
        )
      end

      test "support_extensions with no arguments declares an empty extensions object" do
        capabilities = Capabilities.new
        capabilities.support_extensions

        assert_equal({}, capabilities.to_h[:extensions])
      end

      test "support_extensions tolerates nil" do
        capabilities = Capabilities.new(extensions: nil)

        assert_equal({}, capabilities.to_h[:extensions])
      end

      test "to_h omits extensions when never declared" do
        refute(Capabilities.new(tools: {}).to_h.key?(:extensions))
      end
    end
  end
end
