# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

module MCP
  class ServerSkillsTest < ActiveSupport::TestCase
    include InitializeParamsTestHelper
    include InstrumentationTestHelper

    SKILL_MD = "---\nname: pdf-processing\ndescription: Extract PDFs\n---\n\nBody.\n"

    def entry(uri, content)
      Skill::ResourceEntry.from_content(uri: uri, content: content)
    end

    def pdf_skill
      Skill.new(
        uri: "skill://pdf-processing/SKILL.md",
        frontmatter: { name: "pdf-processing", description: "Extract PDFs" },
        resources: [entry("skill://pdf-processing/SKILL.md", SKILL_MD), entry("skill://pdf-processing/references/FORMS.md", "Forms\n")],
      )
    end

    def git_skill
      Skill.new(uri: "skill://git/SKILL.md", frontmatter: { name: "git", description: "Git" }, resources: "dynamic")
    end

    # No keyword next to the positional params Hash: Ruby 2.7 would read the Hash as the keywords.
    def request(method, params = nil)
      body = { jsonrpc: "2.0", id: 1, method: method }
      body[:params] = params if params
      body
    end

    def modern_request(method, params = {})
      request(method, params.merge(_meta: {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientInfo": { name: "modern_client", version: "2.0" },
        "io.modelcontextprotocol/clientCapabilities": {},
      }))
    end

    def initialize_capabilities(server)
      server.handle(request("initialize", initialize_params)).dig(:result, :capabilities)
    end

    test "a server without skills answers -32601 and advertises no extension" do
      server = Server.new(name: "plain")

      response = server.handle(request("skills/list"))
      assert_equal JsonRpcHandler::ErrorCode::METHOD_NOT_FOUND, response[:error][:code]
      assert_equal "skills/list", response[:error][:data]
      assert_equal JsonRpcHandler::ErrorCode::METHOD_NOT_FOUND, server.handle(request("skills/get", { uri: "skill://x/SKILL.md" }))[:error][:code]
      refute initialize_capabilities(server).key?(:extensions)
      assert_nil server.skills
    end

    test "skills: nil is the same as omitting it, skills: [] serves an empty catalog" do
      assert_nil Server.new(name: "plain", skills: nil).skills

      server = Server.new(name: "empty", skills: [])
      assert_equal [], server.skills
      assert_predicate server.skills, :frozen?
      assert_equal({ Skill::EXTENSION_ID => {} }, initialize_capabilities(server)[:extensions])
      assert_equal({ skills: [] }, server.handle(request("skills/list"))[:result])
      response = server.handle(request("skills/get", { uri: "skill://x/SKILL.md" }))
      assert_equal(-32602, response[:error][:code])
      assert_equal "Skill not found: skill://x/SKILL.md", response[:error][:message]
      assert_equal({ uri: "skill://x/SKILL.md" }, response[:error][:data])
    end

    test "lists and gets registered skills, paginated like the other lists" do
      server = Server.new(name: "catalog", skills: [pdf_skill, git_skill], page_size: 1)

      first = server.handle(request("skills/list"))[:result]
      assert_equal ["skill://pdf-processing/SKILL.md"], first[:skills].map { |skill| skill[:uri] }
      assert_equal "1", first[:nextCursor]
      second = server.handle(request("skills/list", { cursor: "1" }))[:result]
      assert_equal ["skill://git/SKILL.md"], second[:skills].map { |skill| skill[:uri] }
      refute second.key?(:nextCursor)
      assert_equal "dynamic", second[:skills].first[:resources]

      got = server.handle(request("skills/get", { uri: "skill://pdf-processing/SKILL.md" }))[:result]
      assert_equal pdf_skill.to_h, got[:skill]
      refute got.key?(:ttlMs)

      assert_equal(-32602, server.handle(request("skills/list", { cursor: "nope" }))[:error][:code])
    end

    test "skills/list and skills/get carry the _meta of an entry and leave it out of an entry that has none" do
      annotated = Skill.new(uri: "skill://git/SKILL.md", frontmatter: { name: "git", description: "Git" }, resources: "dynamic", meta: { "com.example/origin" => "catalog" })
      from_registry = Server.new(name: "catalog", skills: [pdf_skill, annotated])
      from_handlers = Server.new(name: "catalog")
      from_handlers.skills_handlers(list: ->(_params) { [pdf_skill, annotated] }, get: ->(params) { [pdf_skill, annotated].find { |skill| skill.uri == params[:uri] } })

      [from_registry, from_handlers].each do |server|
        listed = server.handle(request("skills/list"))[:result][:skills]
        refute listed.first.key?(:_meta)
        assert_equal({ "com.example/origin" => "catalog" }, listed.last[:_meta])
        got = server.handle(request("skills/get", { uri: "skill://git/SKILL.md" }))[:result]
        assert_equal annotated.to_h, got[:skill]
        assert_equal({ "com.example/origin" => "catalog" }, got[:skill][:_meta])
        assert_equal '"_meta":{"com.example/origin":"catalog"}', JSON.generate(got[:skill])[/"_meta":\{[^}]*\}/]
      end
    end

    test "skills/list and skills/get are not run without an id, however the skills were configured" do
      # Request methods of the extension need a request id like the protocol's own: framed as notifications, they
      # could never be answered.
      configuration = Configuration.new
      configuration.instrumentation_callback = instrumentation_helper.callback
      from_registry = Server.new(name: "catalog", skills: [pdf_skill], configuration: configuration)
      calls = 0
      list = lambda do |_params|
        calls += 1
        [pdf_skill]
      end
      get = lambda do |_params|
        calls += 1
        pdf_skill
      end
      from_handlers = Server.new(name: "handlers")
      from_handlers.skills_handlers(list: list, get: get)

      [from_registry, from_handlers].each do |server|
        assert_nil server.handle({ jsonrpc: "2.0", method: "skills/list" })
        assert_nil server.handle({ jsonrpc: "2.0", method: "skills/get", params: { uri: pdf_skill.uri } })
      end

      assert_nil instrumentation_helper.data
      assert_equal 0, calls
      from_registry.handle(request("skills/list"))
      assert_equal "skills/list", instrumentation_helper.data[:method]
    end

    test "skills/get refuses a URI that does not name a SKILL.md before any lookup" do
      server = Server.new(name: "catalog", skills: [pdf_skill])

      ["skill://pdf-processing/references/FORMS.md", "skill://pdf-processing", "http://x/SKILL.md", nil, 42].each do |uri|
        response = server.handle(request("skills/get", { uri: uri }))
        assert_equal(-32602, response[:error][:code], uri.inspect)
        assert_equal "Invalid params: uri is not a skill SKILL.md URI", response[:error][:message]
        assert_equal({ uri: uri }, response[:error][:data])
      end
    end

    test "refuses a registry with duplicate URIs and accepts an enclosing skill that lists a nested skill's files" do
      error = assert_raises(ArgumentError) { Server.new(name: "x", skills: [pdf_skill, pdf_skill]) }
      assert_equal "skills: skill skill://pdf-processing/SKILL.md is listed twice.", error.message

      # The specification wants the enclosing manifest complete, nested files and nested SKILL.md included.
      outer = Skill.new(
        uri: "skill://acme/outer/SKILL.md",
        frontmatter: { name: "outer", description: "Outer" },
        resources: [
          entry("skill://acme/outer/SKILL.md", "o"),
          entry("skill://acme/outer/inner/SKILL.md", "i"),
          entry("skill://acme/outer/inner/notes.txt", "n"),
        ],
      )
      inner = Skill.new(uri: "skill://acme/outer/inner/SKILL.md", frontmatter: { name: "inner", description: "Inner" }, resources: "dynamic")
      server = Server.new(name: "x", skills: [outer, inner])
      assert_equal 2, server.skills.size
      listed = server.handle(request("skills/list"))[:result][:skills]
      assert_equal 3, listed.find { |skill| skill[:uri] == "skill://acme/outer/SKILL.md" }[:resources].size

      assert_raises(ArgumentError) { Server.new(name: "x", skills: [pdf_skill, "nope"]) }
    end

    test "handlers answer per request and receive server_context when they ask for it" do
      catalog = [pdf_skill]
      seen_context = nil
      server = Server.new(name: "dynamic")
      server.skills_handlers(
        list: ->(_params, server_context:) {
                seen_context = server_context
                catalog },
        get: ->(params) { catalog.find { |skill| skill.uri == params[:uri] } },
      )

      listed = server.handle(request("skills/list"))[:result]
      assert_equal ["skill://pdf-processing/SKILL.md"], listed[:skills].map { |skill| skill[:uri] }
      assert_kind_of ServerContext, seen_context
      assert_equal pdf_skill.to_h, server.handle(request("skills/get", { uri: "skill://pdf-processing/SKILL.md" })).dig(:result, :skill)
      response = server.handle(request("skills/get", { uri: "skill://git/SKILL.md" }))
      assert_equal(-32602, response[:error][:code])
      assert_equal "Skill not found: skill://git/SKILL.md", response[:error][:message]
      assert_equal [], server.skills
    end

    test "skills_handlers refuses a server whose registry holds skills, which every caller could list and read" do
      server = Server.new(name: "catalog", skills: [pdf_skill])

      error = assert_raises(ArgumentError) { server.skills_handlers(list: ->(_p) { [] }, get: ->(_p) { nil }) }
      assert_match(/cannot be combined with skills in the skills: registry/, error.message)
      # The registry stays what the server serves.
      assert_equal ["skill://pdf-processing/SKILL.md"], server.handle(request("skills/list"))[:result][:skills].map { |skill| skill[:uri] }

      # An empty registry holds nothing to leak, and handlers may be replaced.
      empty = Server.new(name: "catalog", skills: [])
      2.times { empty.skills_handlers(list: ->(_p) { [git_skill] }, get: ->(_p) { git_skill }) }
      assert_equal ["skill://git/SKILL.md"], empty.handle(request("skills/list"))[:result][:skills].map { |skill| skill[:uri] }
    end

    test "a catalog that depends on the caller keeps a hidden skill out of every method when its files go through the same rule" do
      Dir.mktmpdir do |dir|
        root = File.realpath(dir)
        { "guide" => "Public guide", "payroll" => "Payroll runs" }.each do |name, description|
          FileUtils.mkdir_p(File.join(root, name))
          File.write(File.join(root, name, "SKILL.md"), "---\nname: #{name}\ndescription: #{description}\n---\n")
        end
        all = Skill.from_directory(root)
        visible = ->(context) { context[:role] == "admin" ? all : all.reject { |skill| skill.name == "payroll" } }
        server_for = lambda do |role|
          server = Server.new(name: "catalog", server_context: { role: role })
          server.skills_handlers(
            list: ->(_params, server_context:) { visible.call(server_context) },
            get: ->(params, server_context:) { visible.call(server_context).find { |skill| skill.uri == params[:uri] } },
          )
          server.resources_read_handler do |params, server_context:|
            Skill.read_file(visible.call(server_context), params[:uri]) || []
          end
          server
        end
        payroll = "skill://payroll/SKILL.md"

        guest = server_for.call("guest")
        assert_equal ["skill://guide/SKILL.md"], guest.handle(request("skills/list"))[:result][:skills].map { |skill| skill[:uri] }
        assert_equal(-32602, guest.handle(request("skills/get", { uri: payroll }))[:error][:code])
        assert_empty guest.handle(request("resources/list"))[:result][:resources]
        assert_empty guest.handle(request("resources/read", { uri: payroll }))[:result][:contents]
        assert_includes guest.handle(request("resources/read", { uri: "skill://guide/SKILL.md" })).dig(:result, :contents, 0, :text), "Public guide"

        admin = server_for.call("admin")
        assert_equal payroll, admin.handle(request("skills/get", { uri: payroll })).dig(:result, :skill, :uri)
        assert_includes admin.handle(request("resources/read", { uri: payroll })).dig(:result, :contents, 0, :text), "Payroll runs"
      end
    end

    test "an enclosing skill serves the files of a skill nested in it, so hiding the nested skill alone hides nothing" do
      Dir.mktmpdir do |dir|
        root = File.realpath(dir)
        { "guide" => "Public guide", "guide/payroll" => "Payroll runs" }.each do |path, description|
          FileUtils.mkdir_p(File.join(root, path))
          File.write(File.join(root, path, "SKILL.md"), "---\nname: #{File.basename(path)}\ndescription: #{description}\n---\n")
        end
        guide, payroll = Skill.from_directory(root)

        # The manifest of the enclosing skill is complete, as the specification requires, so the nested files are its own.
        assert_includes guide.resources.map(&:uri), payroll.uri
        assert_includes Skill.read_file([guide], payroll.uri).dig(0, :text), "Payroll runs"

        # A caller who must not read the nested skill is therefore not given the enclosing one either.
        assert_nil Skill.read_file([], payroll.uri)
      end
    end

    test "a handler result outside the contract is a server fault with one fixed message" do
      reported = []
      configuration = Configuration.new(exception_reporter: ->(exception, _context) { reported << exception })
      results = { list: nil, get: nil }
      server = Server.new(name: "dynamic", configuration: configuration)
      server.skills_handlers(list: ->(_params) { results[:list] }, get: ->(_params) { results[:get] })

      [["not an array", pdf_skill], ["element", [pdf_skill, 42]], ["duplicate", [pdf_skill, pdf_skill]]].each do |label, result|
        results[:list] = result
        response = server.handle(request("skills/list"))
        assert_equal(-32603, response[:error][:code], label)
        assert_equal "Skills handler returned an invalid result", response[:error][:message], label
      end

      results[:get] = 42
      assert_equal(-32603, server.handle(request("skills/get", { uri: "skill://pdf-processing/SKILL.md" }))[:error][:code])
      results[:get] = git_skill
      assert_equal(-32603, server.handle(request("skills/get", { uri: "skill://pdf-processing/SKILL.md" }))[:error][:code])
      assert_equal 5, reported.size
      assert reported.all? { |exception| exception.is_a?(StandardError) && !exception.is_a?(Server::RequestHandlerError) }

      # An entry built from the wire that lists a nested SKILL.md as a supporting file is within the contract.
      results[:get] = Skill.from_entry(
        "uri" => "skill://acme/outer/SKILL.md",
        "frontmatter" => { "name" => "outer", "description" => "Outer" },
        "resources" => [entry("skill://acme/outer/SKILL.md", "o").to_h, entry("skill://acme/outer/inner/SKILL.md", "i").to_h],
      )
      assert_equal "skill://acme/outer/SKILL.md", server.handle(request("skills/get", { uri: "skill://acme/outer/SKILL.md" }))[:result][:skill][:uri]
    end

    test "skills_handlers requires both callables and leaves the previous configuration intact when a check fails" do
      server = Server.new(name: "plain")
      error = assert_raises(ArgumentError) { server.skills_handlers(list: ->(_p) { [] }, get: nil) }
      assert_equal "skills_handlers requires callable list: and get: handlers.", error.message
      assert_equal JsonRpcHandler::ErrorCode::METHOD_NOT_FOUND, server.handle(request("skills/list"))[:error][:code]

      capabilities = Server::Capabilities.new
      capabilities.support_tools
      server = Server.new(name: "no_resources", capabilities: capabilities)
      error = assert_raises(ArgumentError) { server.skills_handlers(list: ->(_p) { [] }, get: ->(_p) { nil }) }
      assert_match(/requires the resources capability/, error.message)
      assert_equal JsonRpcHandler::ErrorCode::METHOD_NOT_FOUND, server.handle(request("skills/list"))[:error][:code]
      assert_nil server.skills

      server = Server.new(name: "custom")
      server.define_custom_method(method_name: "skills/list") { {} }
      assert_raises(Server::MethodAlreadyDefinedError) { server.skills_handlers(list: ->(_p) { [] }, get: ->(_p) { nil }) }
      assert_nil server.skills

      server = Server.new(name: "catalog", skills: [])
      assert_raises(Server::MethodAlreadyDefinedError) { server.define_custom_method(method_name: "skills/get") { {} } }
    end

    test "skills/list and skills/get carry the cache hints the way resources/list and resources/read do" do
      legacy = Server.new(name: "catalog", skills: [pdf_skill])
      refute legacy.handle(request("skills/list"))[:result].key?(:ttlMs)
      refute legacy.handle(request("skills/get", { uri: "skill://pdf-processing/SKILL.md" }))[:result].key?(:ttlMs)

      configured = Server.new(name: "catalog", skills: [pdf_skill], ttl_ms: 60_000, cache_scope: "public")
      listed = configured.handle(request("skills/list"))[:result]
      assert_equal 60_000, listed[:ttlMs]
      assert_equal "public", listed[:cacheScope]
      got = configured.handle(request("skills/get", { uri: "skill://pdf-processing/SKILL.md" }))[:result]
      assert_equal 60_000, got[:ttlMs]
      assert_equal "public", got[:cacheScope]

      modern = legacy.handle(modern_request("skills/list"))[:result]
      assert_equal "complete", modern[:resultType]
      assert_equal 0, modern[:ttlMs]
      assert_equal "private", modern[:cacheScope]
      got = legacy.handle(modern_request("skills/get", { uri: "skill://pdf-processing/SKILL.md" }))[:result]
      assert_equal "complete", got[:resultType]
      assert_equal 0, got[:ttlMs]
      assert_equal "private", got[:cacheScope]
    end

    test "a handler answers per caller, so its results are never marked for shared caches" do
      server = Server.new(name: "catalog", ttl_ms: 60_000, cache_scope: "public")
      server.skills_handlers(list: ->(_p) { [pdf_skill] }, get: ->(_p) { pdf_skill })
      get_params = { uri: "skill://pdf-processing/SKILL.md" }

      [request("skills/list"), request("skills/get", get_params), modern_request("skills/list"), modern_request("skills/get", get_params)].each do |call|
        result = server.handle(call)[:result]

        assert_equal "private", result[:cacheScope], call[:method]
        assert_equal 60_000, result[:ttlMs], call[:method]
      end

      # Results that are the same for every caller keep the scope the server was configured with.
      assert_equal "public", server.handle(request("tools/list"))[:result][:cacheScope]

      # The reads follow the server unless the read handler says otherwise for what it returns.
      server.resources_read_handler { |_params| [] }
      assert_equal "public", server.handle(request("resources/read", get_params))[:result][:cacheScope]
      server.resources_read_handler { |_params| { contents: [], cacheScope: "private" } }
      assert_equal "private", server.handle(request("resources/read", get_params))[:result][:cacheScope]
    end

    test "resources/list carries each registered skill's SKILL.md with the frontmatter name and description" do
      server = Server.new(name: "catalog", skills: [pdf_skill])
      entry = server.handle(request("resources/list"))[:result][:resources].find { |resource| resource[:uri] == "skill://pdf-processing/SKILL.md" }
      assert_equal "pdf-processing", entry[:name]
      assert_equal "Extract PDFs", entry[:description]
      assert_equal "text/markdown", entry[:mimeType]

      # A resource the application registers at that URI takes the place of the generated entry.
      server.define_resource(uri: "skill://pdf-processing/SKILL.md", name: "custom", mime_type: "text/markdown") { "---\n" }
      entries = server.handle(request("resources/list"))[:result][:resources].select { |resource| resource[:uri] == "skill://pdf-processing/SKILL.md" }
      assert_equal ["custom"], entries.map { |resource| resource[:name] }

      # Replacing the registry brings the generated entry back; a list handler replaces the whole listing.
      server.resources = [Resource.new(uri: "other://x", name: "x")]
      assert_equal ["other://x", "skill://pdf-processing/SKILL.md"], server.handle(request("resources/list"))[:result][:resources].map { |resource| resource[:uri] }
      server.resources_list_handler { |_params| [Resource.new(uri: "custom://only", name: "only")] }
      assert_equal ["custom://only"], server.handle(request("resources/list"))[:result][:resources].map { |resource| resource[:uri] }

      handlers_only = Server.new(name: "catalog")
      handlers_only.skills_handlers(list: ->(_p) { [pdf_skill] }, get: ->(_p) { pdf_skill })
      assert_empty handlers_only.handle(request("resources/list"))[:result][:resources]
    end

    test "the extension is advertised exactly when skills are configured, with resources alongside" do
      error = assert_raises(ArgumentError) do
        capabilities = Server::Capabilities.new
        capabilities.support_resources
        capabilities.support_extensions(Skill.capability)
        Server.new(name: "x", capabilities: capabilities)
      end
      assert_match(/no skills are configured/, error.message)

      error = assert_raises(ArgumentError) do
        capabilities = Server::Capabilities.new
        capabilities.support_tools
        Server.new(name: "x", skills: [], capabilities: capabilities)
      end
      assert_match(/requires the resources capability/, error.message)

      error = assert_raises(ArgumentError) do
        capabilities = Server::Capabilities.new
        capabilities.support_resources
        capabilities.support_extensions(Skill::EXTENSION_ID => { directoryRead: true })
        Server.new(name: "x", skills: [], capabilities: capabilities)
      end
      assert_match(/directoryRead is not served/, error.message)

      capabilities = Server::Capabilities.new
      capabilities.support_resources
      capabilities.support_extensions(Skill.capability.merge("io.modelcontextprotocol/tasks" => {}))
      server = Server.new(name: "x", skills: [pdf_skill], capabilities: capabilities)
      assert_equal(
        { resources: {}, extensions: { Skill::EXTENSION_ID => {}, "io.modelcontextprotocol/tasks" => {} } },
        initialize_capabilities(server),
      )
      assert_equal initialize_capabilities(server), server.handle(request("server/discover")).dig(:result, :capabilities)
    end

    test "the writer and the outgoing snapshot keep advertisement and dispatch consistent" do
      server = Server.new(name: "catalog", skills: [pdf_skill])

      error = assert_raises(ArgumentError) { server.capabilities = { tools: {} } }
      assert_match(/requires the resources capability/, error.message)
      assert_equal Server.new(name: "catalog", skills: [pdf_skill]).capabilities, server.capabilities
      server.capabilities = { resources: {}, logging: {} }
      assert_equal({ resources: {}, logging: {}, extensions: { Skill::EXTENSION_ID => {} } }, initialize_capabilities(server))

      server.capabilities.delete(:resources)
      server.capabilities[:extensions] = { Skill::EXTENSION_ID => { directoryRead: true, other: 1 } }
      advertised = initialize_capabilities(server)
      assert_equal({}, advertised[:resources])
      assert_equal({ other: 1 }, advertised[:extensions][Skill::EXTENSION_ID])
      assert server.handle(request("resources/read", { uri: "skill://pdf-processing/SKILL.md" })).key?(:result), "dispatch gates on the same snapshot"

      plain = Server.new(name: "plain")
      plain.capabilities[:extensions] = { Skill::EXTENSION_ID => {} }
      refute initialize_capabilities(plain).key?(:extensions)
    end

    test "a hand-built declaration needs skills in the same constructor call, handlers may replace the catalog later" do
      capabilities = Server::Capabilities.new
      capabilities.support_resources
      capabilities.support_extensions(Skill.capability)
      server = Server.new(name: "x", skills: [], capabilities: capabilities)
      server.skills_handlers(list: ->(_p) { [pdf_skill] }, get: ->(_p) { nil })

      assert_equal ["skill://pdf-processing/SKILL.md"], server.handle(request("skills/list"))[:result][:skills].map { |skill| skill[:uri] }
    end

    test "the extension identifier is recognized under either key spelling and advertised once" do
      error = assert_raises(ArgumentError) do
        Server.new(name: "x", capabilities: { resources: {}, extensions: { Skill::EXTENSION_ID.to_sym => {} } })
      end
      assert_match(/no skills are configured/, error.message)
      error = assert_raises(ArgumentError) do
        Server.new(name: "x", capabilities: { "resources" => {}, "extensions" => { Skill::EXTENSION_ID => {} } })
      end
      assert_match(/no skills are configured/, error.message)
      error = assert_raises(ArgumentError) do
        Server.new(name: "x", skills: [], capabilities: { resources: {}, extensions: { Skill::EXTENSION_ID.to_sym => { "directoryRead" => true } } })
      end
      assert_match(/directoryRead is not served/, error.message)

      server = Server.new(
        name: "x",
        skills: [pdf_skill],
        capabilities: { resources: {}, extensions: { Skill::EXTENSION_ID.to_sym => { directoryRead: false, other: 1 }, "io.modelcontextprotocol/tasks" => {} } },
      )
      advertised = JSON.parse(JSON.generate(initialize_capabilities(server)))
      assert_equal({ "other" => 1 }, advertised["extensions"][Skill::EXTENSION_ID])
      assert_equal 2, advertised["extensions"].size

      plain = Server.new(name: "plain")
      plain.capabilities[:extensions] = { Skill::EXTENSION_ID.to_sym => {} }
      refute initialize_capabilities(plain).key?(:extensions)

      # A Hash spelling `extensions` both ways is read as one declaration, whichever side holds the Skills entry.
      error = assert_raises(ArgumentError) do
        Server.new(name: "x", capabilities: { extensions: { "io.modelcontextprotocol/tasks" => {} }, "extensions" => { Skill::EXTENSION_ID => {} } })
      end
      assert_match(/no skills are configured/, error.message)
      split = Server.new(name: "split")
      split.capabilities[:extensions] = { "io.modelcontextprotocol/tasks" => {} }
      split.capabilities["extensions"] = { Skill::EXTENSION_ID => {} }
      assert_equal({ "io.modelcontextprotocol/tasks" => {} }, JSON.parse(JSON.generate(initialize_capabilities(split)))["extensions"])
      server = Server.new(
        name: "x",
        skills: [pdf_skill],
        capabilities: { resources: {}, extensions: { Skill::EXTENSION_ID => { other: 1 } }, "extensions" => { "io.modelcontextprotocol/tasks" => {} } },
      )
      advertised = JSON.parse(JSON.generate(initialize_capabilities(server)))
      assert_equal({ "io.modelcontextprotocol/tasks" => {}, Skill::EXTENSION_ID => { "other" => 1 } }, advertised["extensions"])

      # `resources` is advertised under one key, so a nil second spelling cannot serialize after the Hash and undo it.
      [
        { "resources" => {}, resources: nil },
        { resources: nil, "resources" => {} },
        { resources: { listChanged: true }, "resources" => nil },
        { "resources" => { subscribe: true }, resources: { listChanged: true } },
      ].each do |capabilities|
        snapshot = initialize_capabilities(Server.new(name: "x", skills: [pdf_skill], capabilities: capabilities))
        assert_equal [:resources], snapshot.keys.select { |key| key.to_s == "resources" }, capabilities.inspect
        assert_kind_of Hash, snapshot[:resources], capabilities.inspect
      end
      snapshot = initialize_capabilities(Server.new(name: "x", skills: [pdf_skill], capabilities: { "resources" => { subscribe: true }, resources: { listChanged: true } }))
      assert_equal({ listChanged: true }, snapshot[:resources])
    end

    test "skills/get without a params Hash is an invalid-params error, not a server fault" do
      server = Server.new(name: "catalog", skills: [pdf_skill])

      [
        { jsonrpc: "2.0", id: 1, method: "skills/get" },
        { jsonrpc: "2.0", id: 1, method: "skills/get", params: nil },
        { jsonrpc: "2.0", id: 1, method: "skills/get", params: ["skill://pdf-processing/SKILL.md"] },
      ].each do |body|
        response = server.handle(body)
        assert_equal(-32602, response[:error][:code], body.inspect)
        assert_equal "Invalid params: uri is not a skill SKILL.md URI", response[:error][:message]
      end
    end

    test "resources colliding with a directory-backed skill file are refused before anything is committed" do
      Dir.mktmpdir("skills") do |root|
        FileUtils.mkdir_p(File.join(root, "pdf-processing", "references"))
        File.write(File.join(root, "pdf-processing", "SKILL.md"), SKILL_MD)
        File.write(File.join(root, "pdf-processing", "references", "FORMS.md"), "Forms\n")
        skills = Skill.from_directory(root)
        duplicate = Resource.new(uri: "skill://pdf-processing/references/FORMS.md", name: "dup")

        error = assert_raises(ArgumentError) { Server.new(name: "x", skills: skills, resources: [duplicate]) }
        assert_match(/is a file of a directory-backed skill/, error.message)

        server = Server.new(name: "x", skills: skills, resources: [Resource.new(uri: "other://one", name: "one")])
        assert_raises(ArgumentError) { server.define_resource(uri: "skill://pdf-processing/SKILL.md", name: "dup") { "x" } }
        assert_equal ["other://one"], server.resources.map(&:uri)
        assert_raises(ArgumentError) { server.resources = [duplicate] }
        assert_equal ["other://one"], server.resources.map(&:uri)

        server.define_resource_template(uri_template: "skill://pdf-processing/{file}", name: "shadowed") { |_params| "template" }
        assert_equal "Forms\n", server.handle(request("resources/read", { uri: "skill://pdf-processing/references/FORMS.md" })).dig(:result, :contents, 0, :text)
      end
    end
  end
end
