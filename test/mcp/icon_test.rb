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

    def test_initialization_with_only_src
      icon = Icon.new(src: "https://example.com/icon.png")

      assert_nil(icon.mime_type)
      assert_nil(icon.sizes)
      assert_equal("https://example.com/icon.png", icon.src)
      assert_nil(icon.theme)

      assert_equal({ src: "https://example.com/icon.png" }, icon.to_h)
    end

    def test_src_is_required
      exception = assert_raises(ArgumentError) do
        Icon.new
      end
      assert_equal("missing keyword: :src", exception.message)
    end

    def test_src_rejects_nil_and_an_empty_string
      [nil, ""].each do |src|
        exception = assert_raises(ArgumentError) do
          Icon.new(src: src)
        end
        assert_equal("The value of src must be a non-empty String (got #{src.class}).", exception.message)
      end
    end

    def test_src_rejects_a_non_string
      exception = assert_raises(ArgumentError) do
        Icon.new(src: :icon)
      end
      assert_equal("The value of src must be a non-empty String (got Symbol).", exception.message)
    end

    def test_sizes_accepts_an_array_of_strings
      [["48x48", "96x96"], ["any"], []].each do |sizes|
        icon = Icon.new(sizes: sizes, src: "https://example.com/icon.png")

        assert_equal(sizes, icon.to_h[:sizes])
      end
    end

    # https://github.com/modelcontextprotocol/ruby-sdk/issues/562
    def test_sizes_rejects_a_string
      exception = assert_raises(ArgumentError) do
        Icon.new(mime_type: "image/png", sizes: "51x51", src: "https://example.com/icon.png")
      end
      assert_equal(
        'The value of sizes must be an Array of Strings such as ["48x48"] or ["any"] (got String).',
        exception.message,
      )
    end

    def test_sizes_rejects_an_array_holding_a_non_string
      {
        ["48x48", 96] => "Integer",
        [nil] => "NilClass",
        ["48x48", nil] => "NilClass",
        [nil, 96] => "NilClass",
      }.each do |sizes, offender|
        exception = assert_raises(ArgumentError) do
          Icon.new(sizes: sizes, src: "https://example.com/icon.png")
        end
        assert_equal(
          "The value of sizes must be an Array of Strings such as [\"48x48\"] or [\"any\"] (got #{offender} inside the Array).",
          exception.message,
        )
      end
    end

    def test_src_accepts_any_scheme_and_sizes_accept_any_string
      string_subclass = Class.new(String)
      icon = Icon.new(sizes: ["unconventional", +"48x48", string_subclass.new("any")], src: "custom:icon")

      assert_equal({ sizes: ["unconventional", "48x48", "any"], src: "custom:icon" }, icon.to_h)
    end

    def test_mime_type_rejects_a_non_string
      exception = assert_raises(ArgumentError) do
        Icon.new(mime_type: :png, src: "https://example.com/icon.png")
      end
      assert_equal("The value of mime_type must be a String (got Symbol).", exception.message)
    end

    def test_valid_theme_for_light
      assert_nothing_raised do
        Icon.new(src: "https://example.com/icon.png", theme: "light")
      end
    end

    def test_valid_theme_for_dark
      assert_nothing_raised do
        Icon.new(src: "https://example.com/icon.png", theme: "dark")
      end
    end

    def test_invalid_theme
      exception = assert_raises(ArgumentError) do
        Icon.new(src: "https://example.com/icon.png", theme: "unexpected")
      end
      assert_equal('The value of theme must specify "light" or "dark".', exception.message)
    end

    def test_theme_rejects_false
      exception = assert_raises(ArgumentError) do
        Icon.new(src: "https://example.com/icon.png", theme: false)
      end
      assert_equal('The value of theme must specify "light" or "dark".', exception.message)
    end
  end
end
