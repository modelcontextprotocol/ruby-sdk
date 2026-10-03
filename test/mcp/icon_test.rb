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

    def test_from_returns_an_icon_as_is
      icon = Icon.new(src: "https://example.com/icon.png")

      assert_same(icon, Icon.from(icon))
    end

    def test_from_builds_an_icon_from_a_hash_with_either_key_spelling
      expected = { mimeType: "image/png", sizes: ["48x48"], src: "https://example.com/icon.png", theme: "light" }
      [
        { mimeType: "image/png", sizes: ["48x48"], src: "https://example.com/icon.png", theme: "light" },
        { mime_type: "image/png", sizes: ["48x48"], src: "https://example.com/icon.png", theme: "light" },
        { "mimeType" => "image/png", "sizes" => ["48x48"], "src" => "https://example.com/icon.png", "theme" => "light" },
      ].each do |hash|
        assert_equal(expected, Icon.from(hash).to_h)
      end
    end

    def test_from_rejects_an_unknown_key
      exception = assert_raises(ArgumentError) do
        Icon.from({ src: "https://example.com/icon.png", size: "48x48" })
      end
      assert_equal("An icon Hash may only hold src, mimeType (or mime_type), sizes, and theme (got :size).", exception.message)
    end

    def test_from_rejects_a_key_that_is_neither_a_symbol_nor_a_string
      key = Object.new
      key.define_singleton_method(:to_s) { "src" }

      [1, key].each do |bad_key|
        exception = assert_raises(ArgumentError) do
          Icon.from({ bad_key => "https://example.com/icon.png" })
        end
        assert_equal("An icon Hash key must be a Symbol or a String (got #{bad_key.class}).", exception.message)
      end
    end

    def test_from_rejects_a_member_given_twice
      exception = assert_raises(ArgumentError) do
        Icon.from({ src: "https://example.com/icon.png", mimeType: "image/png", mime_type: "image/png" })
      end
      assert_equal("An icon Hash gives mime_type twice.", exception.message)
    end

    def test_from_rejects_anything_but_an_icon_or_a_hash
      exception = assert_raises(ArgumentError) do
        Icon.from("https://example.com/icon.png")
      end
      assert_equal("An icon must be an MCP::Icon or a Hash (got String).", exception.message)
    end

    def test_from_checks_a_hash_the_way_new_does
      exception = assert_raises(ArgumentError) do
        Icon.from({ mimeType: "image/png" })
      end
      assert_equal("missing keyword: :src", exception.message)

      exception = assert_raises(ArgumentError) do
        Icon.from({ src: "https://example.com/icon.png", sizes: "51x51" })
      end
      assert_equal('The value of sizes must be an Array of Strings such as ["48x48"] or ["any"] (got String).', exception.message)
    end

    def test_from_list_keeps_nil_and_converts_each_element
      assert_nil(Icon.from_list(nil))
      assert_equal([], Icon.from_list([]))

      icon = Icon.new(src: "https://example.com/icon.png")
      icons = Icon.from_list([icon, { src: "https://example.com/other.png" }])

      assert_same(icon, icons[0])
      assert_equal({ src: "https://example.com/other.png" }, icons[1].to_h)
    end

    def test_from_list_returns_a_frozen_array
      icons = Icon.from_list([{ src: "https://example.com/icon.png" }])

      assert_predicate(icons, :frozen?)
      assert_raises(FrozenError) do
        icons << { src: "https://example.com/other.png", sizes: "51x51" }
      end
    end

    def test_from_list_rejects_anything_but_nil_or_an_array
      exception = assert_raises(ArgumentError) do
        Icon.from_list({ src: "https://example.com/icon.png" })
      end
      assert_equal("icons must be nil or an Array of MCP::Icon or Hash (got Hash).", exception.message)
    end

    def test_from_list_names_the_position_of_a_rejected_element
      exception = assert_raises(ArgumentError) do
        Icon.from_list([{ src: "https://example.com/icon.png" }, { src: "https://example.com/other.png", sizes: "51x51" }])
      end
      assert_equal('icons[1]: The value of sizes must be an Array of Strings such as ["48x48"] or ["any"] (got String).', exception.message)
    end
  end
end
