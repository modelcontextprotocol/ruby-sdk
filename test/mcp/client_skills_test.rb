# frozen_string_literal: true

require "test_helper"
require "digest"

module MCP
  class ClientSkillsTest < ActiveSupport::TestCase
    SKILL_MD = "---\nname: pdf-processing\ndescription: Extract PDFs\n---\n\nBody.\n"
    FORMS = "Forms\n"
    LOGO = "\x89PNG\r\n\x1a\n\xFF".b
    SKILL_URI = "skill://pdf-processing/SKILL.md"
    FORMS_URI = "skill://pdf-processing/references/FORMS.md"
    LOGO_URI = "skill://pdf-processing/logo.png"

    def digest(content)
      "sha256:#{Digest::SHA256.hexdigest(content)}"
    end

    def wire_entry(uri, content)
      { "uri" => uri, "digest" => digest(content), "size" => content.bytesize }
    end

    def pdf_entry(skill_md: SKILL_MD)
      {
        "uri" => SKILL_URI,
        "frontmatter" => { "name" => "pdf-processing", "description" => "Extract PDFs" },
        "resources" => [wire_entry(SKILL_URI, skill_md), wire_entry(FORMS_URI, FORMS), wire_entry(LOGO_URI, LOGO)],
      }
    end

    # A transport with a canned catalog and file store. `connect` returns the wire Hash a legacy handshake
    # returns and may block on a Queue; `send_request` may run a hook first, so a test can act mid-flight.
    class FakeTransport
      attr_accessor :connected, :capabilities, :skills, :files, :gate, :hook, :requests, :get_answer

      def initialize(skills, files)
        @connected = false
        @capabilities = { "resources" => {}, "extensions" => { Skill::EXTENSION_ID => {} } }
        @skills = skills
        @files = files
        @gate = nil
        @hook = nil
        @requests = []
        @get_answer = nil
      end

      def connect(client_info: nil, protocol_version: nil, capabilities: {})
        outcome = @gate&.pop
        raise outcome if outcome.is_a?(Exception)

        @connected = true
        { "protocolVersion" => "2025-11-25", "capabilities" => @capabilities, "serverInfo" => { "name" => "fake", "version" => "1" } }
      end

      def connected?
        @connected
      end

      def send_request(request:)
        @requests << request
        hook = @hook
        @hook = nil
        hook&.call(request)

        case request[:method]
        when "skills/list" then { "result" => { "skills" => @skills } }
        when "skills/get"
          skill = @get_answer || @skills.find { |candidate| candidate["uri"] == request[:params][:uri] }
          skill ? { "result" => { "skill" => skill } } : { "error" => { "code" => -32602, "message" => "Skill not found" } }
        when "resources/read"
          uri = request[:params][:uri]
          item = @files[uri]
          { "result" => { "contents" => item ? [{ "uri" => uri, "mimeType" => "text/markdown" }.merge(item)] : [] } }
        end
      end
    end

    def files
      { SKILL_URI => { "text" => SKILL_MD.dup }, FORMS_URI => { "text" => FORMS.dup }, LOGO_URI => { "blob" => [LOGO].pack("m0") } }
    end

    def connected_client(skills: [pdf_entry], files: self.files)
      transport = FakeTransport.new(skills, files)
      client = Client.new(transport: transport)
      client.connect
      [client, transport]
    end

    def assert_refused(reason, &block)
      error = assert_raises(Client::SkillReadRefusedError, &block)
      assert_equal reason, error.reason
      error
    end

    def assert_verification_failure(reason, &block)
      error = assert_raises(Client::SkillVerificationError, &block)
      assert_equal reason, error.reason
      error
    end

    test "skills calls are refused until a handshake of this connection advertised the extension and resources" do
      transport = FakeTransport.new([pdf_entry], files)
      client = Client.new(transport: transport)
      assert_refused(:not_advertised) { client.list_skills }
      assert_refused(:not_advertised) { client.get_skill(uri: SKILL_URI) }
      assert_refused(:not_advertised) { client.read_skill_resource(uri: SKILL_URI) }
      assert_nil client.skills_capability
      assert_empty transport.requests

      transport.capabilities = { "resources" => {} }
      client.connect
      assert_refused(:not_advertised) { client.list_skills }

      transport.connected = false
      transport.capabilities = { "extensions" => { Skill::EXTENSION_ID => {} } }
      client.connect
      assert_refused(:not_advertised) { client.list_skills }

      transport.connected = false
      transport.capabilities = { "resources" => {}, "extensions" => { Skill::EXTENSION_ID => "yes" } }
      client.connect
      assert_refused(:not_advertised) { client.list_skills }

      transport.connected = false
      transport.capabilities = { "resources" => {}, "extensions" => { Skill::EXTENSION_ID => {} } }
      client.connect
      assert_equal({}, client.skills_capability)
      assert_predicate client.skills_capability, :frozen?
      assert_equal 1, client.list_skills.skills.size
    end

    test "a transport that reports itself disconnected refuses skills calls until the next connect" do
      client, transport = connected_client
      transport.connected = false

      assert_refused(:not_advertised) { client.list_skills }
      assert_nil client.skills_capability
      client.connect
      assert_equal 1, client.list_skills.skills.size
    end

    test "a transport without connect never becomes ready" do
      transport = mock
      transport.stubs(:respond_to?).with(:connect).returns(false)
      transport.stubs(:respond_to?).with(:connected?).returns(false)
      client = Client.new(transport: transport)

      assert_nil client.connect
      assert_refused(:not_advertised) { client.list_skills }
    end

    test "list_skills returns a frozen page of entries and remembers them" do
      git = { "uri" => "skill://git/SKILL.md", "frontmatter" => { "name" => "git", "description" => "Git" }, "resources" => "dynamic" }
      client, transport = connected_client(skills: [pdf_entry, git])
      page = client.list_skills

      assert_kind_of Client::ListSkillsResult, page
      assert_predicate page, :frozen?
      assert_predicate page.skills, :frozen?
      assert_equal [SKILL_URI, "skill://git/SKILL.md"], page.skills.map(&:uri)
      assert_kind_of Skill, page.skills.first
      assert_nil page.next_cursor
      assert_equal "skills/list", transport.requests.last[:method]
      refute transport.requests.last.key?(:params)

      client.list_skills(cursor: "1", meta: { "x" => 1 })
      assert_equal({ cursor: "1", _meta: { "x" => 1 } }, transport.requests.last[:params])
    end

    test "list_skills and get_skill validate the result and remember nothing from a malformed one" do
      client, transport = connected_client

      transport.skills = [pdf_entry.merge("resources" => [wire_entry(FORMS_URI, FORMS)])]
      assert_raises(Client::SkillEntryError) { client.list_skills }
      transport.skills = [pdf_entry, pdf_entry]
      error = assert_raises(Client::SkillEntryError) { client.list_skills }
      assert_match(/listed twice/, error.message)
      transport.skills = "nope"
      assert_raises(Client::SkillEntryError) { client.list_skills }
      assert_refused(:unknown_skill) { client.read_skill_resource(uri: SKILL_URI) }

      transport.skills = [pdf_entry]
      got = client.get_skill(uri: SKILL_URI)
      assert_kind_of Client::GetSkillResult, got
      assert_predicate got, :frozen?
      assert_equal SKILL_URI, got.skill.uri

      transport.get_answer = { "uri" => "skill://other/SKILL.md", "frontmatter" => { "name" => "other", "description" => "d" }, "resources" => "dynamic" }
      error = assert_raises(Client::SkillEntryError) { client.get_skill(uri: SKILL_URI) }
      assert_includes error.message, 'answered for "skill://other/SKILL.md" instead of "skill://pdf-processing/SKILL.md"'
      transport.get_answer = nil

      assert_raises(Client::ServerError) { client.get_skill(uri: "skill://nope/SKILL.md") }
      assert_raises(ArgumentError) { client.get_skill(uri: 42) }
    end

    test "remote entries beyond the limits are accepted and expose their size" do
      resources = Array.new(600) { |index| { "uri" => "skill://big/f#{index}", "digest" => digest("x"), "size" => 100_000 } } + [wire_entry("skill://big/SKILL.md", "x")]
      client, _transport = connected_client(skills: [{ "uri" => "skill://big/SKILL.md", "frontmatter" => { "name" => "big", "description" => "d" }, "resources" => resources }])
      skill = client.list_skills.skills.first

      assert_equal 601, skill.resources.size
      assert_equal 60_000_001, skill.total_size
    end

    test "read_skill_resource verifies the SKILL.md first, then supporting files, and returns independent frozen values" do
      client, transport = connected_client
      assert_refused(:unknown_skill) { client.read_skill_resource(uri: FORMS_URI) }
      page = client.list_skills
      assert_refused(:skill_md_unverified) { client.read_skill_resource(uri: FORMS_URI) }
      assert_equal 1, transport.requests.size, "refusals send nothing"

      result = client.read_skill_resource(uri: SKILL_URI)
      assert_kind_of Client::SkillReadResult, result
      assert_predicate result, :frozen?
      assert_equal SKILL_URI, result.uri
      assert_equal SKILL_MD.b, result.bytes
      assert_equal Encoding::BINARY, result.bytes.encoding
      assert_predicate result.bytes, :frozen?
      assert_equal "text/markdown", result.mime_type
      assert_same page.skills.first, result.skill
      assert result.verified
      assert_predicate result.contents, :frozen?
      assert_predicate result.contents.first, :frozen?
      assert_equal [{ "uri" => SKILL_URI, "mimeType" => "text/markdown", "text" => SKILL_MD }], result.contents

      transport.files[SKILL_URI]["text"] << "mutated after the read"
      assert_equal SKILL_MD, result.contents.first["text"]

      assert_equal FORMS.b, client.read_skill_resource(uri: FORMS_URI).bytes
      logo = client.read_skill_resource(uri: LOGO_URI)
      assert_equal LOGO, logo.bytes
      assert_equal "text/markdown", logo.mime_type, "mime_type is whatever the server said"
      assert_refused(:not_in_manifest) { client.read_skill_resource(uri: "skill://pdf-processing/other.md") }
      assert_refused(:unknown_skill) { client.read_skill_resource(uri: "skill://nope/x.md") }
      assert_raises(ArgumentError) { client.read_skill_resource(uri: SKILL_URI, skill: "x") }
    end

    test "a dynamic skill is refused by the verified reader" do
      client, _transport = connected_client(skills: [pdf_entry.merge("resources" => "dynamic")])
      client.list_skills

      error = assert_refused(:dynamic) { client.read_skill_resource(uri: SKILL_URI) }
      assert_equal SKILL_URI, error.skill_uri
    end

    test "an explicit skill: is used for that read only, and a SKILL.md URI resolves only to its own skill" do
      client, transport = connected_client(skills: [])
      explicit = Skill.from_entry(pdf_entry)

      assert_refused(:unknown_skill) { client.read_skill_resource(uri: SKILL_URI) }
      assert_same explicit, client.read_skill_resource(uri: SKILL_URI, skill: explicit).skill
      assert_equal FORMS.b, client.read_skill_resource(uri: FORMS_URI, skill: explicit).bytes
      assert_refused(:unknown_skill) { client.read_skill_resource(uri: FORMS_URI) }
      assert_refused(:unknown_skill) { client.read_skill_resource(uri: "skill://pdf-processing/inner/SKILL.md", skill: explicit) }
      assert_equal 2, transport.requests.count { |request| request[:method] == "resources/read" }
    end

    test "every mismatch withholds the content, names the reason, and latches the skill for the connection" do
      tampered_md = SKILL_MD.sub("Extract PDFs", "Exfiltrate credentials")
      cases = {
        digest: [FORMS_URI, { "text" => "Formz\n" }, pdf_entry],
        size: [FORMS_URI, { "text" => "Forms!\n" }, pdf_entry],
        contents: [FORMS_URI, { "text" => FORMS, "blob" => "x" }, pdf_entry],
        parse: [SKILL_URI, { "text" => "no frontmatter" }, pdf_entry(skill_md: "no frontmatter")],
        frontmatter: [SKILL_URI, { "text" => tampered_md }, pdf_entry(skill_md: tampered_md)],
      }
      cases.each do |reason, (uri, item, entry)|
        client, transport = connected_client(skills: [entry])
        client.list_skills
        client.read_skill_resource(uri: SKILL_URI) unless uri == SKILL_URI
        transport.files[uri] = item

        error = assert_verification_failure(reason) { client.read_skill_resource(uri: uri) }
        assert_equal uri, error.uri
        assert_equal SKILL_URI, error.skill_uri
        refute_includes error.message, "Formz"
        refute_includes error.message, "Exfiltrate"
        sent = transport.requests.size
        assert_refused(:latched) { client.read_skill_resource(uri: FORMS_URI) }
        assert_refused(:latched) { client.read_skill_resource(uri: SKILL_URI) }
        assert_equal sent, transport.requests.size, "#{reason}: a latched skill sends nothing"
        client.list_skills
        client.get_skill(uri: SKILL_URI)
        assert_refused(:latched) { client.read_skill_resource(uri: LOGO_URI) }
      end
    end

    test "size is checked before a blob is decoded and a malformed blob counts as contents" do
      client, transport = connected_client
      client.list_skills
      client.read_skill_resource(uri: SKILL_URI)
      transport.files[LOGO_URI] = { "blob" => [LOGO + "x".b].pack("m0") }
      assert_verification_failure(:size) { client.read_skill_resource(uri: LOGO_URI) }

      client, transport = connected_client
      client.list_skills
      client.read_skill_resource(uri: SKILL_URI)
      transport.files[LOGO_URI] = { "blob" => "not base64!" }
      assert_verification_failure(:contents) { client.read_skill_resource(uri: LOGO_URI) }

      client, transport = connected_client
      client.list_skills
      client.read_skill_resource(uri: SKILL_URI)
      transport.files[LOGO_URI] = { "blob" => [LOGO.byteslice(0, 4)].pack("m0") }
      assert_verification_failure(:size) { client.read_skill_resource(uri: LOGO_URI) }
    end

    test "a response that is not exactly one item for the requested URI is a contents failure" do
      client, transport = connected_client
      client.list_skills
      transport.files.delete(SKILL_URI)
      assert_verification_failure(:contents) { client.read_skill_resource(uri: SKILL_URI) }

      client, transport = connected_client
      client.list_skills
      transport.define_singleton_method(:send_request) do |request:|
        if request[:method] == "resources/read"
          { "result" => { "contents" => [{ "uri" => "skill://other/SKILL.md", "text" => SKILL_MD }] } }
        else
          super(request: request)
        end
      end
      assert_verification_failure(:contents) { client.read_skill_resource(uri: SKILL_URI) }

      client, transport = connected_client
      client.list_skills
      transport.define_singleton_method(:send_request) do |request:|
        if request[:method] == "resources/read"
          { "result" => { "contents" => [{ "uri" => SKILL_URI, "text" => SKILL_MD }, { "uri" => SKILL_URI, "text" => SKILL_MD }] } }
        else
          super(request: request)
        end
      end
      assert_verification_failure(:contents) { client.read_skill_resource(uri: SKILL_URI) }
    end

    test "latches survive a connect that performs no new handshake and are cleared by a real reconnect" do
      client, transport = connected_client
      client.list_skills
      transport.files[SKILL_URI] = { "text" => SKILL_MD.sub("Body.", "Evil!") }
      assert_verification_failure(:digest) { client.read_skill_resource(uri: SKILL_URI) }

      client.connect
      assert_refused(:latched) { client.read_skill_resource(uri: SKILL_URI) }

      transport.connected = false
      transport.files[SKILL_URI] = { "text" => SKILL_MD }
      client.connect
      assert_refused(:unknown_skill) { client.read_skill_resource(uri: SKILL_URI) }
      client.list_skills
      assert client.read_skill_resource(uri: SKILL_URI).verified
    end

    test "a latched ancestor refuses an unknown descendant before unknown_skill, and an enclosing skill is reached only through skill:" do
      outer_md = "---\nname: outer\ndescription: Outer\n---\n"
      inner_md = "---\nname: inner\ndescription: Inner\n---\n"
      outer = {
        "uri" => "skill://acme/outer/SKILL.md",
        "frontmatter" => { "name" => "outer", "description" => "Outer" },
        "resources" => [
          wire_entry("skill://acme/outer/SKILL.md", outer_md),
          wire_entry("skill://acme/outer/inner/notes.txt", "notes\n"),
          wire_entry("skill://acme/outer/inner/SKILL.md", inner_md),
        ],
      }
      inner = {
        "uri" => "skill://acme/outer/inner/SKILL.md",
        "frontmatter" => { "name" => "inner", "description" => "Inner" },
        "resources" => [wire_entry("skill://acme/outer/inner/SKILL.md", inner_md)],
      }
      store = {
        "skill://acme/outer/SKILL.md" => { "text" => outer_md.sub("Outer", "Changed") },
        "skill://acme/outer/inner/notes.txt" => { "text" => "notes\n" },
        "skill://acme/outer/inner/SKILL.md" => { "text" => inner_md },
      }
      honest_outer = outer.merge("resources" => [wire_entry("skill://acme/outer/SKILL.md", outer_md.sub("Outer", "Changed")), *outer["resources"][1..-1]])

      # Only the outer skill is remembered: the inner SKILL.md never resolves as the outer skill's file, and
      # a latched ancestor refuses its descendants before anything else is considered.
      client, _transport = connected_client(skills: [honest_outer], files: store)
      client.list_skills
      assert_refused(:unknown_skill) { client.read_skill_resource(uri: "skill://acme/outer/inner/SKILL.md") }
      assert_verification_failure(:frontmatter) { client.read_skill_resource(uri: "skill://acme/outer/SKILL.md") }
      assert_refused(:latched) { client.read_skill_resource(uri: "skill://acme/outer/inner/notes.txt") }
      assert_refused(:latched) { client.read_skill_resource(uri: "skill://acme/outer/inner/SKILL.md") }

      # Both remembered, in either order: a file the nested skill leaves out is never verified against the enclosing
      # manifest automatically, whatever verified, because the nested entry is the most specific one; a host acting
      # on the enclosing skill names it. The nested SKILL.md resolves only to the nested entry.
      honest_store = store.merge("skill://acme/outer/SKILL.md" => { "text" => outer_md })
      [[outer, inner], [inner, outer]].each do |order|
        client, transport = connected_client(skills: order, files: honest_store)
        outer_entry = client.list_skills.skills.find { |skill| skill.uri == outer["uri"] }
        assert_refused(:ambiguous) { client.read_skill_resource(uri: "skill://acme/outer/inner/notes.txt") }
        assert_refused(:skill_md_unverified) { client.read_skill_resource(uri: "skill://acme/outer/inner/notes.txt", skill: outer_entry) }
        assert client.read_skill_resource(uri: "skill://acme/outer/SKILL.md").verified
        error = assert_refused(:ambiguous) { client.read_skill_resource(uri: "skill://acme/outer/inner/notes.txt") }
        assert_equal inner["uri"], error.skill_uri
        result = client.read_skill_resource(uri: "skill://acme/outer/inner/notes.txt", skill: outer_entry)
        assert_equal "notes\n".b, result.bytes
        assert_equal outer["uri"], result.skill.uri
        assert client.read_skill_resource(uri: "skill://acme/outer/inner/SKILL.md").verified
        assert_equal 3, transport.requests.count { |request| request[:method] == "resources/read" }
      end

      # A dynamic nested skill is the most specific entry too: the automatic path answers for it and never falls
      # back to the enclosing manifest that lists the file.
      dynamic_inner = inner.merge("resources" => "dynamic")
      client, transport = connected_client(skills: [outer, dynamic_inner], files: honest_store)
      outer_entry = client.list_skills.skills.find { |skill| skill.uri == outer["uri"] }
      assert client.read_skill_resource(uri: "skill://acme/outer/SKILL.md").verified
      assert_refused(:dynamic) { client.read_skill_resource(uri: "skill://acme/outer/inner/notes.txt") }
      assert_equal 1, transport.requests.count { |request| request[:method] == "resources/read" }
      assert_equal "notes\n".b, client.read_skill_resource(uri: "skill://acme/outer/inner/notes.txt", skill: outer_entry).bytes

      # A file both skills list is never picked between automatically, whatever verified: only the host knows which
      # skill it is acting on, so it names that entry with skill:, and the file is verified against that manifest.
      inner_listing_notes = inner.merge("resources" => [*inner["resources"], wire_entry("skill://acme/outer/inner/notes.txt", "notes\n")])
      client, _transport = connected_client(skills: [outer, inner_listing_notes], files: honest_store)
      entries = client.list_skills.skills.to_h { |skill| [skill.uri, skill] }
      assert client.read_skill_resource(uri: "skill://acme/outer/SKILL.md").verified
      assert client.read_skill_resource(uri: "skill://acme/outer/inner/SKILL.md").verified
      error = assert_refused(:ambiguous) { client.read_skill_resource(uri: "skill://acme/outer/inner/notes.txt") }
      assert_equal "skill://acme/outer/inner/SKILL.md", error.skill_uri
      assert_equal outer["uri"], client.read_skill_resource(uri: "skill://acme/outer/inner/notes.txt", skill: entries[outer["uri"]]).skill.uri
      assert_equal inner["uri"], client.read_skill_resource(uri: "skill://acme/outer/inner/notes.txt", skill: entries[inner["uri"]]).skill.uri

      # A nested skill that fails verification is latched, which blocks the shared file even through the verified
      # enclosing entry named explicitly.
      tampered_inner = honest_store.merge("skill://acme/outer/inner/SKILL.md" => { "text" => inner_md.sub("Inner", "Changed") })
      client, _transport = connected_client(skills: [outer, inner_listing_notes], files: tampered_inner)
      outer_entry = client.list_skills.skills.find { |skill| skill.uri == outer["uri"] }
      assert client.read_skill_resource(uri: "skill://acme/outer/SKILL.md").verified
      assert_raises(Client::SkillVerificationError) { client.read_skill_resource(uri: "skill://acme/outer/inner/SKILL.md") }
      assert_refused(:latched) { client.read_skill_resource(uri: "skill://acme/outer/inner/notes.txt", skill: outer_entry) }
    end

    test "a refreshed catalog does not let a verified enclosing skill stand in for a nested skill that changed" do
      outer_md = "---\nname: outer\ndescription: Outer\n---\n"
      inner_md = "---\nname: inner\ndescription: Inner\n---\n"
      inner_md_v2 = inner_md.sub("Inner", "Innex")
      notes_uri = "skill://acme/outer/inner/notes.txt"
      catalog = lambda do |manifest, notes|
        description = manifest == inner_md ? "Inner" : "Innex"
        [
          {
            "uri" => "skill://acme/outer/SKILL.md",
            "frontmatter" => { "name" => "outer", "description" => "Outer" },
            "resources" => [wire_entry("skill://acme/outer/SKILL.md", outer_md), wire_entry("skill://acme/outer/inner/SKILL.md", manifest), wire_entry(notes_uri, notes)],
          },
          {
            "uri" => "skill://acme/outer/inner/SKILL.md",
            "frontmatter" => { "name" => "inner", "description" => description },
            "resources" => [wire_entry("skill://acme/outer/inner/SKILL.md", manifest), wire_entry(notes_uri, notes)],
          },
        ]
      end
      files = lambda do |manifest, notes|
        { "skill://acme/outer/SKILL.md" => { "text" => outer_md }, "skill://acme/outer/inner/SKILL.md" => { "text" => manifest }, notes_uri => { "text" => notes } }
      end
      client, transport = connected_client(skills: catalog.call(inner_md, "v1\n"), files: files.call(inner_md, "v1\n"))
      held = client.list_skills.skills.find { |skill| skill.uri == "skill://acme/outer/inner/SKILL.md" }
      assert client.read_skill_resource(uri: "skill://acme/outer/SKILL.md").verified
      assert client.read_skill_resource(uri: "skill://acme/outer/inner/SKILL.md").verified
      assert_equal "v1\n".b, client.read_skill_resource(uri: notes_uri, skill: held).bytes

      # The server changes the nested skill in both manifests at once, the host refreshes the catalog and re-reads
      # only the enclosing SKILL.md: the changed file is never served as verified through the enclosing entry, and
      # the held entry fails closed until its own SKILL.md is read again, which then fails and latches the skill.
      transport.skills = catalog.call(inner_md_v2, "v2\n")
      transport.files = files.call(inner_md_v2, "v2\n")
      client.list_skills
      assert client.read_skill_resource(uri: "skill://acme/outer/SKILL.md").verified
      assert_refused(:ambiguous) { client.read_skill_resource(uri: notes_uri) }
      assert_refused(:skill_md_unverified) { client.read_skill_resource(uri: notes_uri, skill: held) }
      assert_verification_failure(:digest) { client.read_skill_resource(uri: "skill://acme/outer/inner/SKILL.md", skill: held) }
      assert_refused(:latched) { client.read_skill_resource(uri: notes_uri, skill: held) }
    end

    test "two remembered skills listing one file are refused as ambiguous whatever their digests say" do
      outer_md = "---\nname: outer\ndescription: Outer\n---\n"
      inner_md = "---\nname: inner\ndescription: Inner\n---\n"
      notes_uri = "skill://acme/outer/inner/notes.txt"
      outer = {
        "uri" => "skill://acme/outer/SKILL.md",
        "frontmatter" => { "name" => "outer", "description" => "Outer" },
        "resources" => [wire_entry("skill://acme/outer/SKILL.md", outer_md), wire_entry(notes_uri, "notes\n")],
      }
      inner = {
        "uri" => "skill://acme/outer/inner/SKILL.md",
        "frontmatter" => { "name" => "inner", "description" => "Inner" },
        "resources" => [wire_entry("skill://acme/outer/inner/SKILL.md", inner_md), wire_entry(notes_uri, "other\n")],
      }
      store = {
        "skill://acme/outer/SKILL.md" => { "text" => outer_md },
        "skill://acme/outer/inner/SKILL.md" => { "text" => inner_md },
        notes_uri => { "text" => "notes\n" },
      }
      client, transport = connected_client(skills: [outer, inner], files: store)
      outer_entry = client.list_skills.skills.find { |skill| skill.uri == outer["uri"] }
      client.read_skill_resource(uri: outer["uri"])

      error = assert_refused(:ambiguous) { client.read_skill_resource(uri: notes_uri) }
      assert_equal notes_uri, error.uri
      assert_equal 1, transport.requests.count { |request| request[:method] == "resources/read" }
      # The host names the skill it is acting on, and the file is verified against that manifest alone.
      assert_equal "notes\n".b, client.read_skill_resource(uri: notes_uri, skill: outer_entry).bytes

      # Agreeing digests change nothing: the choice is the host's either way.
      inner_agreeing = inner.merge("resources" => [wire_entry("skill://acme/outer/inner/SKILL.md", inner_md), wire_entry(notes_uri, "notes\n")])
      client, _transport = connected_client(skills: [outer, inner_agreeing], files: store)
      client.list_skills
      client.read_skill_resource(uri: outer["uri"])
      assert_refused(:ambiguous) { client.read_skill_resource(uri: notes_uri) }
    end

    test "with three nested levels the most specific skill answers and every enclosing lister is named" do
      deep = "skill://a/b/c/deep.txt"
      entry_for = lambda do |path, name|
        manifest = "---\nname: #{name}\ndescription: #{name.upcase}\n---\n"
        {
          "uri" => "skill://#{path}/SKILL.md",
          "frontmatter" => { "name" => name, "description" => name.upcase },
          "resources" => [wire_entry("skill://#{path}/SKILL.md", manifest), wire_entry(deep, "d\n")],
        }
      end
      skills = [entry_for.call("a", "a"), entry_for.call("a/b", "b"), entry_for.call("a/b/c", "c")]
      store = skills.to_h { |skill| [skill["uri"], { "text" => "---\nname: #{skill["frontmatter"]["name"]}\ndescription: #{skill["frontmatter"]["description"]}\n---\n" }] }
      store[deep] = { "text" => "d\n" }
      client, transport = connected_client(skills: skills, files: store)
      entries = client.list_skills.skills.to_h { |skill| [skill.uri, skill] }

      error = assert_refused(:ambiguous) { client.read_skill_resource(uri: deep) }
      assert_equal "skill://a/b/c/SKILL.md", error.skill_uri
      assert_includes error.message, '"skill://a/b/SKILL.md" and "skill://a/SKILL.md"'
      assert_empty transport.requests.select { |request| request[:method] == "resources/read" }

      client.read_skill_resource(uri: "skill://a/b/c/SKILL.md")
      assert_equal "d\n".b, client.read_skill_resource(uri: deep, skill: entries["skill://a/b/c/SKILL.md"]).bytes
    end

    test "a URI longer or deeper than the client resolves is refused at once, before the ancestor roots are computed" do
      client, transport = connected_client
      client.list_skills
      deep = "skill://#{Array.new(20_000, "a").join("/")}/x"
      long = "skill://pdf-processing/#{"x" * (Skill::Uri::MAX_RESOLVED_BYTES + 1)}"

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      [deep, long].each do |uri|
        error = assert_refused(:unknown_skill) { client.read_skill_resource(uri: uri) }
        assert_operator error.message.bytesize, :<, 200, "the message leaves the URI out"
      end
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
      assert_empty transport.requests.select { |request| request[:method] == "resources/read" }

      # The advertisement check keeps its precedence, and a URI at the limits takes the ordinary path.
      idle = Client.new(transport: FakeTransport.new([pdf_entry], files))
      assert_refused(:not_advertised) { idle.read_skill_resource(uri: deep) }
      at_limit = "skill://#{Array.new(Skill::Uri::MAX_RESOLVED_SEGMENTS, "a").join("/")}"
      assert_refused(:unknown_skill) { client.read_skill_resource(uri: at_limit) }
      assert_raises(ArgumentError) { client.read_skill_resource(uri: "skill://pdf-processing/\xFF") }
      assert_raises(ArgumentError) { client.get_skill(uri: "skill://pdf-processing/\xFF/SKILL.md") }
    end

    test "a URI in an encoding that is not ASCII-compatible is refused as an argument and as an entry" do
      wide = SKILL_URI.encode("UTF-16LE")
      client, transport = connected_client(skills: [pdf_entry.merge("uri" => wide)])

      assert_raises(Client::SkillEntryError) { client.list_skills }
      assert_raises(ArgumentError) { client.read_skill_resource(uri: wide) }
      assert_raises(ArgumentError) { client.get_skill(uri: wide) }
      assert_equal ["skills/list"], transport.requests.map { |request| request[:method] }
    end

    test "server-chosen URIs appear escaped in error messages" do
      # ESC and LF, then RIGHT-TO-LEFT OVERRIDE, ZERO WIDTH SPACE, and NEL, which `inspect` would leave as they are
      # (NEL on Ruby 2.7 only).
      name = "a\e[31m\nFORGED LOG LINE#{[0x202E, 0x200B, 0x85].pack("U*")}"
      uri = "skill://#{name}/SKILL.md"
      entry = { "uri" => uri, "frontmatter" => { "name" => name, "description" => "d" }, "resources" => [wire_entry(uri, "listed")] }
      client, transport = connected_client(skills: [entry], files: { uri => { "text" => "tampered" } })
      client.list_skills
      transport.get_answer = entry

      errors = [
        assert_refused(:not_in_manifest) { client.read_skill_resource(uri: "skill://#{name}/other.md") },
        assert_refused(:unknown_skill) { client.read_skill_resource(uri: "skill://#{name}/nested/SKILL.md") },
        assert_raises(Client::SkillEntryError) { client.get_skill(uri: "skill://#{name}/nested/SKILL.md") },
        assert_raises(Client::SkillVerificationError) { client.read_skill_resource(uri: uri) },
        assert_refused(:latched) { client.read_skill_resource(uri: uri) },
      ]
      errors.each do |error|
        assert_predicate error.message, :ascii_only?, error.class.name
        refute_match(/[\n\e]/, error.message)
      end
      assert_equal uri, errors[3].uri
    end

    test "the segment boundary keeps skill://ab apart from skill://a" do
      a_md = "---\nname: a\ndescription: A\n---\n"
      a = { "uri" => "skill://a/SKILL.md", "frontmatter" => { "name" => "a", "description" => "A" }, "resources" => [wire_entry("skill://a/SKILL.md", a_md)] }
      client, _transport = connected_client(skills: [a], files: { "skill://a/SKILL.md" => { "text" => a_md } })
      client.list_skills

      assert_refused(:unknown_skill) { client.read_skill_resource(uri: "skill://ab/x") }
    end

    test "a replaced entry does not inherit verified status, and an in-flight automatic read cannot restore it" do
      client, transport = connected_client
      first = client.list_skills.skills.first
      client.read_skill_resource(uri: SKILL_URI)
      assert_equal FORMS.b, client.read_skill_resource(uri: FORMS_URI).bytes

      second = client.list_skills.skills.first
      refute_same first, second
      assert_refused(:skill_md_unverified) { client.read_skill_resource(uri: FORMS_URI) }

      # The catalog is replaced while the SKILL.md read is in flight: the read completes against the old object.
      transport.hook = ->(_request) { client.list_skills }
      result = client.read_skill_resource(uri: SKILL_URI)
      assert_same second, result.skill
      assert_refused(:skill_md_unverified) { client.read_skill_resource(uri: FORMS_URI) }

      # An explicit read verifies the exact object the caller supplied, even after replacement.
      assert client.read_skill_resource(uri: SKILL_URI, skill: second).verified
      assert_equal FORMS.b, client.read_skill_resource(uri: FORMS_URI, skill: second).bytes

      # An explicit read spanning a replacement still marks the supplied object; the new index object stays unverified.
      third = client.list_skills.skills.first
      transport.hook = ->(_request) { client.list_skills }
      assert_same third, client.read_skill_resource(uri: SKILL_URI, skill: third).skill
      assert_equal FORMS.b, client.read_skill_resource(uri: FORMS_URI, skill: third).bytes
      assert_refused(:skill_md_unverified) { client.read_skill_resource(uri: FORMS_URI) }
    end

    test "a connect during an in-flight call discards its result as connection_changed without latching" do
      client, transport = connected_client
      transport.hook = ->(_request) {
                         transport.connected = false
                         client.connect }
      assert_refused(:connection_changed) { client.list_skills }

      client.list_skills
      client.read_skill_resource(uri: SKILL_URI)
      transport.files[FORMS_URI] = { "text" => "Formz\n" }
      transport.hook = ->(_request) {
                         transport.connected = false
                         client.connect }
      assert_refused(:connection_changed) { client.read_skill_resource(uri: FORMS_URI) }
      client.list_skills
      transport.files[FORMS_URI] = { "text" => FORMS }
      assert client.read_skill_resource(uri: SKILL_URI).verified, "nothing was latched by the stale failure"

      transport.hook = ->(_request) {
                         transport.connected = false
                         client.connect }
      transport.skills = "garbage"
      assert_refused(:connection_changed) { client.list_skills }
    end

    test "overlapping handshakes: a stale completion or failure changes nothing" do
      transport = FakeTransport.new([pdf_entry], files)
      client = Client.new(transport: transport)

      first_gate = Queue.new
      transport.gate = first_gate
      blocked = Thread.new { client.connect }
      blocked.report_on_exception = false
      sleep(0.01) until blocked.status == "sleep"
      transport.gate = nil
      client.connect
      assert_equal 1, client.list_skills.skills.size

      first_gate << RuntimeError.new("handshake A failed late")
      error = assert_raises(RuntimeError) { blocked.value }
      assert_equal "handshake A failed late", error.message
      assert_equal 1, client.list_skills.skills.size, "the failure of the older attempt did not clear readiness"

      transport.connected = false
      second_gate = Queue.new
      transport.gate = second_gate
      blocked = Thread.new { client.connect }
      blocked.report_on_exception = false
      sleep(0.01) until blocked.status == "sleep"
      transport.gate = nil
      client.connect
      transport.capabilities = { "resources" => {} }
      second_gate << :go
      blocked.join(5)
      assert_equal 1, client.list_skills.skills.size, "the older completion did not replace the recorded capabilities"
    end

    test "readiness comes from the handshake result on the modern lifecycle too" do
      transport = Class.new do
        attr_reader :connected

        def initialize
          @connected = false
        end

        def connect(client_info: nil, protocol_version: nil, capabilities: {}, mode: :legacy)
          @connected = true
          { "supportedVersions" => ["2026-07-28"], "capabilities" => { "resources" => {}, "extensions" => { MCP::Skill::EXTENSION_ID => {} } } }
        end

        def connected?
          @connected
        end

        def send_request(request:)
          { "result" => { "skills" => [] } }
        end
      end.new
      client = Client.new(transport: transport)
      client.connect(mode: :modern)

      assert_equal({}, client.skills_capability)
      assert_equal [], client.list_skills.skills
    end

    test "a failed handshake leaves the client refusing skills calls" do
      transport = FakeTransport.new([pdf_entry], files)
      client = Client.new(transport: transport)
      transport.gate = Queue.new
      transport.gate << RuntimeError.new("boom")
      assert_raises(RuntimeError) { client.connect }

      assert_refused(:not_advertised) { client.list_skills }
      assert_nil client.skills_capability
    end

    test "a malformed read response is a contents failure that latches, whatever its shape" do
      [{ "result" => false }, { "result" => [] }, { "result" => { "contents" => "text" } }, { "result" => { "contents" => nil } }].each do |response|
        client, transport = connected_client
        client.list_skills
        transport.define_singleton_method(:send_request) do |request:|
          request[:method] == "resources/read" ? response : super(request: request)
        end

        assert_verification_failure(:contents) { client.read_skill_resource(uri: SKILL_URI) }
        assert_refused(:latched) { client.read_skill_resource(uri: SKILL_URI) }
      end
    end

    test "list_skills and get_skill refuse a response that is not a Hash or whose result is not a Hash" do
      [nil, "nope", { "result" => "nope" }].each do |response|
        client, transport = connected_client
        transport.define_singleton_method(:send_request) { |request:| response }

        assert_raises(Client::SkillEntryError, response.inspect) { client.list_skills }
        assert_raises(Client::SkillEntryError, response.inspect) { client.get_skill(uri: SKILL_URI) }
      end
    end

    test "values nested deeper than JSON.parse reads by default are refused rather than exhausting the stack" do
      # Only a transport that parses without a nesting limit can deliver these.
      deep = 100_000.times.inject("leaf") { |value, _| [value] }

      entry = pdf_entry.merge("frontmatter" => { "name" => "pdf-processing", "description" => "Extract PDFs", "metadata" => deep })
      client, _transport = connected_client(skills: [entry])
      error = assert_raises(Client::SkillEntryError) { client.list_skills }
      assert_includes error.message, "must not nest deeper than 100 levels"
      assert_raises(Client::SkillEntryError) { client.get_skill(uri: SKILL_URI) }

      client, _transport = connected_client(files: files.merge(SKILL_URI => { "text" => SKILL_MD.dup, "_meta" => { "deep" => deep } }))
      client.list_skills
      assert_verification_failure(:contents) { client.read_skill_resource(uri: SKILL_URI) }
      assert_refused(:latched) { client.read_skill_resource(uri: SKILL_URI) }

      # The handshake itself succeeds, as it does for a client that never uses Skills.
      transport = FakeTransport.new([pdf_entry], files)
      transport.capabilities = transport.capabilities.merge("experimental" => { "deep" => deep })
      client = Client.new(transport: transport)
      assert_equal "fake", client.connect.dig("serverInfo", "name")
      assert_nil client.skills_capability
      assert_refused(:not_advertised) { client.list_skills }
    end

    test "an explicit skill cannot claim a URI outside its root, and a URI that is not structurally valid is unknown" do
      client, transport = connected_client(skills: [])
      explicit = Skill.from_entry(pdf_entry)

      assert_refused(:not_in_manifest) { client.read_skill_resource(uri: "skill://other/file.md", skill: explicit) }
      assert_refused(:unknown_skill) { client.read_skill_resource(uri: "skill://pdf-processing/../x") }
      assert_refused(:unknown_skill) { client.read_skill_resource(uri: "skill://pdf-processing/references/FORMS.md/") }
      assert_empty transport.requests.select { |request| request[:method] == "resources/read" }
    end

    test "the result's uri is an independent frozen copy of the argument" do
      client, _transport = connected_client
      client.list_skills
      argument = SKILL_URI.dup
      result = client.read_skill_resource(uri: argument)
      argument << "/tampered"

      assert_equal SKILL_URI, result.uri
      assert_predicate result.uri, :frozen?
    end

    test "a stale get_skill completion is refused as connection_changed" do
      client, transport = connected_client
      transport.hook = ->(_request) {
                         transport.connected = false
                         client.connect }

      assert_refused(:connection_changed) { client.get_skill(uri: SKILL_URI) }
    end

    test "a read completing after another read latched the skill is discarded" do
      client, transport = connected_client
      client.list_skills
      client.read_skill_resource(uri: SKILL_URI)
      transport.files[LOGO_URI] = { "blob" => "AAAA" }
      transport.hook = ->(_request) { assert_verification_failure(:size) { client.read_skill_resource(uri: LOGO_URI) } }

      assert_refused(:latched) { client.read_skill_resource(uri: FORMS_URI) }
    end

    test "concurrent reads and reconnects neither deadlock nor raise anything but Skills errors" do
      client, transport = connected_client
      client.list_skills
      client.read_skill_resource(uri: SKILL_URI)
      unexpected = Queue.new
      readers = Array.new(4) do
        Thread.new do
          50.times do
            client.read_skill_resource(uri: FORMS_URI)
          rescue Client::SkillError
            nil
          rescue StandardError => e
            unexpected << e
          end
        end
      end
      reconnector = Thread.new do
        5.times do
          transport.connected = false
          client.connect
          client.list_skills
          client.read_skill_resource(uri: SKILL_URI)
        rescue Client::SkillError
          nil
        rescue StandardError => e
          unexpected << e
        end
      end

      (readers + [reconnector]).each { |thread| assert thread.join(10), "a thread did not finish" }
      assert_equal 0, unexpected.size, unexpected.size.times.map { unexpected.pop.inspect }.join("; ")
    end

    test "list_skills and get_skill carry the cursor, the cache hints, and _meta of the result" do
      client, transport = connected_client
      transport.define_singleton_method(:send_request) do |request:|
        case request[:method]
        when "skills/list"
          { "result" => { "skills" => @skills, "nextCursor" => "page-2", "ttlMs" => 5000, "cacheScope" => "private", "_meta" => { "a" => 1 } } }
        when "skills/get"
          { "result" => { "skill" => @skills.first, "ttlMs" => 60_000, "cacheScope" => "public" } }
        end
      end

      page = client.list_skills
      assert_equal "page-2", page.next_cursor
      assert_equal 5000, page.ttl_ms
      assert_equal "private", page.cache_scope
      assert_equal({ "a" => 1 }, page.meta)

      got = client.get_skill(uri: SKILL_URI)
      assert_equal SKILL_URI, got.skill.uri
      assert_equal 60_000, got.ttl_ms
      assert_equal "public", got.cache_scope
      assert_nil got.meta
    end

    test "list_skills and get_skill expose the _meta of an entry as a frozen Hash and refuse an entry whose _meta is not an object" do
      annotated = pdf_entry.merge("_meta" => { "com.example/origin" => "catalog" })
      client, transport = connected_client(skills: [annotated])

      page = client.list_skills
      assert_equal({ "com.example/origin" => "catalog" }, page.skills.first.meta)
      assert_predicate page.skills.first.meta, :frozen?
      assert_nil page.meta
      got = client.get_skill(uri: SKILL_URI)
      assert_equal({ "com.example/origin" => "catalog" }, got.skill.meta)
      assert_nil got.meta
      assert_nil connected_client.first.list_skills.skills.first.meta

      transport.skills = [pdf_entry.merge("_meta" => "origin=catalog")]
      error = assert_raises(Client::SkillEntryError) { client.list_skills }
      assert_equal "Skill entry rejected: The value of meta must be a Hash (got String).", error.message
      assert_raises(Client::SkillEntryError) { client.get_skill(uri: SKILL_URI) }
      assert_equal({ "com.example/origin" => "catalog" }, client.read_skill_resource(uri: SKILL_URI).skill.meta)
    end

    test "skills calls are refused while a reconnect handshake is in flight, even on a connected transport" do
      client, transport = connected_client
      client.list_skills
      transport.connected = false
      gate = Queue.new
      transport.gate = gate
      blocked = Thread.new { client.connect }
      blocked.report_on_exception = false
      begin
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        until blocked.status == "sleep"
          flunk("the handshake did not block") if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          sleep(0.01)
        end
        # The transport already reports connected, so only the missing readiness can refuse the calls.
        transport.connected = true

        assert_refused(:not_advertised) { client.list_skills }
        assert_refused(:not_advertised) { client.read_skill_resource(uri: SKILL_URI) }
        assert_nil client.skills_capability
      ensure
        gate << :go
        blocked.join(5)
      end
      assert_equal 1, client.list_skills.skills.size
    end

    test "verify helpers serve a raw read path" do
      client, _transport = connected_client
      skill = client.list_skills.skills.first
      contents = client.read_resource(uri: FORMS_URI)

      assert Skill.verify_resource(skill, FORMS_URI, contents.first["text"].b)
      assert Skill.verify_frontmatter(skill, client.read_resource(uri: SKILL_URI).first["text"])
    end
  end
end
