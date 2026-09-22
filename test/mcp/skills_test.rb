# frozen_string_literal: true

require "test_helper"

module MCP
  class SkillsTest < ActiveSupport::TestCase
    test "exposes the SEP-2640 wire vocabulary" do
      # These strings are shared with the ext-skills reference package and the other official SDKs.
      assert_equal "io.modelcontextprotocol/skills", Skills::EXTENSION_ID
      assert_equal "skill://", Skills::URI_SCHEME
      assert_equal "inode/directory", Skills::DIRECTORY_MIME_TYPE
      assert_equal "text/markdown", Skills::SKILL_MIME_TYPE
    end

    test ".capability builds the extensions fragment, empty when no optional feature is offered" do
      assert_equal({ "io.modelcontextprotocol/skills" => {} }, Skills.capability)
      assert_equal({ "io.modelcontextprotocol/skills" => { directoryRead: true } }, Skills.capability(directory_read: true))
    end

    test ".declared? and .directory_read? read either key form" do
      assert Skills.declared?({ extensions: Skills.capability })
      assert Skills.declared?({ "extensions" => { "io.modelcontextprotocol/skills" => {} } })
      assert Skills.declared?({ extensions: { "io.modelcontextprotocol/skills": {} } })
      refute Skills.declared?({ extensions: { "io.modelcontextprotocol/ui" => {} } })
      refute Skills.declared?({})
      refute Skills.declared?(nil)

      assert Skills.directory_read?({ extensions: Skills.capability(directory_read: true) })
      refute Skills.directory_read?({ extensions: Skills.capability })
    end

    test ".client_supports? is the client-side spelling of .declared?" do
      assert Skills.client_supports?({ extensions: Skills.capability })
      refute Skills.client_supports?({ extensions: {} })
    end

    test ".uri_for addresses SKILL.md under a flat or prefixed skill path" do
      assert_equal "skill://git-workflow/SKILL.md", Skills.uri_for("git-workflow")
      assert_equal "skill://acme/billing/refunds/SKILL.md", Skills.uri_for("acme/billing/refunds")
      assert_equal "skill://git-workflow/SKILL.md", Skills.uri_for("/git-workflow/")
      assert_equal "github://owner/repo/skills/refunds/SKILL.md", Skills.uri_for("owner/repo/skills/refunds", scheme: "github://")
      assert_raises(ArgumentError) { Skills.uri_for("") }
    end

    test ".resolve resolves a skill's internal reference against its own root" do
      uri = "skill://acme/billing/refunds/SKILL.md"

      assert_equal "skill://acme/billing/refunds/references/GUIDE.md", Skills.resolve(uri, "references/GUIDE.md")
      assert_equal "skill://acme/billing/refunds/examples/email.md", Skills.resolve(uri, "./examples/email.md")
    end

    test ".digest formats the SHA-256 of the raw bytes the manifest covers" do
      digest = Skills.digest("# Refunds")

      assert_match(/\Asha256:[0-9a-f]{64}\z/, digest)
      assert_equal "sha256:#{Digest::SHA256.hexdigest("# Refunds")}", digest
    end
  end
end
