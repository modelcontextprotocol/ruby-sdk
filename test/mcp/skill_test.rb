# frozen_string_literal: true

require "test_helper"

module MCP
  class SkillTest < ActiveSupport::TestCase
    SKILL_URI = "skill://acme/billing/refunds/SKILL.md"
    DIGEST = "sha256:#{"a" * 64}"

    test "exposes the SEP-2640 vocabulary" do
      assert_equal "dynamic", Skill::DYNAMIC
      assert_equal "SKILL.md", Skill::SKILL_FILE
      assert_equal 512, Skill::MAX_RESOURCES
      assert_equal 16_777_216, Skill::MAX_TOTAL_SIZE
    end

    test "derives name and root from the URI alone" do
      skill = build

      assert_equal "refunds", skill.name
      assert_equal "skill://acme/billing/refunds", skill.root
      assert_equal "git-workflow", Skill.name_from_uri("skill://git-workflow/SKILL.md")
    end

    test "serializes the entry shape skills/list and skills/get share" do
      skill = build(frontmatter: { "name" => "refunds", "description" => "d", "license" => "Apache-2.0" })

      assert_equal(
        {
          uri: SKILL_URI,
          frontmatter: { "name" => "refunds", "description" => "d", "license" => "Apache-2.0" },
          resources: [{ uri: SKILL_URI, digest: DIGEST, size: 10 }],
        },
        skill.to_h,
      )
    end

    test "passes frontmatter through verbatim rather than curating it" do
      frontmatter = { "name" => "refunds", "description" => "d", "metadata" => { "version" => "2.1.0" } }

      assert_equal frontmatter, build(frontmatter: frontmatter).frontmatter
    end

    test "requires the URI to address the skill's SKILL.md" do
      error = assert_raises(ArgumentError) do
        Skill.new(uri: "skill://refunds", frontmatter: { name: "refunds", description: "d" }, resources: Skill::DYNAMIC)
      end

      assert_match(/must be the URI of the skill's SKILL.md/, error.message)
    end

    test "requires the frontmatter name to equal the final skill-path segment" do
      error = assert_raises(ArgumentError) { build(frontmatter: { "name" => "rebates", "description" => "d" }) }

      assert_match(/must equal the final segment of the skill path/, error.message)
    end

    test "requires name and description in the frontmatter" do
      assert_raises(ArgumentError) { build(frontmatter: { "name" => "refunds" }) }
      assert_raises(ArgumentError) { build(frontmatter: { "description" => "d" }) }
    end

    test "requires the manifest to list SKILL.md itself" do
      error = assert_raises(ArgumentError) do
        build(resources: [{ uri: "skill://acme/billing/refunds/examples/email.md", digest: DIGEST, size: 1 }])
      end

      assert_match(/must list #{Regexp.escape(SKILL_URI)} itself/, error.message)
    end

    test "rejects duplicate and out-of-skill manifest entries" do
      duplicated = assert_raises(ArgumentError) { build(resources: [manifest_entry, manifest_entry]) }
      assert_match(/more than once/, duplicated.message)

      outside = assert_raises(ArgumentError) do
        build(resources: [manifest_entry, { uri: "skill://other/file.md", digest: DIGEST, size: 1 }])
      end
      assert_match(/fall outside/, outside.message)
    end

    test "rejects a malformed digest or size" do
      assert_raises(ArgumentError) { build(resources: [{ uri: SKILL_URI, digest: "sha256:zz", size: 1 }]) }
      assert_raises(ArgumentError) { build(resources: [{ uri: SKILL_URI, digest: DIGEST, size: -1 }]) }
      assert_raises(ArgumentError) { build(resources: [{ uri: SKILL_URI, digest: DIGEST, size: "10" }]) }
    end

    test "accepts the dynamic marker in place of a manifest" do
      skill = build(resources: Skill::DYNAMIC)

      assert_predicate skill, :dynamic?
      assert_nil skill.total_size
      assert_empty skill.limit_violations
      assert_equal "dynamic", skill.to_h[:resources]
    end

    test "rejects a resources value that is neither a manifest nor the dynamic marker" do
      assert_raises(ArgumentError) { build(resources: nil) }
      assert_raises(ArgumentError) { build(resources: "generated") }
    end

    test "reports the per-skill limits it exceeds instead of refusing the skill" do
      oversized = build(resources: [{ uri: SKILL_URI, digest: DIGEST, size: Skill::MAX_TOTAL_SIZE + 1 }])

      assert_equal 1, oversized.limit_violations.size
      assert_match(/exceeds the #{Skill::MAX_TOTAL_SIZE} per-skill limit/, oversized.limit_violations.first)
    end

    test ".from accepts an instance, a symbol-keyed Hash and a string-keyed Hash" do
      skill = build

      assert_same skill, Skill.from(skill)
      assert_equal skill.to_h, Skill.from(skill.to_h).to_h
      assert_equal skill.to_h, Skill.from({ "uri" => SKILL_URI, "frontmatter" => skill.frontmatter, "resources" => [manifest_entry] }).to_h
      assert_raises(ArgumentError) { Skill.from("skill://refunds/SKILL.md") }
    end

    private

    def manifest_entry
      { uri: SKILL_URI, digest: DIGEST, size: 10 }
    end

    NOT_GIVEN = Object.new

    def build(uri: SKILL_URI, frontmatter: { "name" => "refunds", "description" => "d" }, resources: NOT_GIVEN)
      resources = [manifest_entry] if resources == NOT_GIVEN
      Skill.new(uri: uri, frontmatter: frontmatter, resources: resources)
    end
  end
end
