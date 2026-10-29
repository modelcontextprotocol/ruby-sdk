# frozen_string_literal: true

require "test_helper"

module MCP
  class Skill
    class FrontmatterTest < ActiveSupport::TestCase
      FRONTMATTER = Skill.const_get(:Frontmatter)

      def load(text)
        FRONTMATTER.load(text)
      end

      def assert_refused(text, message = nil)
        error = assert_raises(FRONTMATTER::Error, message || text.inspect) { load(text) }
        assert_equal :parse, error.reason
      end

      test "reads the block between the delimiters as a Hash with String keys" do
        assert_equal(
          { "name" => "pdf", "description" => "Extract PDFs", "tags" => ["a", "b"], "nested" => { "x" => 1, "y" => 1.5, "z" => nil } },
          load("---\nname: pdf\ndescription: Extract PDFs\ntags:\n  - a\n  - b\nnested:\n  x: 1\n  y: 1.5\n  z: ~\n---\n\nBody text is never read.\n"),
        )
      end

      test "skips a leading UTF-8 BOM and accepts CRLF line endings" do
        assert_equal({ "name" => "pdf" }, load("\xEF\xBB\xBF---\nname: pdf\n---\n".b))
        assert_equal({ "name" => "pdf" }, load("---\r\nname: pdf\r\n---\r\nbody"))
        assert_equal({ "name" => "pdf" }, load("---\nname: pdf\n---"))
      end

      test "refuses text that does not open with a delimiter line, lacks the closing one, or is not UTF-8" do
        assert_refused("name: pdf\n---\n")
        assert_refused("--- \nname: pdf\n---\n")
        assert_refused("---")
        assert_refused("---\nname: pdf\n")
        assert_refused("")
        assert_refused("---\nname: \xFF\n---\n".b)
      end

      test "refuses line breaks Psych honors but the delimiter scan or a YAML 1.2 reader does not" do
        assert_refused("---\r\r\nname: pdf\r\n---\r\n", "doubled CR on the opening line")
        assert_refused("---\nname: pdf\r\r\n---\n", "doubled CR on a block line")
        assert_refused("---\nname: pdf\rdescription: d\n---\n", "lone CR inside a block line")
        assert_refused("---\nname: pdf\n---\r", "lone CR after the closing delimiter at EOF")
        { "NEL" => 0x85, "LINE SEPARATOR" => 0x2028, "PARAGRAPH SEPARATOR" => 0x2029 }.each do |label, codepoint|
          separator = codepoint.chr(Encoding::UTF_8)
          assert_refused("---\nname: pdf#{separator}evil: injected\n---\n", label)
          assert_refused("---#{separator}name: pdf\n---\n", "#{label} on the opening line")
          assert_refused("---\nname: \"pdf#{separator}more\"\n---\n", "#{label} in a quoted scalar")
          assert_refused("---\nname: |\n  pdf#{separator}more\n---\n", "#{label} in a block scalar")
        end
        assert_equal({ "name" => "pdf" }, load("---\r\nname: pdf\r\n---"))
      end

      test "refuses integers beyond the range every JSON reader keeps exact" do
        assert_refused("---\nname: pdf\nbig: 9007199254740992\n---\n")
        assert_refused("---\nname: pdf\nbig: -9007199254740992\n---\n")
        assert_equal({ "name" => "pdf", "big" => 9_007_199_254_740_991 }, load("---\nname: pdf\nbig: 9007199254740991\n---\n"))
      end

      test "refuses a block over 64 KiB" do
        long = "description: #{"x" * (64 * 1024)}\n"
        assert_refused("---\nname: pdf\n#{long}---\n")
      end

      test "refuses a second document, an explicit document end, and directives" do
        assert_refused("---\nname: a\n...\n---\nname: b\n---\n", "second document")
        assert_refused("---\nname: a\n...\n---\n", "trailing document end")
        assert_refused("---\n%YAML 1.2\n---\nname: a\n---\n", "YAML directive")
        assert_refused("---\n%TAG ! tag:example.com,2000:\n---\nname: a\n---\n", "TAG directive")
      end

      test "refuses an empty block and a block whose top level is not a mapping" do
        assert_refused("---\n---\n")
        assert_refused("---\n# only a comment\n---\n")
        assert_refused("---\n- a\n- b\n---\n")
        assert_refused("---\njust a scalar\n---\n")
      end

      test "refuses tags on keys, values, and collections, aliases, and merge keys" do
        assert_refused("---\ncount: !!int \"010\"\n---\n", "tagged quoted value")
        assert_refused("---\ncount: !!str 1\n---\n", "tagged plain value")
        assert_refused("---\n!!str name: a\n---\n", "tagged key")
        assert_refused("---\nlist: !!seq\n  - a\n---\n", "tagged collection")
        assert_refused("---\nbase: &b\n  x: 1\nother: *b\n---\n", "alias")
        assert_refused("---\n<<: {x: 1}\nname: a\n---\n", "merge key")
      end

      test "refuses duplicate keys, which safe_load would silently collapse" do
        assert_refused("---\nname: a\nname: b\n---\n")
        assert_refused("---\nnested:\n  x: 1\n  x: 2\n---\n")
      end

      test "requires every key to be an untagged scalar whose resolved type is String" do
        assert_refused("---\n1: a\n---\n", "integer key")
        assert_refused("---\ntrue: a\n---\n", "boolean key")
        assert_refused("---\n~: a\n---\n", "null key")
        assert_refused("---\n? [a, b]\n: c\n---\n", "collection key")
        assert_equal({ "1" => "a", "true" => "b", "name" => "c" }, load("---\n\"1\": a\n'true': b\nname: c\n---\n"))
      end

      test "refuses nesting deeper than 64 levels before Psych builds objects" do
        deep = (1..66).map { |level| "#{"  " * (level - 1)}a:\n" }.join
        assert_refused("---\n#{deep}#{"  " * 66}x: 1\n---\n")
      end

      test "stops parsing at the depth limit, before the scan costs the square of the nesting" do
        nested = ->(levels, leaf) { "---\nname: a\ndescription: d\nx: #{"[" * levels}#{leaf}#{"]" * levels}\n---\n" }

        # The root mapping is level 1, so a scalar under 62 sequences and an empty 63rd sequence sit at level 64.
        assert load(nested.call(62, "0"))
        assert_refused(nested.call(63, "0"))
        assert load(nested.call(63, ""))
        assert_refused(nested.call(64, ""))

        # About 60 KiB, within the block limit; parsed whole before the depth was looked at, it took seconds.
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        assert_refused(nested.call(30_000, "0"), "30,000 levels")
        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
      end

      test "refuses plain scalars whose YAML 1.1 and 1.2 core-schema readings differ, and accepts their quoted forms" do
        divergent = ["yes", "no", "on", "off", "Yes", "NO", "010", "0777", "08", "1:20", "12:30:45", "1_000", "0o10", "1e3", "1E3", "1e+3", ".5e3", "2001-01-01", ":sym"]
        divergent.each do |scalar|
          assert_refused("---\nvalue: #{scalar}\n---\n", "value #{scalar}")
          assert_refused("---\n#{scalar}: 1\n---\n", "key #{scalar}")
          assert_equal({ "value" => scalar }, load("---\nvalue: \"#{scalar}\"\n---\n"), "quoted #{scalar}")
        end
      end

      test "accepts plain scalars both schemas read the same way, with their resolved values" do
        {
          "y" => "y",
          "n" => "n",
          "True" => true,
          "TRUE" => true,
          "false" => false,
          "null" => nil,
          "Null" => nil,
          "~" => nil,
          "+1" => 1,
          "-1" => -1,
          "00" => 0,
          "0x1F" => 31,
          ".5" => 0.5,
          "1." => 1.0,
          "1.0" => 1.0,
          "1.5e+3" => 1500.0,
          "0.5e+3" => 500.0,
          "-1.5e-3" => -0.0015,
          "plain words" => "plain words",
        }.each do |scalar, expected|
          assert_equal({ "value" => expected }, load("---\nvalue: #{scalar}\n---\n"), scalar)
        end
      end

      test "refuses non-finite numbers, which JSON cannot carry" do
        assert_refused("---\nvalue: .inf\n---\n")
        assert_refused("---\nvalue: -.inf\n---\n")
        assert_refused("---\nvalue: .nan\n---\n")
      end

      test "compares normalized values with Integer and Float kept distinct and Hash keys as sets" do
        assert FRONTMATTER.equal?({ "a" => 1, "b" => [1, { "c" => "d" }] }, { "b" => [1, { "c" => "d" }], "a" => 1 })
        refute FRONTMATTER.equal?({ "a" => 1 }, { "a" => 1.0 })
        refute FRONTMATTER.equal?({ "a" => 1 }, { "a" => 1, "b" => nil })
        refute FRONTMATTER.equal?({ "a" => [1, 2] }, { "a" => [2, 1] })
        refute FRONTMATTER.equal?({ "a" => "1" }, { "a" => 1 })
        refute FRONTMATTER.equal?({ "a" => nil }, { "a" => false })
      end
    end
  end
end
