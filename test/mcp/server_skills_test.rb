# frozen_string_literal: true

require "test_helper"

module MCP
  class ServerSkillsTest < ActiveSupport::TestCase
    include InstrumentationTestHelper

    SKILL_MD = "# Refunds"
    EMAIL_MD = "Dear customer"
    EU_MD = "EU invoice"

    setup do
      @skill = Skill.new(
        uri: Skills.uri_for("acme/billing/refunds"),
        frontmatter: { "name" => "refunds", "description" => "Process customer refund requests" },
        resources: [
          entry(Skills.uri_for("acme/billing/refunds"), SKILL_MD),
          entry("skill://acme/billing/refunds/examples/email.md", EMAIL_MD),
          entry("skill://acme/billing/refunds/templates/regional/eu-invoice.md", EU_MD),
        ],
      )
      @server = build_server(skills: [@skill])
    end

    test "skills/list serves the complete entry, manifest and all" do
      response = @server.handle({ jsonrpc: "2.0", method: "skills/list", id: 1 })

      assert_equal({ skills: [@skill.to_h] }, response[:result])
    end

    test "skills/list paginates entries atomically" do
      other = Skill.new(
        uri: Skills.uri_for("git-workflow"),
        frontmatter: { "name" => "git-workflow", "description" => "Branching conventions" },
        resources: [entry(Skills.uri_for("git-workflow"), SKILL_MD)],
      )
      server = build_server(skills: [@skill, other], page_size: 1)

      first = server.handle({ jsonrpc: "2.0", method: "skills/list", id: 1 })[:result]
      assert_equal [@skill.to_h], first[:skills]
      assert_equal "1", first[:nextCursor]

      second = server.handle({ jsonrpc: "2.0", method: "skills/list", id: 2, params: { cursor: first[:nextCursor] } })[:result]
      assert_equal [other.to_h], second[:skills]
      assert_nil second[:nextCursor]
    end

    test "a server serving no skills answers skills/list with an empty listing" do
      server = build_server(skills: [])

      assert_equal({ skills: [] }, server.handle({ jsonrpc: "2.0", method: "skills/list", id: 1 })[:result])
    end

    test "#skills_list_handler replaces the served catalog and may return a partial listing" do
      @server.skills_list_handler { |_params| [] }

      assert_equal({ skills: [] }, @server.handle({ jsonrpc: "2.0", method: "skills/list", id: 1 })[:result])
    end

    test "#skills_list_handler receives server_context when it opts in" do
      seen = nil
      @server.skills_list_handler do |_params, server_context:|
        seen = server_context
        []
      end

      @server.handle({ jsonrpc: "2.0", method: "skills/list", id: 1 })

      refute_nil seen
    end

    test "skills/get returns the same entry shape as the listing" do
      response = @server.handle({ jsonrpc: "2.0", method: "skills/get", id: 1, params: { uri: @skill.uri } })

      assert_equal({ skill: @skill.to_h }, response[:result])
    end

    test "skills/get answers an unknown URI with -32602 and the URI in the error data" do
      response = @server.handle({ jsonrpc: "2.0", method: "skills/get", id: 1, params: { uri: "skill://nope/SKILL.md" } })

      assert_equal(-32602, response[:error][:code])
      assert_equal({ uri: "skill://nope/SKILL.md" }, response[:error][:data])
    end

    test "skills/get records the requested skill in the instrumentation data" do
      configuration = MCP::Configuration.new
      configuration.instrumentation_callback = instrumentation_helper.callback
      server = build_server(skills: [@skill], configuration: configuration)

      server.handle({ jsonrpc: "2.0", method: "skills/get", id: 1, params: { uri: @skill.uri } })

      assert_instrumentation_data({ method: "skills/get", skill_uri: @skill.uri })
    end

    test "skills/get rejects a request without a uri" do
      response = @server.handle({ jsonrpc: "2.0", method: "skills/get", id: 1, params: {} })

      assert_equal(-32602, response[:error][:code])
    end

    test "#skills_get_handler answers for a skill the listing omits" do
      unlisted = Skill.new(
        uri: Skills.uri_for("generated"),
        frontmatter: { "name" => "generated", "description" => "Built per request" },
        resources: Skill::DYNAMIC,
      )
      server = build_server(skills: [])
      server.skills_list_handler { |_params| [] }
      server.skills_get_handler { |params| unlisted if params[:uri] == unlisted.uri }

      response = server.handle({ jsonrpc: "2.0", method: "skills/get", id: 1, params: { uri: unlisted.uri } })

      assert_equal({ skill: unlisted.to_h }, response[:result])
      assert_equal "dynamic", response[:result][:skill][:resources]
    end

    test "skills/list and skills/get require the extension declaration" do
      server = MCP::Server.new(name: "test", capabilities: { resources: {} }, skills: [@skill])

      ["skills/list", "skills/get"].each do |method|
        response = server.handle({ jsonrpc: "2.0", method: method, id: 1, params: { uri: @skill.uri } })

        assert_match(/extensions.io.modelcontextprotocol\/skills/, response[:error][:data])
      end
    end

    test "declaring the extension without the resources capability is refused at construction" do
      error = assert_raises(ArgumentError) do
        MCP::Server.new(name: "test", capabilities: { tools: {}, extensions: Skills.capability })
      end

      assert_match(/requires the `resources` capability/, error.message)
    end

    test "resources/directory/read lists a directory's direct children, subdirectories included" do
      response = @server.handle({
        jsonrpc: "2.0",
        method: "resources/directory/read",
        id: 1,
        params: { uri: @skill.root },
      })

      assert_equal(
        [
          { uri: "#{@skill.root}/SKILL.md", name: "SKILL.md", mimeType: "text/markdown" },
          { uri: "#{@skill.root}/examples", name: "examples", mimeType: "inode/directory" },
          { uri: "#{@skill.root}/templates", name: "templates", mimeType: "inode/directory" },
        ],
        response[:result][:resources],
      )
    end

    test "resources/directory/read is not recursive" do
      response = @server.handle({
        jsonrpc: "2.0",
        method: "resources/directory/read",
        id: 1,
        params: { uri: "#{@skill.root}/templates" },
      })

      assert_equal(
        [{ uri: "#{@skill.root}/templates/regional", name: "regional", mimeType: "inode/directory" }],
        response[:result][:resources],
      )
    end

    test "resources/directory/read answers a URI that is not a served directory with -32602" do
      response = @server.handle({
        jsonrpc: "2.0",
        method: "resources/directory/read",
        id: 1,
        params: { uri: "#{@skill.root}/missing" },
      })

      assert_equal(-32602, response[:error][:code])
      assert_equal({ uri: "#{@skill.root}/missing" }, response[:error][:data])
    end

    test "resources/directory/read requires the directoryRead setting, which the extension does not imply" do
      server = build_server(skills: [@skill], directory_read: false)

      response = server.handle({
        jsonrpc: "2.0",
        method: "resources/directory/read",
        id: 1,
        params: { uri: @skill.root },
      })

      assert_match(/directoryRead/, response[:error][:data])
    end

    test "#resources_directory_read_handler replaces the manifest-derived listing" do
      child = { uri: "skill://generated/reports", name: "reports", mimeType: "inode/directory" }
      @server.resources_directory_read_handler { |_params| [child] }

      response = @server.handle({
        jsonrpc: "2.0",
        method: "resources/directory/read",
        id: 1,
        params: { uri: "skill://generated" },
      })

      assert_equal([child], response[:result][:resources])
    end

    test "skills/list carries the SEP-2549 cache hints on the modern wire and skills/get does not" do
      list = @server.handle(modern_request("skills/list"))[:result]
      assert_equal "complete", list[:resultType]
      assert_equal 0, list[:ttlMs]
      assert_equal "private", list[:cacheScope]

      get = @server.handle(modern_request("skills/get", uri: @skill.uri))[:result]
      assert_equal "complete", get[:resultType]
      refute get.key?(:ttlMs)
      refute get.key?(:cacheScope)
    end

    test "a skill over the per-skill limits is registered with a warning rather than refused" do
      oversized = {
        uri: Skills.uri_for("huge"),
        frontmatter: { "name" => "huge", "description" => "d" },
        resources: [{ uri: Skills.uri_for("huge"), digest: Skills.digest(SKILL_MD), size: Skill::MAX_TOTAL_SIZE + 1 }],
      }

      # `$VERBOSE = false` because the rake test task runs with `-W0`, under which `Kernel#warn` emits nothing.
      original_verbose = $VERBOSE
      $VERBOSE = false
      server = nil
      assert_output(nil, /exceeds the #{Skill::MAX_TOTAL_SIZE} per-skill limit/) do
        server = build_server(skills: [oversized])
      end

      assert_equal 1, server.skills.size
    ensure
      $VERBOSE = original_verbose
    end

    private

    def entry(uri, content)
      { uri: uri, digest: Skills.digest(content), size: content.bytesize }
    end

    def build_server(skills:, page_size: nil, directory_read: true, configuration: nil)
      MCP::Server.new(
        name: "test",
        capabilities: { resources: {}, extensions: Skills.capability(directory_read: directory_read) },
        skills: skills,
        page_size: page_size,
        configuration: configuration,
      )
    end

    def modern_request(method, params = {})
      {
        jsonrpc: "2.0",
        method: method,
        id: 1,
        params: params.merge(
          _meta: {
            RequestEnvelope::PROTOCOL_VERSION_META_KEY => "2026-07-28",
            RequestEnvelope::CLIENT_CAPABILITIES_META_KEY => {},
          },
        ),
      }
    end
  end
end
