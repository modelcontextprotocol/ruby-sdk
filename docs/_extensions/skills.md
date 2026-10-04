---
layout: default
title: Skills
nav_order: 4
---

# Skills

Skills (SEP-2640) is a Final extension (negotiated via [Capability Extensions](/extensions/capability-extensions/)) that lets a server
publish Agent Skills: folders holding a `SKILL.md` with YAML frontmatter plus supporting files, served as ordinary MCP resources
under `skill://` URIs. The extension adds two methods, `skills/list` and `skills/get`, whose entries name a skill's `SKILL.md`,
repeat its frontmatter, and list its files with SHA-256 digests and sizes, so a host can approve a skill from the listing and
verify every file it later fetches. See the [Skills specification](https://github.com/modelcontextprotocol/ext-skills/blob/main/specification/stable/skills.mdx),
the stable text behind SEP-2640.

## Serving Skills

The common case is a directory of skill folders. `MCP::Skill.from_directory` reads the frontmatter, computes the digests and
sizes, and the server serves `skills/list`, `skills/get`, and `resources/read` for every file:

```ruby
# skills/
#   pdf-processing/
#     SKILL.md             <- frontmatter `name` must equal the directory name
#     references/FORMS.md
server = MCP::Server.new(name: "catalog", skills: MCP::Skill.from_directory("skills"))
```

Passing `skills:` advertises `io.modelcontextprotocol/skills` under `capabilities.extensions`; `resources`, which the SEP requires
alongside it, is part of the default capabilities. An empty Array serves an empty catalog; `nil` (the default) serves no skills,
and `skills/list` then answers `-32601`. `MCP::Skill.capability` exists for a hand-built `MCP::Server::Capabilities`; such
a declaration must be paired with a non-`nil` `skills:` in the same `MCP::Server.new` call.

Skills assembled in code are `MCP::Skill` values whose files the application serves itself:

```ruby
skill_md = File.read("git-workflow/SKILL.md")
skill = MCP::Skill.new(
  uri: "skill://git-workflow/SKILL.md",
  frontmatter: { name: "git-workflow", description: "Branching and commit conventions. Use when preparing a commit or a pull request." },
  resources: [MCP::Skill::ResourceEntry.from_content(uri: "skill://git-workflow/SKILL.md", content: skill_md)],
)
server = MCP::Server.new(name: "catalog", skills: [skill])
server.define_resource(
  uri: "skill://git-workflow/SKILL.md",
  name: "git-workflow", # a SKILL.md resource takes its name and description from the frontmatter
  description: "Branching and commit conventions. Use when preparing a commit or a pull request.",
  mime_type: "text/markdown",
) { skill_md }
```

Every URI a skill lists must be served, or a client reading it fails closed. `MCP::Skill.new` checks what a host may reject:
the URI shape (`skill://<path>/SKILL.md`, segments limited to letters, digits, `-`, `.`, `_`, and `~`), `name` equal to the last
path segment and following the Agent Skills naming rules (1 to 64 lowercase letters, digits, and single hyphens between them),
a `description` of 1 to 1024 characters, JSON-representable frontmatter values, entries under the skill root with
the skill's own `SKILL.md` among them, and the SEP limits of 512 entries and 16 MiB. `resources: "dynamic"` declares a skill
whose files are generated per request and carry no digests. `meta:` is the entry's `_meta`,
passed through under the same JSON rules as the frontmatter and given no meaning by the SDK;
the `io.modelcontextprotocol.skills/` key prefix is reserved for the extension,
so a server's own annotations use its own reverse-domain prefix.
A skill nested in another skill's directory is a skill of its own
and, as the specification requires of a complete manifest, its files (its `SKILL.md` included) are supporting files of
the enclosing skill as well: `from_directory` lists them in both entries, and a hand-built enclosing skill lists them itself.

With the default `resources/list` handler, the listing carries the `SKILL.md` of every registered skill with `name` and
`description` taken from the frontmatter and `mimeType` `text/markdown`, as the specification asks of a `SKILL.md` resource,
unless the application registered a resource at that URI itself (as the example above does in order to serve the file).

{: .important }
> Files of a directory-backed skill are looked up by exact URI in a map built at construction, so request data never reaches
> the filesystem. Dotfiles, symbolic links, FIFOs, and devices are skipped, a hard link is refused, and every other regular file
> is published, editor backups included. The tree is trusted as the operator's: keep it writable only by the operator while
> skills are built and served. Each file is read at request time and refused with `-32603` when its inode, size, or digest
> no longer matches what was registered, or when it has gained a hard link. A read of a URI under such a skill that names
> none of its files answers `-32602`, as the specification requires, so resource templates are shadowed for the whole subtree
> under the skill root; URIs outside every skill root keep the server's usual behavior. A resource registered with the URI of
> a skill file is refused. `resources_read_handler`
> replaces the default reader, skill files included; delegate with `MCP::Skill.read_file(server.skills, params[:uri]) ||
> your_contents`, which returns the `contents` Array or `nil`, and answer `-32602` yourself for a `nil` under a skill root.

### Catalogs That Depend on the Caller

A catalog that depends on the caller is served from handlers; both are required because a server declaring the extension
must answer `skills/get` for every skill it serves, listed or not:

```ruby
server.skills_handlers(
  # Array<MCP::Skill>; the server paginates
  list: ->(params, server_context:) { skills_for(server_context) },
  # MCP::Skill, or nil for -32602
  get: ->(params, server_context:) { skills_for(server_context).find { |skill| skill.uri == params[:uri] } },
)
server.resources_read_handler do |params, server_context:|
  MCP::Skill.read_file(skills_for(server_context), params[:uri]) || other_contents(params[:uri])
end
```

Handlers may receive `server_context:` when they declare the keyword. A result outside this contract
(not an `MCP::Skill`, a duplicate URI, a skill for another URI) is answered with `-32603`.
`skills/list` and `skills/get` carry the `ttlMs`/`cacheScope` cache hints the way `resources/list` and `resources/read` do.

{: .important }
> A server serves skills from the `skills:` registry or from handlers, never both: `skills_handlers` raises `ArgumentError`
> while the registry holds skills, because a registered skill, its `SKILL.md` entry in `resources/list`, and its files
> are served to every caller.

A catalog that hides a skill from some callers applies its rule everywhere itself:

- `server_context` is the value the server was built with, plus the `_meta` of the request under `:_meta`,
  so the catalog needs a server built for each caller from the authenticated request
  (see [Server Context](/server/server-context/)).
- Do not reassign the `server_context` of a server that concurrent requests share,
  and do not decide from `_meta`, which the client chooses.
- Filter `get` as well as `list`, and the reads, as the `resources_read_handler` above does.
  `MCP::Skill.read_file` serves the files of the directory-backed skills among those it is given
  and returns `nil` for any other URI.
- A handler that answers `-32602` for an unserved URI under a skill root, as the specification asks,
  judges that against the caller's skills too, so that a hidden skill answers exactly like a URI that does not exist.
- What the handlers answer is never marked `cacheScope: "public"`:
  where the `cache_scope` of the server would make it so, the result says `"private"`.
- The reads are not covered: on a server configured with `cache_scope: "public"`,
  return `{ contents: contents, cacheScope: "private" }` from the `resources_read_handler` for files that depend on the caller.
- Leaving a nested skill out of a caller's catalog does not hide it from a caller who is given the enclosing skill:
  the enclosing skill lists the nested files as its own, with their URIs, digests, and sizes, as a complete manifest must,
  and serves them.
- Keep a skill that some callers must not see out of the directory of a skill they may see,
  or withhold the enclosing skill from them as well.

## Reading Skills

```ruby
page = client.list_skills                               # ListSkillsResult(skills:, next_cursor:, meta:, ttl_ms:, cache_scope:)
entry = client.get_skill(uri: "skill://pdf-processing/SKILL.md").skill
entry.meta                                              # the entry's _meta as a frozen Hash, or nil
result = client.read_skill_resource(uri: entry.uri, skill: entry)
result.bytes                                            # the verified bytes, frozen
client.read_skill_resource(uri: "skill://pdf-processing/references/FORMS.md", skill: entry).bytes
client.skills_capability                                # the extension settings, or nil
```

Nothing is read ahead of need: the specification forbids fetching a skill's files on connection, on listing, or at approval,
so call `read_skill_resource` for `SKILL.md` when the skill is loaded and for a supporting file when it is used.
A relative reference in a `SKILL.md` resolves against the directory of that `SKILL.md`, which for a nested skill is its own root
and not the enclosing one; `read_skill_resource` takes the resulting URI.

`read_skill_resource` fetches a file through `resources/read` and checks it against the entry remembered from `list_skills` or
`get_skill` (or passed as `skill:`): exactly one content item for the URI, the size before anything is decoded, the SHA-256
digest, and for a `SKILL.md` the frontmatter compared field by field with the entry. A mismatch raises
`MCP::Client::SkillVerificationError` (`reason` `:contents`, `:size`, `:digest`, `:parse`, or `:frontmatter`), withholds
the content, and latches the skill: no further read of it is sent on this connection, even after a new listing, so reading
a latched skill again takes a new connection. A supporting file is read only after the skill's `SKILL.md` verified;
without `skill:` it resolves to the most specific remembered skill that contains it, never to an enclosing one,
and a `SKILL.md` URI resolves only to its own entry, never as a supporting file of an enclosing skill.
The specification resolves a read against the entry the host loaded the skill from, so a host acting on a skill
keeps that entry at least until the skill's `SKILL.md` leaves the model's context and passes it as `skill:`;
when an enclosing skill lists the file too and no `skill:` is given, the read is refused as `:ambiguous` rather than guessed.
Calls refused before anything is sent raise `MCP::Client::SkillReadRefusedError` with `reason` `:not_advertised`
(no handshake of this connection advertised the extension and `resources`), `:connection_changed`, `:latched`,
`:unknown_skill` (pass `skill:` or call `get_skill` first; also the answer for a URI longer than 8 KiB or deeper than
128 segments, which this SDK does not resolve), `:ambiguous`, `:dynamic`, `:not_in_manifest`, or `:skill_md_unverified`;
later releases may add reasons, so treat an unknown one as a refusal.
For a skill the host is acting on, `:not_in_manifest` is what the specification calls a read of an unlisted file,
a verification failure equivalent to a digest mismatch: no content is fetched, the SDK latches nothing
(the URI may come from model output), and a host that takes it as a sign that the skill changed fetches the entry again
with `get_skill`. Both classes inherit from `MCP::Client::SkillError`, and their messages show URIs escaped to ASCII,
since a server chooses them. `meta:` and `cancellation:` work as on the other methods.

Entries are remembered per client and bound to the connection: `connect` forgets them, and a `connect` that performs no new
handshake (the transport is still connected) keeps the latches. A listing or `get_skill` that replaces an entry drops its
verified status, so supporting reads of that skill are refused until its `SKILL.md` is read again, and the specification asks
the host to treat a changed `resources` set as revoking any approval bound to the old one. `skills_capability` returning `nil`
means not ready or not advertised on the current connection, never that skill files may be read raw.

Hosts that load a skill with `read_resource` instead own the obligations above: stop loading the skill on any raise and
verify `SKILL.md` before any other file. `MCP::Skill.verify_resource(skill, uri, bytes)` checks size and digest (pass `text.b`
for a text item, the decoded `blob` otherwise) and `MCP::Skill.verify_frontmatter(skill, text)` compares the frontmatter; a static
`SKILL.md` needs both, and a `"dynamic"` skill can only be checked with the second.

{: .important }
> The frontmatter of a skill entry is untrusted input, and so is its `_meta`. The SDK compares the frontmatter and passes both
> through; it never acts on a field.
> The SEP requires hosts to ignore or approval-gate `allowed-tools`, hooks, and scripts in skills that arrive over MCP, and to treat
> `name` and `description` as display text. `mime_type` on a read result is the server's unverified display metadata. These are
> the obligations the SDK can state here; the Security Considerations of the specification list the rest a host must implement
> itself: tagging content with its originating server, binding resource reads to that server, resolving skill names per origin,
> binding persisted approval to the entry's `resources` set, and isolating any disk cache from filesystem-skill discovery.

{: .note }
> Frontmatter is read under rules stricter than YAML so that every YAML library reads it the same way: one document without
> directives or document markers, no tags, aliases, or merge keys, keys that are untagged strings, values JSON can carry, and no
> plain scalar whose YAML 1.1 reading differs from its YAML 1.2 reading (`yes`, `no`, `on`, `off`, `010`, `1:20`, `1_000`,
> `0o10`, and the like): quote such values. The NEL, LINE SEPARATOR, and PARAGRAPH SEPARATOR characters (line breaks in
> YAML 1.1 only) and integers outside the range from -(2^53 - 1) to 2^53 - 1 (which JavaScript readers round) are refused
> as well. A leading UTF-8 BOM is skipped for extraction while digests cover it. The block is limited to 64 KiB by this SDK,
> not by the protocol. Hosts must accept skills up to the 512-entry and 16 MiB limits and may accept larger ones, so
> the client accepts entries of any size; `MCP::Skill#total_size` and `#resources` are the hooks for a host that declines
> large skills.

`resources/directory/read` and the `directoryRead` setting are not served in this release; declaring `directoryRead` is refused.
