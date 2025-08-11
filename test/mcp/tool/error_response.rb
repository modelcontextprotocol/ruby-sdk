# frozen_string_literal: true

require "test_helper"

module MCP
  class Tool
    class ErrorResponseTest < ActiveSupport::TestCase
      test "#initialize with content" do
        content = [{
          type: "text",
          text: "Unauthorized",
        }]
        response = ErrorResponse.new(content)

        assert_equal content, response.content
        assert response.error?
      end

      test "#to_h" do
        content = [{
          type: "text",
          text: "Unauthorized",
        }]
        response = ErrorResponse.new(content)
        actual = response.to_h

        assert_equal [:content, :isError].sort, actual.keys.sort
        assert_equal content, actual[:content]
        assert actual[:isError]
      end

      test "#error?" do
        response = ErrorResponse.new(nil)
        assert response.error?
      end
    end
  end
end
