# frozen_string_literal: true

require "test_helper"

module ModelContextProtocol
  module Client
    class ToolTest < Minitest::Test
      def test_name_returns_name_from_payload
        tool = Tool.new("name" => "test_tool")
        assert_equal("test_tool", tool.name)
      end

      def test_name_returns_nil_when_not_in_payload
        tool = Tool.new({})
        assert_nil(tool.name)
      end

      def test_description_returns_description_from_payload
        tool = Tool.new("description" => "A test tool")
        assert_equal("A test tool", tool.description)
      end

      def test_description_returns_nil_when_not_in_payload
        tool = Tool.new({})
        assert_nil(tool.description)
      end

      def test_input_schema_returns_input_schema_from_payload
        schema = { "type" => "object", "properties" => { "foo" => { "type" => "string" } } }
        tool = Tool.new("inputSchema" => schema)
        assert_equal(schema, tool.input_schema)
      end

      def test_input_schema_returns_nil_when_not_in_payload
        tool = Tool.new({})
        assert_nil(tool.input_schema)
      end

      def test_payload_is_accessible
        payload = { "name" => "test", "description" => "desc", "inputSchema" => {} }
        tool = Tool.new(payload)
        assert_equal(payload, tool.payload)
      end
    end
  end
end
