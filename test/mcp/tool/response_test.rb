# frozen_string_literal: true

require "test_helper"

module MCP
  class Tool
    class ResponseTest < ActiveSupport::TestCase
      test "#initialize with content" do
        content = [{
          type: "text",
          text: "Unauthorized",
        }]
        response = Response.new(content)

        assert_equal content, response.content
        refute response.error?
      end

      test "#initialize with content and error set to true" do
        content = [{
          type: "text",
          text: "Unauthorized",
        }]
        response = Response.new(content, error: true)

        assert_equal content, response.content
        assert response.error?
      end

      test "#initialize with content and error explicitly set to false" do
        content = [{
          type: "text",
          text: "Unauthorized",
        }]
        response = Response.new(content, error: false)

        assert_equal content, response.content
        refute response.error?
      end

      test "#initialize with content and structuredContent" do
        content = [{
          type: "text",
          text: "{\"code\":401,\"message\":\"Unauthorized\"}",
        }]
        structured_content = { code: 401, message: "Unauthorized" }
        response = Response.new(content, structured_content: structured_content)

        assert_equal content, response.content
        assert_equal structured_content, response.structured_content
        refute response.error?
      end

      test "#error? for a standard response" do
        response = Response.new(nil, error: false)
        refute response.error?
      end

      test "#error? for an error response" do
        response = Response.new(nil, error: true)
        assert response.error?
      end

      test "#to_h for a standard response" do
        content = [{
          type: "text",
          text: "Unauthorized",
        }]
        response = Response.new(content)
        actual = response.to_h

        assert_equal [:content, :isError], actual.keys
        assert_equal content, actual[:content]
        refute actual[:isError]
      end

      test "#to_h for an error response" do
        content = [{
          type: "text",
          text: "Unauthorized",
        }]
        response = Response.new(content, error: true)
        actual = response.to_h
        assert_equal [:content, :isError], actual.keys
        assert_equal content, actual[:content]
        assert actual[:isError]
      end

      test "#to_h for a standard response with content and structured content" do
        content = [{
          type: "text",
          text: "{\"code\":401,\"message\":\"Unauthorized\"}",
        }]
        structured_content = { code: 401, message: "Unauthorized" }
        response = Response.new(content, structured_content: structured_content)
        actual = response.to_h

        assert_equal [:content, :isError, :structuredContent], actual.keys
        assert_equal content, actual[:content]
        assert_equal structured_content, actual[:structuredContent]
        refute actual[:isError]
      end

      test "#to_h for a standard response with structured content only" do
        structured_content = { code: 401, message: "Unauthorized" }
        response = Response.new(structured_content: structured_content)
        actual = response.to_h

        assert_equal [:isError, :structuredContent], actual.keys
        assert_nil actual[:content]
        assert_equal structured_content, actual[:structuredContent]
        refute actual[:isError]
      end
    end
  end
end
