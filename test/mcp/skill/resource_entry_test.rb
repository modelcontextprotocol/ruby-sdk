# frozen_string_literal: true

require "test_helper"

module MCP
  class Skill
    class ResourceEntryTest < ActiveSupport::TestCase
      DIGEST = "sha256:#{"a" * 64}"

      test "holds the uri, digest, and size of one skill file and serializes them" do
        entry = ResourceEntry.new(uri: "skill://pdf/SKILL.md", digest: DIGEST, size: 12)

        assert_equal "skill://pdf/SKILL.md", entry.uri
        assert_equal DIGEST, entry.digest
        assert_equal 12, entry.size
        assert_equal({ uri: "skill://pdf/SKILL.md", digest: DIGEST, size: 12 }, entry.to_h)
        assert_predicate entry, :frozen?
      end

      test "from accepts an entry, a Hash with Symbol keys, and a Hash with String keys" do
        entry = ResourceEntry.new(uri: "skill://pdf/SKILL.md", digest: DIGEST, size: 1)

        assert_same entry, ResourceEntry.from(entry)
        assert_equal entry, ResourceEntry.from(uri: "skill://pdf/SKILL.md", digest: DIGEST, size: 1)
        assert_equal entry, ResourceEntry.from("uri" => "skill://pdf/SKILL.md", "digest" => DIGEST, "size" => 1)
      end

      test "from refuses other values, unknown keys, and a member given twice" do
        error = assert_raises(ArgumentError) { ResourceEntry.from("skill://pdf/SKILL.md") }
        assert_equal "A skill resource entry must be an MCP::Skill::ResourceEntry or a Hash (got String).", error.message

        error = assert_raises(ArgumentError) { ResourceEntry.from(uri: "skill://pdf/SKILL.md", digest: DIGEST, size: 1, mime: "x") }
        assert_equal "A skill resource entry Hash may only hold uri, digest, and size (got :mime).", error.message

        error = assert_raises(ArgumentError) { ResourceEntry.from(uri: "skill://pdf/SKILL.md", "uri" => "x", digest: DIGEST, size: 1) }
        assert_equal "A skill resource entry Hash gives uri twice.", error.message
      end

      test "from_content computes the size and digest from the exact bytes served" do
        content = "---\nname: pdf\n---\n"
        entry = ResourceEntry.from_content(uri: "skill://pdf/SKILL.md", content: content)

        assert_equal content.bytesize, entry.size
        assert_equal "sha256:#{Digest::SHA256.hexdigest(content)}", entry.digest

        binary = "\x89PNG\xFF".b
        assert_equal "sha256:#{Digest::SHA256.hexdigest(binary)}", ResourceEntry.from_content(uri: "skill://pdf/logo.png", content: binary).digest

        error = assert_raises(ArgumentError) { ResourceEntry.from_content(uri: "skill://pdf/SKILL.md", content: 42) }
        assert_equal "The value of content must be a String (got Integer).", error.message
      end

      test "refuses a uri that is not a structurally valid skill URI" do
        ["http://x/SKILL.md", "skill://", "skill://a//b", "skill://a/./b", "skill://a/../b", "skill://a/b".encode("UTF-16LE"), 42].each do |uri|
          error = assert_raises(ArgumentError, uri.inspect) { ResourceEntry.new(uri: uri, digest: DIGEST, size: 1) }
          assert_equal "The value of uri must be a skill:// URI with non-empty path segments.", error.message
        end
      end

      test "refuses a digest that is not sha256 over 64 lowercase hex characters" do
        ["sha256:#{"A" * 64}", "sha256:#{"a" * 63}", "sha1:#{"a" * 64}", "a" * 64, DIGEST.encode("UTF-16LE"), nil].each do |digest|
          error = assert_raises(ArgumentError, digest.inspect) { ResourceEntry.new(uri: "skill://pdf/SKILL.md", digest: digest, size: 1) }
          assert_equal "The value of digest must be sha256: followed by 64 lowercase hex characters.", error.message
        end
      end

      test "refuses a size that is not a non-negative Integer" do
        [-1, 1.5, "12", nil].each do |size|
          error = assert_raises(ArgumentError, size.inspect) { ResourceEntry.new(uri: "skill://pdf/SKILL.md", digest: DIGEST, size: size) }
          assert_equal "The value of size must be a non-negative Integer (got #{size.class}).", error.message
        end
        assert_equal 0, ResourceEntry.new(uri: "skill://pdf/SKILL.md", digest: DIGEST, size: 0).size
      end
    end
  end
end
