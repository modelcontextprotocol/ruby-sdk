# frozen_string_literal: true

require "test_helper"

module MCP
  module Content
    class ImageTest < ActiveSupport::TestCase
      test "#to_h returns mimeType (camelCase) per MCP spec" do
        image = Image.new("base64data", "image/png")
        result = image.to_h

        assert_equal "image/png", result[:mimeType]
        refute result.key?(:mime_type), "Expected camelCase mimeType, got snake_case mime_type"
        assert_equal "image", result[:type]
        assert_equal "base64data", result[:data]
      end

      test "#to_h with annotations" do
        image = Image.new("base64data", "image/png", annotations: { role: "thumbnail" })
        result = image.to_h

        assert_equal({ role: "thumbnail" }, result[:annotations])
      end

      test "#to_h without annotations omits the key" do
        image = Image.new("base64data", "image/png")
        result = image.to_h

        refute result.key?(:annotations)
      end
    end

    class AudioTest < ActiveSupport::TestCase
      test "#to_h returns correct format per MCP spec" do
        audio = Audio.new("base64data", "audio/wav")
        result = audio.to_h

        assert_equal "audio", result[:type]
        assert_equal "base64data", result[:data]
        assert_equal "audio/wav", result[:mimeType]
      end

      test "#to_h with annotations" do
        audio = Audio.new("base64data", "audio/wav", annotations: { role: "recording" })
        result = audio.to_h

        assert_equal({ role: "recording" }, result[:annotations])
      end

      test "#to_h without annotations omits the key" do
        audio = Audio.new("base64data", "audio/wav")
        result = audio.to_h

        refute result.key?(:annotations)
      end
    end
  end
end
