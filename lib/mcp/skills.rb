# frozen_string_literal: true

require "digest"

module MCP
  # Server-side vocabulary and helpers for the Skills extension (SEP-2640, Extensions Track, Final):
  # Agent Skills served over the existing Resources primitive. Each file of a skill directory is an
  # ordinary MCP resource, conventionally under the `skill://` scheme, so a host that already treats
  # resources as a virtual filesystem consumes MCP-served skills exactly as it does local ones.
  #
  # The extension is negotiated per SEP-2133 through `capabilities.extensions`. Declaring it commits
  # the server to `skills/list` and `skills/get`; `resources/directory/read` is additionally gated
  # behind the `directoryRead` setting. A server declaring the extension MUST also declare the
  # `resources` capability, since that is where every skill file is actually read from.
  #
  # @example Declaring a skills-serving server
  #   capabilities = MCP::Server::Capabilities.new
  #   capabilities.support_resources
  #   capabilities.support_extensions(MCP::Skills.capability)
  #
  #   server = MCP::Server.new(
  #     name: "docs_server",
  #     capabilities: capabilities,
  #     skills: [
  #       MCP::Skill.new(
  #         uri: MCP::Skills.uri_for("git-workflow"),
  #         frontmatter: { "name" => "git-workflow", "description" => "This team's Git conventions" },
  #         resources: [{ uri: MCP::Skills.uri_for("git-workflow"), digest: MCP::Skills.digest(skill_md), size: skill_md.bytesize }],
  #       ),
  #     ],
  #   )
  #
  #   server.resources_read_handler { |params| [{ uri: params[:uri], mimeType: "text/markdown", text: load(params[:uri]) }] }
  #
  # https://modelcontextprotocol.io/seps/2640-skills-extension
  module Skills
    # Reverse-DNS extension identifier, shared wire vocabulary with the other official SDKs.
    EXTENSION_ID = "io.modelcontextprotocol/skills"

    # Conventional scheme for skill resources. No scheme is privileged: a server MAY serve skills
    # under a scheme native to its domain, and the structural constraints hold either way.
    URI_SCHEME = "skill://"

    # MIME type identifying a directory resource, the only kind `resources/directory/read` accepts.
    DIRECTORY_MIME_TYPE = "inode/directory"

    # MIME type a skill's `SKILL.md` SHOULD carry.
    SKILL_MIME_TYPE = "text/markdown"

    extend self

    # The `capabilities.extensions` fragment advertising Skills support. Pass to
    # `MCP::Server::Capabilities#support_extensions` or merge into a client's declared capabilities.
    # An empty declaration means the extension with none of its optional features.
    def capability(directory_read: false)
      { EXTENSION_ID => directory_read ? { directoryRead: true } : {} }
    end

    # Whether `capabilities` declares the extension (symbol or string keys throughout).
    def declared?(capabilities)
      !declaration(capabilities).nil?
    end

    # Whether `capabilities` declares `resources/directory/read`. Clients MUST NOT call the method
    # against a server that has not.
    def directory_read?(capabilities)
      read_key(declaration(capabilities), :directoryRead) == true
    end

    alias_method :client_supports?, :declared?

    # The skill URI for a skill path: one or more `/`-separated segments whose last is the skill's
    # `name`, with any preceding segments a server-chosen organizational prefix.
    #
    #   uri_for("git-workflow")         # => "skill://git-workflow/SKILL.md"
    #   uri_for("acme/billing/refunds") # => "skill://acme/billing/refunds/SKILL.md"
    def uri_for(skill_path, scheme: URI_SCHEME)
      path = skill_path.to_s.delete_prefix("/").delete_suffix("/")
      raise ArgumentError, "skill_path must name at least one segment" if path.empty?

      "#{scheme}#{path}/#{Skill::SKILL_FILE}"
    end

    # Resolves a skill's internal relative reference (`references/GUIDE.md`) against its root,
    # exactly as the same path would resolve on a filesystem.
    def resolve(skill_uri, relative_path)
      root = skill_uri.delete_suffix("/#{Skill::SKILL_FILE}")
      "#{root}/#{relative_path.to_s.delete_prefix("./").delete_prefix("/")}"
    end

    # The `sha256:<64 lowercase hex>` digest of a file's raw bytes, the form every manifest entry takes.
    def digest(content)
      "sha256:#{Digest::SHA256.hexdigest(content)}"
    end

    private

    def declaration(capabilities)
      declaration = read_key(read_key(capabilities, :extensions), EXTENSION_ID)
      declaration.is_a?(Hash) ? declaration : nil
    end

    def read_key(hash, key)
      return unless hash.is_a?(Hash)

      value = hash[key.to_sym]
      value.nil? ? hash[key.to_s] : value
    end
  end
end
