# frozen_string_literal: true

require "test_helper"

module MCP
  class Resource
    class ContentsTest < ActiveSupport::TestCase
      test "Contents#to_h returns hash with mimeType" do
        contents = Resource::Contents.new(
          uri: "test://example",
          mime_type: "text/plain",
        )

        result = contents.to_h

        assert_equal "test://example", result[:uri]
        assert_equal "text/plain", result[:mimeType]
        refute result.key?(:mime_type), "Should use camelCase 'mimeType' not snake_case 'mime_type'"
      end

      test "Contents#to_h omits mimeType when nil" do
        contents = Resource::Contents.new(uri: "test://example")

        result = contents.to_h

        assert_equal({ uri: "test://example" }, result)
        refute result.key?(:mimeType)
      end

      test "TextContents#to_h returns hash with text and mimeType" do
        text_contents = Resource::TextContents.new(
          uri: "test://text",
          mime_type: "text/plain",
          text: "Hello, world!",
        )

        result = text_contents.to_h

        assert_equal "test://text", result[:uri]
        assert_equal "text/plain", result[:mimeType]
        assert_equal "Hello, world!", result[:text]
        refute result.key?(:mime_type), "Should use camelCase 'mimeType' not snake_case 'mime_type'"
      end

      test "BlobContents#to_h returns hash with blob and mimeType" do
        blob_contents = Resource::BlobContents.new(
          uri: "test://binary",
          mime_type: "image/png",
          data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
        )

        result = blob_contents.to_h

        assert_equal "test://binary", result[:uri]
        assert_equal "image/png", result[:mimeType]
        assert_equal "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==", result[:blob]
        refute result.key?(:data), "Should use 'blob' not 'data' per MCP specification"
        refute result.key?(:mime_type), "Should use camelCase 'mimeType' not snake_case 'mime_type'"
      end

      test "BlobContents#to_h omits mimeType when nil" do
        blob_contents = Resource::BlobContents.new(
          uri: "test://binary",
          mime_type: nil,
          data: "base64data",
        )

        result = blob_contents.to_h

        assert_equal({ uri: "test://binary", blob: "base64data" }, result)
        refute result.key?(:mimeType)
      end
    end
  end
end
