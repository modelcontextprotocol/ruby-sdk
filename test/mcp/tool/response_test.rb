# frozen_string_literal: true

require "test_helper"

module MCP
  class Tool
    class ResponseTest < ActiveSupport::TestCase
      test "#initialize with content and error flag" do
        content = [{
          type: "text",
          text: "Unauthorized",
        }]
        response = Response.new(content, error: true)

        assert_equal content, response.content
        assert response.error?

        response = Response.new(content, error: false)
        assert_equal content, response.content
        refute response.error?

        response = Response.new(content)
        assert_equal content, response.content
        refute response.error?
      end

      test "#to_h" do
        content = [{
          type: "text",
          text: "Unauthorized",
        }]
        response = Response.new(content)
        actual = response.to_h

        assert_equal [:content, :isError].sort, actual.keys.sort
        assert_equal content, actual[:content]
        refute actual[:isError]

        response = Response.new(content, error: true)
        actual = response.to_h
        assert_equal [:content, :isError].sort, actual.keys.sort
        assert_equal content, actual[:content]
        assert actual[:isError]
      end

      test "#error?" do
        response = Response.new(nil, error: true)
        assert response.error?

        response = Response.new(nil, error: false)
        refute response.error?
      end
    end
  end
end
