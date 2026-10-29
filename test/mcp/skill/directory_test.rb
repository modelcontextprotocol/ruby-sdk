# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module MCP
  class Skill
    class DirectoryTest < ActiveSupport::TestCase
      SKILL_MD = "---\nname: pdf-processing\ndescription: Extract PDFs\n---\n\nBody.\n"

      def with_root
        Dir.mktmpdir("skills") do |root|
          yield root
        end
      end

      def write(root, relative, content)
        path = File.join(root, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, content)
        path
      end

      def pdf_root(root)
        write(root, "pdf-processing/SKILL.md", SKILL_MD)
        write(root, "pdf-processing/references/FORMS.md", "Forms\n")
        write(root, "pdf-processing/logo.png", "\x89PNG\r\n\x1a\n\xFF".b)
        root
      end

      def read_request(uri)
        { jsonrpc: "2.0", id: 1, method: "resources/read", params: { uri: uri } }
      end

      test "turns every directory holding a SKILL.md into a skill with digests and sizes of its files" do
        with_root do |root|
          pdf_root(root)
          skills = Skill.from_directory(root)

          assert_equal ["skill://pdf-processing/SKILL.md"], skills.map(&:uri)
          skill = skills.first
          assert_equal({ "name" => "pdf-processing", "description" => "Extract PDFs" }, skill.frontmatter)
          assert_equal(
            ["skill://pdf-processing/SKILL.md", "skill://pdf-processing/logo.png", "skill://pdf-processing/references/FORMS.md"],
            skill.resources.map(&:uri),
          )
          entry = skill.resources.find { |candidate| candidate.uri == "skill://pdf-processing/SKILL.md" }
          assert_equal SKILL_MD.bytesize, entry.size
          assert_equal "sha256:#{Digest::SHA256.hexdigest(SKILL_MD)}", entry.digest
          assert_predicate skill, :frozen?
        end
      end

      test "accepts a Pathname and a symbolic link to the root, and orders skills by URI" do
        with_root do |root|
          pdf_root(root)
          write(root, "acme/outer/SKILL.md", "---\nname: outer\ndescription: Outer\n---\n")
          link = File.join(root, "link")
          File.symlink(root, link)

          assert_equal ["skill://acme/outer/SKILL.md", "skill://pdf-processing/SKILL.md"], Skill.from_directory(Pathname.new(link)).map(&:uri)
        end
      end

      test "a nested skill is published on its own and its files are supporting files of the enclosing skill" do
        with_root do |root|
          write(root, "acme/outer/SKILL.md", "---\nname: outer\ndescription: Outer\n---\n")
          write(root, "acme/outer/guide.md", "g\n")
          write(root, "acme/outer/inner/SKILL.md", "---\nname: inner\ndescription: Inner\n---\n")
          write(root, "acme/outer/inner/notes.txt", "n\n")
          skills = Skill.from_directory(root)
          by_uri = skills.to_h { |skill| [skill.uri, skill] }

          outer = by_uri.fetch("skill://acme/outer/SKILL.md")
          inner = by_uri.fetch("skill://acme/outer/inner/SKILL.md")
          assert_equal(
            ["skill://acme/outer/SKILL.md", "skill://acme/outer/guide.md", "skill://acme/outer/inner/SKILL.md", "skill://acme/outer/inner/notes.txt"],
            outer.resources.map(&:uri),
          )
          assert_equal ["skill://acme/outer/inner/SKILL.md", "skill://acme/outer/inner/notes.txt"], inner.resources.map(&:uri)
          shared = ->(skill) { skill.resources.find { |entry| entry.uri == "skill://acme/outer/inner/notes.txt" } }
          assert_equal shared.call(inner), shared.call(outer), "both manifests carry the same digest and size"
          # The nested files count toward the enclosing skill's total as well.
          assert_equal inner.total_size + "---\nname: outer\ndescription: Outer\n---\n".bytesize + "g\n".bytesize, outer.total_size

          # The shared file is served once; a URI under a skill root that names no file is -32602, and
          # a URI outside every skill root keeps the base reader's answer.
          server = Server.new(name: "catalog", skills: skills)
          assert_equal "n\n", server.handle(read_request("skill://acme/outer/inner/notes.txt")).dig(:result, :contents, 0, :text)
          response = server.handle(read_request("skill://acme/outer/missing.md"))
          assert_equal(-32602, response[:error][:code])
          assert_equal "Skill file not found: skill://acme/outer/missing.md", response[:error][:message]
          assert_equal [], server.handle(read_request("skill://elsewhere/x"))[:result][:contents]

          listed = server.handle({ jsonrpc: "2.0", id: 1, method: "resources/list" })[:result][:resources]
          assert_equal ["inner", "outer"], listed.map { |resource| resource[:name] }.sort
        end
      end

      test "a hard link is refused at construction, and one added to a served file is refused at read time" do
        with_root do |root|
          pdf_root(root)
          outside = File.join(root, "secret.txt")
          File.binwrite(outside, "TOP SECRET\n")
          linked = File.join(root, "pdf-processing", "linked.txt")
          File.link(outside, linked)
          error = assert_raises(ArgumentError) { Skill.from_directory(root) }
          assert_equal "#{File.realpath(root)}/pdf-processing/linked.txt has more than one hard link", error.message

          File.delete(linked)
          server = Server.new(name: "catalog", skills: Skill.from_directory(root))
          File.link(File.join(root, "pdf-processing", "references", "FORMS.md"), File.join(root, "FORMS-copy.md"))
          assert_equal(-32603, server.handle(read_request("skill://pdf-processing/references/FORMS.md"))[:error][:code])
        end
      end

      test "a path that no longer names the opened file is refused at construction" do
        with_root do |root|
          pdf_root(root)
          other = File.stat(__FILE__)
          begin
            # What `stat` reports for the path differs from the opened handle, as after an intermediate directory swap.
            File.stubs(:stat).returns(other)
            error = assert_raises(ArgumentError) { Skill.from_directory(root) }
          ensure
            File.unstub(:stat)
          end
          assert_equal "#{File.realpath(root)}/pdf-processing/SKILL.md is not the file its path names", error.message
        end
      end

      test "three levels of nesting list every descendant in every enclosing manifest once" do
        with_root do |root|
          write(root, "a/SKILL.md", "---\nname: a\ndescription: A\n---\n")
          write(root, "a/b/SKILL.md", "---\nname: b\ndescription: B\n---\n")
          write(root, "a/b/c/SKILL.md", "---\nname: c\ndescription: C\n---\n")
          write(root, "a/b/c/deep.txt", "d\n")
          by_uri = Skill.from_directory(root).to_h { |skill| [skill.uri, skill.resources.map(&:uri)] }

          assert_equal ["skill://a/SKILL.md", "skill://a/b/SKILL.md", "skill://a/b/c/SKILL.md", "skill://a/b/c/deep.txt"], by_uri.fetch("skill://a/SKILL.md")
          assert_equal ["skill://a/b/SKILL.md", "skill://a/b/c/SKILL.md", "skill://a/b/c/deep.txt"], by_uri.fetch("skill://a/b/SKILL.md")
          assert_equal ["skill://a/b/c/SKILL.md", "skill://a/b/c/deep.txt"], by_uri.fetch("skill://a/b/c/SKILL.md")
        end
      end

      test "records from separate scans are accepted when equal and refused when they come from different files" do
        with_root do |root|
          write(root, "acme/outer/SKILL.md", "---\nname: outer\ndescription: Outer\n---\n")
          write(root, "acme/outer/inner/SKILL.md", "---\nname: inner\ndescription: Inner\n---\n")
          write(root, "acme/outer/inner/notes.txt", "n\n")
          outer = Skill.from_directory(root).find { |skill| skill.name == "outer" }
          inner_again = Skill.from_directory(root).find { |skill| skill.name == "inner" }
          assert_equal 2, Server.new(name: "catalog", skills: [outer, inner_again]).skills.size

          with_root do |other|
            write(other, "acme/outer/inner/SKILL.md", "---\nname: inner\ndescription: Inner\n---\n")
            write(other, "acme/outer/inner/notes.txt", "n\n")
            foreign_inner = Skill.from_directory(other).first
            error = assert_raises(ArgumentError) { Server.new(name: "catalog", skills: [outer, foreign_inner]) }
            assert_equal "The skill file skill://acme/outer/inner/SKILL.md is served by more than one skill from different files.", error.message
          end
        end
      end

      test "the -32602 answer covers the skill subtree only and comes after registered resources" do
        with_root do |root|
          pdf_root(root)
          skills = Skill.from_directory(root)
          plain = Server.new(name: "catalog", skills: skills)
          assert_equal [], plain.handle(read_request("skill://pdf-processing-extra/x"))[:result][:contents], "a sibling prefix is outside the root"

          server = Server.new(name: "catalog", skills: skills)
          server.define_resource(uri: "skill://pdf-processing/extra", name: "extra", mime_type: "text/plain") { { uri: "skill://pdf-processing/extra", text: "extra" } }
          server.define_resource_template(uri_template: "skill://pdf-processing/templates/{id}", name: "shadowed") { |id:| "template #{id}" }
          assert_equal "extra", server.handle(read_request("skill://pdf-processing/extra")).dig(:result, :contents, 0, :text)
          assert_equal(-32602, server.handle(read_request("skill://pdf-processing/templates/1"))[:error][:code], "templates are shadowed under the skill root")
        end
      end

      test "skips dotfiles, symbolic links, and FIFOs, publishes editor backups, and ignores files outside skill directories" do
        with_root do |root|
          pdf_root(root)
          write(root, "pdf-processing/.env", "SECRET=1")
          write(root, "pdf-processing/SKILL.md~", "backup")
          write(root, "README.md", "not a skill")
          File.symlink(File.join(root, "README.md"), File.join(root, "pdf-processing", "linked.md"))
          File.mkfifo(File.join(root, "pdf-processing", "pipe")) if File.respond_to?(:mkfifo)
          uris = Skill.from_directory(root).first.resources.map(&:uri)

          assert_includes uris, "skill://pdf-processing/SKILL.md~"
          refute_includes uris, "skill://pdf-processing/.env"
          refute_includes uris, "skill://pdf-processing/linked.md"
          refute_includes uris, "skill://pdf-processing/pipe"
          refute_includes uris, "skill://README.md"
        end
      end

      test "refuses a root that is missing, not a directory, holds a SKILL.md itself, or holds no skill" do
        with_root do |root|
          error = assert_raises(ArgumentError) { Skill.from_directory(File.join(root, "missing")) }
          assert_match(/cannot be resolved/, error.message)

          file = write(root, "file.txt", "x")
          error = assert_raises(ArgumentError) { Skill.from_directory(file) }
          assert_match(/is not a directory/, error.message)

          error = assert_raises(ArgumentError) { Skill.from_directory(root) }
          assert_match(/No directory holding a SKILL.md/, error.message)

          write(root, "SKILL.md", SKILL_MD)
          error = assert_raises(ArgumentError) { Skill.from_directory(root) }
          assert_match(/holds a SKILL.md itself/, error.message)

          assert_raises(ArgumentError) { Skill.from_directory(42) }
        end
      end

      test "refuses directory and file names outside the unreserved URI characters, naming the path" do
        with_root do |root|
          pdf_root(root)
          write(root, "pdf-processing/My Forms.md", "x")
          error = assert_raises(ArgumentError) { Skill.from_directory(root) }
          assert_includes error.message, File.join(root, "pdf-processing", "My Forms.md")
          assert_match(/may only use letters, digits/, error.message)
        end

        with_root do |root|
          write(root, "pdf tools/SKILL.md", "---\nname: pdf tools\ndescription: d\n---\n")
          error = assert_raises(ArgumentError) { Skill.from_directory(root) }
          assert_includes error.message, File.join(root, "pdf tools")
        end
      end

      test "refuses a frontmatter the shared rules cannot read, a name that differs from the directory, and over-limit skills" do
        with_root do |root|
          write(root, "pdf-processing/SKILL.md", "---\nname: pdf-processing\ndescription: d\nflag: yes\n---\n")
          error = assert_raises(ArgumentError) { Skill.from_directory(root) }
          assert_match(/frontmatter of .*SKILL.md cannot be read \(parse\)/, error.message)
        end

        with_root do |root|
          write(root, "pdf-processing/SKILL.md", "---\nname: other\ndescription: d\n---\n")
          error = assert_raises(ArgumentError) { Skill.from_directory(root) }
          assert_includes error.message, File.join(root, "pdf-processing")
          assert_match(/must equal the last segment/, error.message)
        end

        with_root do |root|
          write(root, "pdf-processing/SKILL.md", SKILL_MD)
          512.times { |index| write(root, "pdf-processing/f#{index}", "x") }
          error = assert_raises(ArgumentError) { Skill.from_directory(root) }
          assert_match(/at most 512 entries/, error.message)
        end
      end

      test "accepts a BOM-prefixed SKILL.md and registers its digest over the raw bytes" do
        with_root do |root|
          content = "\xEF\xBB\xBF#{SKILL_MD}".b
          write(root, "pdf-processing/SKILL.md", content)
          skill = Skill.from_directory(root).first

          assert_equal "pdf-processing", skill.name
          assert_equal "sha256:#{Digest::SHA256.hexdigest(content)}", skill.resources.first.digest
        end
      end

      test "the server serves text files as text and other files as base64 blobs, by exact URI only" do
        with_root do |root|
          pdf_root(root)
          server = Server.new(name: "catalog", skills: Skill.from_directory(root))

          assert_equal(
            { contents: [{ uri: "skill://pdf-processing/references/FORMS.md", mimeType: "text/markdown", text: "Forms\n" }] },
            server.handle(read_request("skill://pdf-processing/references/FORMS.md"))[:result],
          )
          assert_equal(
            { contents: [{ uri: "skill://pdf-processing/logo.png", blob: ["\x89PNG\r\n\x1a\n\xFF".b].pack("m0") }] },
            server.handle(read_request("skill://pdf-processing/logo.png"))[:result],
          )
          # URIs under the skill root that name no registered file are refused without touching the filesystem.
          ["skill://pdf-processing/.env", "skill://pdf-processing/../pdf-processing/SKILL.md", "skill://pdf-processing/references/FORMS.md/"].each do |uri|
            response = server.handle(read_request(uri))
            assert_equal(-32602, response[:error][:code], uri)
            assert_equal "Skill file not found: #{uri}", response[:error][:message]
          end
        end
      end

      test "a file that changed since registration is refused with one generic error and the detail goes to the reporter" do
        with_root do |root|
          pdf_root(root)
          reported = []
          configuration = Configuration.new(exception_reporter: ->(exception, _context) { reported << exception })
          server = Server.new(name: "catalog", skills: Skill.from_directory(root), configuration: configuration)
          forms = File.join(root, "pdf-processing", "references", "FORMS.md")

          File.binwrite(forms, "Formz\n")
          response = server.handle(read_request("skill://pdf-processing/references/FORMS.md"))
          assert_equal(-32603, response[:error][:code])
          assert_equal "Skill file changed since registration", response[:error][:message]
          assert_equal 1, reported.size
          assert_includes reported.first.message, forms
          assert_match(/content/, reported.first.message)

          File.binwrite(forms, "Forms\n\n")
          assert_equal(-32603, server.handle(read_request("skill://pdf-processing/references/FORMS.md"))[:error][:code])

          File.delete(forms)
          assert_equal(-32603, server.handle(read_request("skill://pdf-processing/references/FORMS.md"))[:error][:code])

          File.symlink(File.join(root, "pdf-processing", "SKILL.md"), forms)
          assert_equal(-32603, server.handle(read_request("skill://pdf-processing/references/FORMS.md"))[:error][:code])

          if File.respond_to?(:mkfifo)
            File.delete(forms)
            File.mkfifo(forms)
            assert_equal(-32603, server.handle(read_request("skill://pdf-processing/references/FORMS.md"))[:error][:code])
          end
          refute_includes response[:error].to_s, root
        end
      end

      test "a registered file replaced by a new inode holding the same bytes is refused" do
        with_root do |root|
          pdf_root(root)
          server = Server.new(name: "catalog", skills: Skill.from_directory(root))
          forms = File.join(root, "pdf-processing", "references", "FORMS.md")
          # The original inode stays alive under another name, so the new file cannot reuse its number.
          File.rename(forms, "#{forms}.old")
          File.binwrite(forms, "Forms\n")

          assert_equal(-32603, server.handle(read_request("skill://pdf-processing/references/FORMS.md"))[:error][:code])
        end
      end

      test "an intermediate directory swapped for one holding a same-named file with the same bytes is refused" do
        with_root do |root|
          pdf_root(root)
          server = Server.new(name: "catalog", skills: Skill.from_directory(root))
          references = File.join(root, "pdf-processing", "references")
          File.rename(references, "#{references}.old")
          FileUtils.mkdir_p(references)
          File.binwrite(File.join(references, "FORMS.md"), "Forms\n")

          assert_equal(-32603, server.handle(read_request("skill://pdf-processing/references/FORMS.md"))[:error][:code])
        end
      end

      test "a file that would take the skill over the size limit is refused before it is read" do
        with_root do |root|
          pdf_root(root)
          # Sorts before every other file of the skill, so the refusal happens before any file is read.
          huge = File.join(root, "pdf-processing", "0huge.bin")
          File.open(huge, "wb") { |io| io.truncate(Skill::MAX_TOTAL_SIZE + 1) }
          File.any_instance.expects(:read).never

          error = assert_raises(ArgumentError) { Skill.from_directory(root) }
          assert_includes error.message, huge
          assert_match(/past the 16777216 byte limit/, error.message)
        end
      end

      test "a file that grows past the size budget after its size was checked is refused by the bounded read" do
        with_root do |root|
          pdf_root(root)
          grown = File.join(root, "pdf-processing", "0grown.bin")
          File.binwrite(grown, "")
          # `fstat` saw an empty file; the read, bounded to one byte past the whole budget, then returns that much.
          File.any_instance.expects(:read).with(Skill::MAX_TOTAL_SIZE + 1).returns(("\0" * (Skill::MAX_TOTAL_SIZE + 1)).b)

          error = assert_raises(ArgumentError) { Skill.from_directory(root) }
          assert_includes error.message, grown
          assert_match(/past the 16777216 byte limit/, error.message)
        end
      end

      test "a SKILL.md that vanishes between the directory check and the scan is refused with an ArgumentError" do
        with_root do |root|
          pdf_root(root)
          # The scan runs on the resolved root, so the stub must match the path the scan passes.
          pdf = File.join(File.realpath(root), "pdf-processing")
          File.delete(File.join(pdf, "SKILL.md"))
          Skill.stubs(:skill_directory?).returns(false)
          Skill.stubs(:skill_directory?).with(pdf).returns(true)

          error = assert_raises(ArgumentError) { Skill.from_directory(root) }
          assert_equal "The SKILL.md of #{pdf} disappeared while the directory was being scanned.", error.message
        end
      end

      test "resources are ordered by URI, not by the directory walk" do
        with_root do |root|
          pdf_root(root)
          write(root, "pdf-processing/a/b.md", "b\n")
          write(root, "pdf-processing/a.md", "a\n")

          uris = Skill.from_directory(root).first.resources.map(&:uri)
          assert_equal uris.sort, uris
          assert_operator uris.index("skill://pdf-processing/a.md"), :<, uris.index("skill://pdf-processing/a/b.md")
        end
      end

      test "a directory that cannot be listed or an entry that cannot be examined is an ArgumentError naming it" do
        with_root do |root|
          pdf_root(root)
          begin
            Dir.stubs(:children).raises(Errno::EACCES)
            error = assert_raises(ArgumentError) { Skill.from_directory(root) }
          ensure
            Dir.unstub(:children)
          end
          assert_equal "The directory #{File.realpath(root)} cannot be listed (Errno::EACCES).", error.message
        end
        with_root do |root|
          pdf_root(root)
          begin
            File.stubs(:lstat).raises(Errno::EIO)
            error = assert_raises(ArgumentError) { Skill.from_directory(root) }
          ensure
            File.unstub(:lstat)
          end
          assert_equal "The entry #{File.join(File.realpath(root), "pdf-processing")} cannot be examined (Errno::EIO).", error.message
        end
      end

      test "without NOFOLLOW a symbolic link in place of a registered file is still refused" do
        with_root do |root|
          pdf_root(root)
          server = Server.new(name: "catalog", skills: Skill.from_directory(root))
          forms = File.join(root, "pdf-processing", "references", "FORMS.md")
          File.delete(forms)
          File.symlink(File.join(root, "pdf-processing", "SKILL.md"), forms)

          Skill.stubs(:nofollow_supported?).returns(false)
          assert_equal(-32603, server.handle(read_request("skill://pdf-processing/references/FORMS.md"))[:error][:code])
        end
      end

      test "read_file lets a custom resources_read_handler serve skill files with the same checks" do
        with_root do |root|
          pdf_root(root)
          skills = Skill.from_directory(root)
          server = Server.new(name: "catalog", skills: skills)
          server.resources_read_handler do |params|
            Skill.read_file(server.skills, params[:uri]) || [{ uri: params[:uri], text: "custom" }]
          end

          assert_equal "Forms\n", server.handle(read_request("skill://pdf-processing/references/FORMS.md")).dig(:result, :contents, 0, :text)
          assert_equal "custom", server.handle(read_request("other://thing")).dig(:result, :contents, 0, :text)
          assert_nil Skill.read_file(skills, "skill://pdf-processing/nope")
          # The item's uri is the record's own String, so a handler must not be able to change it for later reads.
          assert_predicate Skill.read_file(skills, "skill://pdf-processing/references/FORMS.md").first[:uri], :frozen?

          File.binwrite(File.join(root, "pdf-processing", "references", "FORMS.md"), "Formz\n")
          response = server.handle(read_request("skill://pdf-processing/references/FORMS.md"))
          assert_equal(-32603, response[:error][:code])
          assert_equal "Skill file changed since registration", response[:error][:message]
        end
      end

      test "directory-backed skills keep serving when the Array is combined or filtered" do
        with_root do |root|
          pdf_root(root)
          write(root, "acme/outer/SKILL.md", "---\nname: outer\ndescription: Outer\n---\n")
          all = Skill.from_directory(root)
          only_pdf = all.select { |skill| skill.name == "pdf-processing" }
          server = Server.new(name: "catalog", skills: only_pdf + [])

          assert_equal "Forms\n", server.handle(read_request("skill://pdf-processing/references/FORMS.md")).dig(:result, :contents, 0, :text)
          assert_equal({ contents: [] }, server.handle(read_request("skill://acme/outer/SKILL.md"))[:result])
        end
      end
    end
  end
end
