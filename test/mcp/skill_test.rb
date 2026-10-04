# frozen_string_literal: true

require "test_helper"
require "digest"

module MCP
  class SkillTest < ActiveSupport::TestCase
    SKILL_MD = "---\nname: pdf-processing\ndescription: Extract PDFs\n---\n\nBody.\n"
    FORMS = "Forms\n"

    def digest(content)
      "sha256:#{Digest::SHA256.hexdigest(content)}"
    end

    def entry(uri, content)
      { uri: uri, digest: digest(content), size: content.bytesize }
    end

    def build(uri: "skill://pdf-processing/SKILL.md", frontmatter: { name: "pdf-processing", description: "Extract PDFs" }, resources: nil, meta: nil)
      resources ||= [entry(uri, SKILL_MD), entry("skill://pdf-processing/references/FORMS.md", FORMS)]
      Skill.new(uri: uri, frontmatter: frontmatter, resources: resources, meta: meta)
    end

    test "exposes the SEP-2640 vocabulary" do
      assert_equal "io.modelcontextprotocol/skills", Skill::EXTENSION_ID
      assert_equal 512, Skill::MAX_RESOURCES
      assert_equal 16 * 1024 * 1024, Skill::MAX_TOTAL_SIZE
      assert_equal({ "io.modelcontextprotocol/skills" => {} }, Skill.capability)
    end

    test "holds a frozen entry whose frontmatter has String keys and whose resources are entries" do
      skill = build

      assert_equal "skill://pdf-processing/SKILL.md", skill.uri
      assert_equal ["pdf-processing"], skill.skill_path
      assert_equal "pdf-processing", skill.name
      assert_equal({ "name" => "pdf-processing", "description" => "Extract PDFs" }, skill.frontmatter)
      assert_equal ["skill://pdf-processing/SKILL.md", "skill://pdf-processing/references/FORMS.md"], skill.resources.map(&:uri)
      assert_kind_of Skill::ResourceEntry, skill.resources.first
      assert_equal SKILL_MD.bytesize + FORMS.bytesize, skill.total_size
      refute_predicate skill, :dynamic?
      assert_predicate skill, :frozen?
      assert_predicate skill.frontmatter, :frozen?
      assert_predicate skill.resources, :frozen?
      assert_equal(
        {
          uri: "skill://pdf-processing/SKILL.md",
          frontmatter: { "name" => "pdf-processing", "description" => "Extract PDFs" },
          resources: [
            { uri: "skill://pdf-processing/SKILL.md", digest: digest(SKILL_MD), size: SKILL_MD.bytesize },
            { uri: "skill://pdf-processing/references/FORMS.md", digest: digest(FORMS), size: FORMS.bytesize },
          ],
        },
        skill.to_h,
      )
    end

    test "copies the frontmatter so a caller mutating its Hash afterwards changes nothing" do
      frontmatter = { name: "pdf-processing", description: "Extract PDFs", tags: ["a"] }
      skill = build(frontmatter: frontmatter)
      frontmatter[:tags] << "b"
      frontmatter[:description] = "changed"

      assert_equal({ "name" => "pdf-processing", "description" => "Extract PDFs", "tags" => ["a"] }, skill.frontmatter)
    end

    test "carries the _meta of the entry as a frozen copy under the frontmatter's JSON rules, or none at all" do
      assert_nil build.meta
      refute build.to_h.key?(:_meta)

      tags = ["a"]
      skill = build(meta: { "com.example/origin": "catalog", "io.modelcontextprotocol.skills/tags": tags })
      tags << "b"
      assert_equal({ "com.example/origin" => "catalog", "io.modelcontextprotocol.skills/tags" => ["a"] }, skill.meta)
      assert_predicate skill.meta, :frozen?
      assert_predicate skill.meta["io.modelcontextprotocol.skills/tags"], :frozen?
      assert_equal skill.meta, skill.to_h[:_meta]
      assert_equal({}, build(meta: {}).to_h[:_meta])

      error = assert_raises(ArgumentError) { build(meta: "origin=catalog") }
      assert_equal "The value of meta must be a Hash (got String).", error.message
      error = assert_raises(ArgumentError) { build(meta: { when: Time.at(0) }) }
      assert_equal "The value of meta must be JSON-representable (got Time).", error.message
      error = assert_raises(ArgumentError) { build(meta: { 1 => "one" }) }
      assert_equal "The value of meta keys must be Strings or Symbols (got Integer).", error.message

      remote = Skill.from_entry("uri" => "skill://pdf/SKILL.md", "frontmatter" => { "name" => "pdf", "description" => "d" }, "resources" => "dynamic", "_meta" => { "a" => 1 })
      assert_equal({ "a" => 1 }, remote.meta)
      assert_predicate remote.meta, :frozen?
      assert_equal({ "a" => 1 }, remote.to_h[:_meta])
      remote = Skill.from_entry(uri: "skill://pdf/SKILL.md", frontmatter: { name: "pdf", description: "d" }, resources: "dynamic", _meta: { a: 1 })
      assert_equal({ "a" => 1 }, remote.meta)
      assert_nil Skill.from_entry("uri" => "skill://pdf/SKILL.md", "frontmatter" => { "name" => "pdf", "description" => "d" }, "resources" => "dynamic").meta
      error = assert_raises(ArgumentError) { Skill.from_entry("uri" => "skill://pdf/SKILL.md", "frontmatter" => { "name" => "pdf", "description" => "d" }, "resources" => "dynamic", "_meta" => []) }
      assert_equal "The value of meta must be a Hash (got Array).", error.message
    end

    test "a dynamic skill lists no entries and has no total size" do
      skill = build(resources: "dynamic")

      assert_predicate skill, :dynamic?
      assert_equal "dynamic", skill.resources
      assert_nil skill.total_size
      assert_equal "dynamic", skill.to_h[:resources]
    end

    test "allows nested skill paths and recovers the name from the last segment" do
      skill = Skill.new(
        uri: "skill://acme/billing/refunds/SKILL.md",
        frontmatter: { name: "refunds", description: "Refund flow" },
        resources: [entry("skill://acme/billing/refunds/SKILL.md", "x")],
      )

      assert_equal ["acme", "billing", "refunds"], skill.skill_path
      assert_equal "refunds", skill.name
    end

    test "refuses a uri that does not name a SKILL.md under at least one segment" do
      wide = "skill://pdf/SKILL.md".encode("UTF-16LE")
      ["skill://SKILL.md", "skill://pdf/skill.md", "skill://pdf/SKILL.md/", "http://pdf/SKILL.md", "skill://pdf//SKILL.md", wide, nil].each do |uri|
        error = assert_raises(ArgumentError, uri.inspect) { build(uri: uri, frontmatter: { name: "pdf", description: "d" }, resources: "dynamic") }
        assert_equal "The value of uri must be a skill://<path>/SKILL.md URI with non-empty path segments.", error.message
      end
    end

    test "refuses local segments outside the unreserved URI characters" do
      error = assert_raises(ArgumentError) { build(uri: "skill://pdf%20tools/SKILL.md", frontmatter: { name: "pdf%20tools", description: "d" }, resources: "dynamic") }
      assert_equal "The value of uri may only use letters, digits, -, ., _, and ~ in its segments.", error.message
    end

    test "refuses frontmatter that is not a Hash with non-empty name and description" do
      error = assert_raises(ArgumentError) { build(frontmatter: "name: pdf", resources: "dynamic") }
      assert_equal "The value of frontmatter must be a Hash (got String).", error.message

      error = assert_raises(ArgumentError) { build(frontmatter: { description: "d" }, resources: "dynamic") }
      assert_equal "The value of frontmatter must hold a non-empty String under name.", error.message

      error = assert_raises(ArgumentError) { build(frontmatter: { name: "pdf-processing", description: "" }, resources: "dynamic") }
      assert_equal "The value of frontmatter must hold a non-empty String under description.", error.message

      error = assert_raises(ArgumentError) { build(frontmatter: { name: "other", description: "d" }, resources: "dynamic") }
      assert_equal "The frontmatter name must equal the last segment of the skill path.", error.message
    end

    test "holds a locally defined skill to the Agent Skills rules for name and description" do
      named = ->(name) { build(uri: "skill://#{name}/SKILL.md", frontmatter: { name: name, description: "d" }, resources: "dynamic") }

      ["PDF", "pdf_tools", "pdf.tools", "-pdf", "pdf-", "pdf--tools", "a" * 65].each do |name|
        error = assert_raises(ArgumentError, name) { named.call(name) }
        assert_equal "The frontmatter name must be 1 to 64 lowercase letters, digits, and single hyphens between them.", error.message
      end
      ["pdf", "pdf-tools", "a1-b2-c3", "a" * 64].each { |name| assert_equal name, named.call(name).name }

      error = assert_raises(ArgumentError) { build(frontmatter: { name: "pdf-processing", description: "d" * 1025 }, resources: "dynamic") }
      assert_equal "The frontmatter description must hold at most 1024 characters.", error.message
      assert build(frontmatter: { name: "pdf-processing", description: "d" * 1024 }, resources: "dynamic")

      # A leading segment is a namespace, not a name, and an entry a server sent is not held to these rules.
      assert build(uri: "skill://Acme_Corp/pdf/SKILL.md", frontmatter: { name: "pdf", description: "d" }, resources: "dynamic")
      remote = Skill.from_entry(
        "uri" => "skill://PDF_Tools/SKILL.md",
        "frontmatter" => { "name" => "PDF_Tools", "description" => "d" * 2000 },
        "resources" => "dynamic",
      )
      assert_equal "PDF_Tools", remote.name
    end

    test "refuses frontmatter values JSON cannot carry, cycles, and keys that collide once stringified" do
      error = assert_raises(ArgumentError) { build(frontmatter: { name: "pdf-processing", description: "d", when: Time.at(0) }, resources: "dynamic") }
      assert_equal "The value of frontmatter must be JSON-representable (got Time).", error.message

      error = assert_raises(ArgumentError) { build(frontmatter: { name: "pdf-processing", description: "d", ratio: Float::NAN }, resources: "dynamic") }
      assert_equal "The value of frontmatter must hold finite numbers.", error.message

      error = assert_raises(ArgumentError) { build(frontmatter: { name: "pdf-processing", description: "d", big: 2**53 }) }
      assert_equal "The value of frontmatter must hold integers within 2**53.", error.message
      assert_equal (2**53) - 1, build(frontmatter: { name: "pdf-processing", description: "d", big: (2**53) - 1 }).frontmatter["big"]

      cyclic = { name: "pdf-processing", description: "d" }
      cyclic[:self] = cyclic
      error = assert_raises(ArgumentError) { build(frontmatter: cyclic, resources: "dynamic") }
      assert_equal "The value of frontmatter must not be cyclic.", error.message

      error = assert_raises(ArgumentError) { build(frontmatter: { name: "pdf-processing", description: "d", "x" => 1, x: 2 }, resources: "dynamic") }
      assert_equal 'The value of frontmatter keys collide after stringification ("x").', error.message

      error = assert_raises(ArgumentError) { build(frontmatter: { name: "pdf-processing", description: "d", 1 => "one" }, resources: "dynamic") }
      assert_equal "The value of frontmatter keys must be Strings or Symbols (got Integer).", error.message
    end

    test "refuses frontmatter and meta strings JSON cannot encode, whatever encoding they are labeled with" do
      binary = "\xFF".b
      mislabeled = "\xFF".dup.force_encoding(Encoding::UTF_8)
      refute_predicate mislabeled, :valid_encoding?
      assert_predicate binary, :valid_encoding?

      # The second binary String holds the UTF-8 bytes of one character; only its label keeps `utf8_encodable?` from accepting it.
      [binary, "\u00E9".b, mislabeled, "\x82".dup.force_encoding(Encoding::Shift_JIS)].each do |value|
        error = assert_raises(ArgumentError, value.inspect) { build(frontmatter: { name: "pdf-processing", description: "d", note: value }, resources: "dynamic") }
        assert_equal "The value of frontmatter must hold strings JSON can encode.", error.message
        error = assert_raises(ArgumentError, value.inspect) { build(meta: { note: value }) }
        assert_equal "The value of meta must hold strings JSON can encode.", error.message
      end
      error = assert_raises(ArgumentError) { build(frontmatter: { name: "pdf-processing", description: "d", binary => "x" }, resources: "dynamic") }
      assert_equal "The value of frontmatter must hold strings JSON can encode.", error.message
      error = assert_raises(ArgumentError) { build(meta: { binary.to_sym => "x" }) }
      assert_equal "The value of meta must hold strings JSON can encode.", error.message
      error = assert_raises(ArgumentError) { Skill.from_entry("uri" => "skill://pdf/SKILL.md", "frontmatter" => { "name" => "pdf", "description" => "d", "note" => binary }, "resources" => "dynamic") }
      assert_equal "The value of frontmatter must hold strings JSON can encode.", error.message

      # Labeled encodings JSON can convert stay as given; the generated document carries the characters.
      skill = build(frontmatter: { name: "pdf-processing", description: "d", note: "\u3042".encode(Encoding::Shift_JIS), ascii: "plain".b }, resources: "dynamic", meta: { note: "a".encode(Encoding::UTF_16LE) })
      assert_equal Encoding::Shift_JIS, skill.frontmatter["note"].encoding
      generated = JSON.parse(JSON.generate(skill.to_h))
      assert_equal "\u3042", generated["frontmatter"]["note"]
      assert_equal "plain", generated["frontmatter"]["ascii"]
      assert_equal "a", generated["_meta"]["note"]
    end

    test "refuses frontmatter nested deeper than JSON.parse reads by default" do
      nested = ->(levels) { levels.times.inject("leaf") { |value, _| [value] } }
      frontmatter = ->(levels) { { name: "pdf-processing", description: "d", metadata: nested.call(levels) } }

      # The frontmatter Hash is the first level.
      assert build(frontmatter: frontmatter.call(Skill::Json::MAX_DEPTH - 1), resources: "dynamic")
      error = assert_raises(ArgumentError) { build(frontmatter: frontmatter.call(Skill::Json::MAX_DEPTH), resources: "dynamic") }
      assert_equal "The value of frontmatter must not nest deeper than 100 levels.", error.message
    end

    test "refuses resources that are neither dynamic nor an Array, and entries that break the manifest rules" do
      error = assert_raises(ArgumentError) { build(resources: { uri: "x" }) }
      assert_equal 'The value of resources must be "dynamic" or an Array of entries (got Hash).', error.message

      error = assert_raises(ArgumentError) { build(resources: [entry("skill://pdf-processing/SKILL.md", "x"), "nope"]) }
      assert_equal "resources[1]: A skill resource entry must be an MCP::Skill::ResourceEntry or a Hash (got String).", error.message

      error = assert_raises(ArgumentError) { build(resources: [entry("skill://pdf-processing/SKILL.md", "x"), entry("skill://pdf-processing-extra/x", "y")]) }
      assert_equal 'resources[1]: The entry uri must lie under "skill://pdf-processing".', error.message

      error = assert_raises(ArgumentError) { build(resources: [entry("skill://pdf-processing/SKILL.md", "x"), entry("skill://pdf-processing/SKILL.md", "y")]) }
      assert_equal "resources[1]: The entry uri is listed twice.", error.message

      error = assert_raises(ArgumentError) { build(resources: [entry("skill://pdf-processing/references/FORMS.md", "x")]) }
      assert_equal "The value of resources must list the skill's own SKILL.md.", error.message

      # A nested skill's SKILL.md is a supporting file of the enclosing skill, so listing it is fine.
      enclosing = build(resources: [entry("skill://pdf-processing/SKILL.md", "x"), entry("skill://pdf-processing/inner/SKILL.md", "y")])
      assert_equal ["skill://pdf-processing/SKILL.md", "skill://pdf-processing/inner/SKILL.md"], enclosing.resources.map(&:uri)
    end

    test "refuses a local skill over the SEP limits" do
      many = Array.new(512) { |index| entry("skill://pdf-processing/f#{index}", "x") } + [entry("skill://pdf-processing/SKILL.md", "x")]
      error = assert_raises(ArgumentError) { build(resources: many) }
      assert_equal "The value of resources must hold at most 512 entries.", error.message

      assert_equal 512, build(resources: many[1..-1]).resources.size

      big = [entry("skill://pdf-processing/SKILL.md", "x"), { uri: "skill://pdf-processing/big", digest: digest("x"), size: Skill::MAX_TOTAL_SIZE }]
      error = assert_raises(ArgumentError) { build(resources: big) }
      assert_equal "The value of resources must list at most 16777216 bytes in total.", error.message
    end

    test "from_entry accepts a remote entry structurally, beyond the limits and the local character set" do
      resources = Array.new(600) { |index| { "uri" => "skill://acme/r%20d/f#{index}", "digest" => digest("x"), "size" => 100_000 } }
      resources << { "uri" => "skill://acme/r%20d/SKILL.md", "digest" => digest("x"), "size" => 1 }
      resources << { "uri" => "skill://acme/r%20d/inner/SKILL.md", "digest" => digest("x"), "size" => 1 }
      skill = Skill.from_entry("uri" => "skill://acme/r%20d/SKILL.md", "frontmatter" => { "name" => "r%20d", "description" => "d" }, "resources" => resources)

      assert_equal 602, skill.resources.size
      assert_equal 60_000_002, skill.total_size
      assert_predicate skill, :frozen?

      error = assert_raises(ArgumentError) { Skill.from_entry("uri" => "skill://acme/SKILL.md", "frontmatter" => { "name" => "acme", "description" => "d" }, "resources" => [{ "uri" => "skill://acme/x", "digest" => digest("x"), "size" => 1 }]) }
      assert_equal "The value of resources must list the skill's own SKILL.md.", error.message

      error = assert_raises(ArgumentError) { Skill.from_entry("not a hash") }
      assert_equal "A skill entry must be a Hash (got String).", error.message
    end

    test "verify_resource checks the size then the digest of the bytes against the listed entry" do
      skill = build

      assert Skill.verify_resource(skill, "skill://pdf-processing/references/FORMS.md", FORMS.b)

      error = assert_raises(Client::SkillVerificationError) { Skill.verify_resource(skill, "skill://pdf-processing/references/FORMS.md", "Forms!\n".b) }
      assert_equal :size, error.reason
      assert_equal "skill://pdf-processing/references/FORMS.md", error.uri
      assert_equal "skill://pdf-processing/SKILL.md", error.skill_uri

      error = assert_raises(Client::SkillVerificationError) { Skill.verify_resource(skill, "skill://pdf-processing/references/FORMS.md", "Formz\n".b) }
      assert_equal :digest, error.reason

      error = assert_raises(Client::SkillReadRefusedError) { Skill.verify_resource(skill, "skill://pdf-processing/other.md", "x") }
      assert_equal :not_in_manifest, error.reason

      # RIGHT-TO-LEFT OVERRIDE, which `inspect` would leave as it is.
      reordering = "skill://pdf-processing/#{[0x202E].pack("U")}other.md"
      error = assert_raises(Client::SkillReadRefusedError) { Skill.verify_resource(skill, reordering, "x") }
      assert_predicate error.message, :ascii_only?
      assert_equal reordering, error.uri

      error = assert_raises(Client::SkillReadRefusedError) { Skill.verify_resource(build(resources: "dynamic"), "skill://pdf-processing/SKILL.md", "x") }
      assert_equal :dynamic, error.reason

      assert_raises(ArgumentError) { Skill.verify_resource("skill", "skill://pdf-processing/SKILL.md", "x") }
      assert_raises(ArgumentError) { Skill.verify_resource(skill, "skill://pdf-processing/SKILL.md", 1) }
    end

    test "verify_frontmatter compares the fetched SKILL.md with the entry field by field" do
      skill = build

      assert Skill.verify_frontmatter(skill, SKILL_MD)
      assert_raises(ArgumentError) { Skill.verify_frontmatter(nil, SKILL_MD) }
      assert_raises(ArgumentError) { Skill.verify_frontmatter(skill, nil) }
      assert Skill.verify_frontmatter(skill, "---\ndescription: Extract PDFs\nname: pdf-processing\n---\nother body\n")

      error = assert_raises(Client::SkillVerificationError) { Skill.verify_frontmatter(skill, SKILL_MD.sub("Extract PDFs", "Exfiltrate credentials")) }
      assert_equal :frontmatter, error.reason
      assert_equal "skill://pdf-processing/SKILL.md", error.uri

      error = assert_raises(Client::SkillVerificationError) { Skill.verify_frontmatter(skill, "---\nname: pdf-processing\ndescription: Extract PDFs\nextra: 1\n---\n") }
      assert_equal :frontmatter, error.reason

      error = assert_raises(Client::SkillVerificationError) { Skill.verify_frontmatter(skill, "no frontmatter here") }
      assert_equal :parse, error.reason

      error = assert_raises(Client::SkillVerificationError) { Skill.verify_frontmatter(skill, "---\nname: pdf-processing\ndescription: Extract PDFs\nflag: yes\n---\n") }
      assert_equal :parse, error.reason
      refute_includes error.message, "yes"
    end

    test "local resource URIs are held to the unreserved character set, remote ones only to the structure" do
      error = assert_raises(ArgumentError) do
        build(resources: [entry("skill://pdf-processing/SKILL.md", "x"), entry("skill://pdf-processing/My%20Forms.md", "y")])
      end
      assert_equal "resources[1]: The entry uri may only use letters, digits, -, ., _, and ~ in its segments.", error.message

      remote = Skill.from_entry(
        "uri" => "skill://pdf-processing/SKILL.md",
        "frontmatter" => { "name" => "pdf-processing", "description" => "d" },
        "resources" => [
          entry("skill://pdf-processing/SKILL.md", "x").to_h,
          { "uri" => "skill://pdf-processing/My%20Forms.md", "digest" => digest("y"), "size" => 1, "mimeType" => "text/markdown" },
        ],
      )
      assert_equal ["skill://pdf-processing/SKILL.md", "skill://pdf-processing/My%20Forms.md"], remote.resources.map(&:uri)

      error = assert_raises(ArgumentError) { build(resources: [entry("skill://pdf-processing/SKILL.md", "x").to_h.merge(mimeType: "text/markdown")]) }
      assert_match(/may only hold uri, digest, and size/, error.message)
    end

    test "Uri derives candidate skill URIs from the segments and applies the segment boundary" do
      uri = Skill::Uri

      assert uri.structural?("skill://a/b")
      refute uri.structural?("skill://a//b")
      refute uri.structural?("skill://")
      assert uri.manifest_uri?("skill://a/b/SKILL.md")
      refute uri.manifest_uri?("skill://SKILL.md")
      refute uri.manifest_uri?("skill://a/b/skill.md")
      assert_equal ["a", "b"], uri.skill_path("skill://a/b/SKILL.md")
      assert_equal "skill://a/b", uri.root(["a", "b"])
      assert uri.under?("skill://a/b/x", "skill://a/b")
      refute uri.under?("skill://ab/x", "skill://a")
      refute uri.under?("skill://a/b", "skill://a/b")
      assert_equal ["skill://a/SKILL.md", "skill://a/b/SKILL.md", "skill://a/b/c/SKILL.md"], uri.candidate_skill_uris("skill://a/b/c/file.md")
      assert_equal ["skill://a/SKILL.md", "skill://a/b/SKILL.md"], uri.candidate_skill_uris("skill://a/b/SKILL.md")
      assert_empty uri.candidate_skill_uris("skill://a")
      assert_empty uri.candidate_skill_uris("http://a/b")

      assert uri.resolvable?("skill://#{Array.new(uri::MAX_RESOLVED_SEGMENTS, "a").join("/")}")
      refute uri.resolvable?("skill://#{Array.new(uri::MAX_RESOLVED_SEGMENTS + 1, "a").join("/")}")
      prefix = "skill://a/"
      assert uri.resolvable?(prefix + "x" * (uri::MAX_RESOLVED_BYTES - prefix.bytesize))
      refute uri.resolvable?(prefix + "x" * (uri::MAX_RESOLVED_BYTES - prefix.bytesize + 1))
    end
  end
end
