---
layout: default
title: Skills
nav_order: 4
---

# Skills

Skills (SEP-2640) is a Final extension (negotiated via [Capability Extensions](/extensions/capability-extensions/))
that serves [Agent Skills](https://agentskills.io/specification) over the existing Resources primitive.
A skill is a directory of files, minimally a `SKILL.md`, and each of those files is an ordinary MCP resource
under the `skill://` scheme. A host that already treats resources as a virtual filesystem consumes an
MCP-served skill exactly as it consumes one from disk.

The extension adds three methods on top of that: `skills/list` enumerates the skills a server serves,
`skills/get` returns one entry by URI, and the optional `resources/directory/read` lists a directory's
direct children. Skill *content* is always read through ordinary `resources/read`.

```ruby
skill_md = File.read("skills/refunds/SKILL.md")
email_md = File.read("skills/refunds/examples/email.md")
uri = MCP::Skills.uri_for("acme/billing/refunds") # => "skill://acme/billing/refunds/SKILL.md"

capabilities = MCP::Server::Capabilities.new
capabilities.support_resources # required: skill files are read through `resources/read`
capabilities.support_extensions(MCP::Skills.capability(directory_read: true))

server = MCP::Server.new(
  name: "billing_server",
  capabilities: capabilities,
  skills: [
    MCP::Skill.new(
      uri: uri,
      # The verbatim SKILL.md frontmatter: every field the author wrote, not a curated subset.
      frontmatter: { "name" => "refunds", "description" => "Process customer refund requests per company policy" },
      # The complete manifest: every file of the skill, SKILL.md included, with digests and sizes.
      resources: [
        { uri: uri, digest: MCP::Skills.digest(skill_md), size: skill_md.bytesize },
        { uri: MCP::Skills.resolve(uri, "examples/email.md"), digest: MCP::Skills.digest(email_md), size: email_md.bytesize },
      ],
    ),
  ],
)

# Skill files are served as ordinary resources.
server.resources_read_handler do |params|
  [{ uri: params[:uri], mimeType: "text/markdown", text: load_skill_file(params[:uri]) }]
end
```

That server answers `skills/list`, `skills/get` and `resources/directory/read` with no further wiring:
directory children are derived from the registered skills' manifests.

## Entries

A `skills/list` entry is a complete manifest rather than a summary, so a host that pages the listing has,
in that one pass, everything it needs to build its registry, present the skill for approval, bind that
approval to content, and verify every file it later reads. `skills/get` returns the identical shape for a
single skill and is never a step a host must take to complete a listed entry; it exists to refresh one
entry's digests, and to answer for a skill the listing omitted.

`MCP::Skill` enforces the extension's structural rules at construction: the URI addresses the skill's
`SKILL.md`, the frontmatter carries `name` and `description`, the frontmatter `name` equals the final
segment of the skill path, and the manifest is complete, duplicate-free and confined to the skill's root.

{: .important }
A skill whose content is generated per request cannot publish stable digests. Pass
`resources: MCP::Skill::DYNAMIC` instead of a manifest. Such a skill offers no content integrity and
cannot be content-bound, and hosts MAY decline to load it.

## Limits

SEP-2640 fixes two per-skill limits every conforming host accepts: 512 resources and 16 MiB in total.
A registered skill that exceeds either is kept and warned about rather than refused — servers SHOULD stay
within them, but only the host decides whether to load an oversized skill. `MCP::Skill#limit_violations`
reports what a given skill exceeds.

## Unenumerable catalogs

A server whose skill catalog is large, generated, or otherwise unenumerable MAY return an empty or partial
`skills/list`; hosts MUST NOT read that as proof the server has no skills. Such a server replaces the
default lookups, and MUST still answer `skills/get` for every skill it serves:

```ruby
server.skills_list_handler { |_params| [] }
server.skills_get_handler { |params| SkillCatalog.find(params[:uri]) }
server.resources_directory_read_handler { |params| SkillCatalog.children_of(params[:uri]) }
```

Each block may declare `server_context:` to receive the request context, the same opt-in
`resources_list_handler` uses.

## Directory reads

`resources/directory/read` is gated behind the `directoryRead` setting, which
`MCP::Skills.capability(directory_read: true)` declares; a client MUST NOT call it otherwise. It returns the
direct children of a directory resource as the same `Resource` objects `resources/list` returns,
subdirectories carrying `mimeType: "inode/directory"`. The listing is never recursive: a client descends by
calling the method again on a child directory. A URI that does not exist, or that is not a directory
resource, answers `-32602`, as `skills/get` does for an unknown skill.

{: .note }
For a skill whose entry carries a manifest, a directory read tells a host nothing the manifest did not.
It earns its place for dynamically generated skills, for resource trees that are not skills at all, and for
observing a directory without refreshing the entry. A host MUST NOT treat the result as extending a manifest.

See the [Skills extension specification](https://modelcontextprotocol.io/seps/2640-skills-extension).
