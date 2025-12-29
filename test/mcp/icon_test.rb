# frozen_string_literal: true

require "test_helper"

module MCP
  class IconTest < ActiveSupport::TestCase
    def test_initialization
      icon = Icon.new(mime_type: "image/png", sizes: ["48x48", "96x96"], src: "https://example.com", theme: "light")

      assert_equal("image/png", icon.mime_type)
      assert_equal(["48x48", "96x96"], icon.sizes)
      assert_equal("https://example.com", icon.src)
      assert_equal("light", icon.theme)

      assert_equal({ mimeType: "image/png", sizes: ["48x48", "96x96"], src: "https://example.com", theme: "light" }, icon.to_h)
    end

    def test_initialization_by_default
      icon = Icon.new

      assert_nil(icon.mime_type)
      assert_nil(icon.sizes)
      assert_nil(icon.src)
      assert_nil(icon.theme)

      assert_empty(icon.to_h)
    end

    def test_valid_theme_for_light
      assert_nothing_raised do
        Icon.new(theme: "light")
      end
    end

    def test_valid_theme_for_dark
      assert_nothing_raised do
        Icon.new(theme: "dark")
      end
    end

    def test_invalid_theme
      exception = assert_raises(ArgumentError) do
        Icon.new(theme: "unexpected")
      end
      assert_equal('The value of theme must specify "light" or "dark".', exception.message)
    end
  end
end
