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

      test "#to_h with meta" do
        meta = { "application/vnd.ant.mcp-app" => { "csp" => "default-src 'self'" } }
        image = Image.new("base64data", "image/png", meta: meta)

        assert_equal meta, image.to_h[:_meta]
      end

      test "#to_h without meta omits the key" do
        image = Image.new("base64data", "image/png")

        refute image.to_h.key?(:_meta)
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

      test "#to_h with meta" do
        meta = { "application/vnd.ant.mcp-app" => { "csp" => "default-src 'self'" } }
        audio = Audio.new("base64data", "audio/wav", meta: meta)

        assert_equal meta, audio.to_h[:_meta]
      end

      test "#to_h without meta omits the key" do
        audio = Audio.new("base64data", "audio/wav")

        refute audio.to_h.key?(:_meta)
      end
    end

    class EmbeddedResourceTest < ActiveSupport::TestCase
      test "#to_h returns correct format per MCP spec" do
        resource = Object.new
        def resource.to_h
          { uri: "test://example", mimeType: "text/plain", text: "content" }
        end

        embedded = EmbeddedResource.new(resource)
        result = embedded.to_h

        assert_equal "resource", result[:type]
        assert_equal({ uri: "test://example", mimeType: "text/plain", text: "content" }, result[:resource])
      end

      test "#to_h with annotations" do
        resource = Object.new
        def resource.to_h
          { uri: "test://x" }
        end

        embedded = EmbeddedResource.new(resource, annotations: { role: "data" })
        result = embedded.to_h

        assert_equal({ role: "data" }, result[:annotations])
      end

      test "#to_h without annotations omits the key" do
        resource = Object.new
        def resource.to_h
          { uri: "test://x" }
        end

        embedded = EmbeddedResource.new(resource)
        result = embedded.to_h

        refute result.key?(:annotations)
      end

      test "#to_h with meta" do
        resource = Object.new
        def resource.to_h
          { uri: "test://x" }
        end

        meta = { "application/vnd.ant.mcp-app" => { "csp" => "default-src 'self'" } }
        embedded = EmbeddedResource.new(resource, meta: meta)

        assert_equal meta, embedded.to_h[:_meta]
      end

      test "#to_h without meta omits the key" do
        resource = Object.new
        def resource.to_h
          { uri: "test://x" }
        end

        embedded = EmbeddedResource.new(resource)

        refute embedded.to_h.key?(:_meta)
      end
    end

    class ResourceLinkTest < ActiveSupport::TestCase
      test "#to_h returns correct format per MCP spec" do
        resource = Resource.new(
          uri: "file:///project/src/main.rs",
          name: "main.rs",
          description: "Primary application entry point",
          mime_type: "text/x-rust",
        )

        result = ResourceLink.new(resource).to_h

        assert_equal(
          {
            uri: "file:///project/src/main.rs",
            name: "main.rs",
            description: "Primary application entry point",
            mimeType: "text/x-rust",
            type: "resource_link",
          },
          result,
        )
      end

      test "#to_h carries the optional fields of the resource" do
        resource = Resource.new(
          uri: "file:///project/src/main.rs",
          name: "main.rs",
          title: "Main",
          icons: [Icon.new(mime_type: "image/png", sizes: ["48x48"], src: "https://example.com/icon.png", theme: "light")],
          annotations: Annotations.new(audience: ["user"], priority: 0.5, last_modified: "2025-01-12T15:00:58Z"),
          size: 0,
          meta: { "example" => "value" },
        )

        result = ResourceLink.new(resource).to_h

        assert_equal(
          {
            uri: "file:///project/src/main.rs",
            name: "main.rs",
            title: "Main",
            icons: [{ mimeType: "image/png", sizes: ["48x48"], src: "https://example.com/icon.png", theme: "light" }],
            annotations: { audience: ["user"], priority: 0.5, lastModified: "2025-01-12T15:00:58Z" },
            size: 0,
            _meta: { "example" => "value" },
            type: "resource_link",
          },
          result,
        )
      end

      test "#to_h with a class-based resource" do
        resource_class = Class.new(Resource) do
          uri "file:///docs/user_guide.md"
          resource_name "user_guide"
          mime_type "text/markdown"
        end

        result = ResourceLink.new(resource_class).to_h

        assert_equal(
          { uri: "file:///docs/user_guide.md", name: "user_guide", mimeType: "text/markdown", type: "resource_link" },
          result,
        )
      end
    end

    class TextTest < ActiveSupport::TestCase
      test "#to_h returns correct format per MCP spec" do
        text = Text.new("hello")
        result = text.to_h

        assert_equal "text", result[:type]
        assert_equal "hello", result[:text]
      end

      test "#to_h with meta" do
        meta = { "application/vnd.ant.mcp-app" => { "csp" => "default-src 'self'" } }
        text = Text.new("hello", meta: meta)

        assert_equal meta, text.to_h[:_meta]
      end

      test "#to_h without meta omits the key" do
        text = Text.new("hello")

        refute text.to_h.key?(:_meta)
      end
    end
  end
end
