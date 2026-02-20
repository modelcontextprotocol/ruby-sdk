# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.7.1] - 2026-02-21

### Fixed

- Fix `Resource::Contents#to_h` to use correct property names per MCP spec (#235)
- Return JSON-RPC protocol errors for unknown tool calls (#231)
- Fix `logging/setLevel` to return empty hash per MCP specification (#230)

## [0.7.0] - 2026-02-14

### Added

- `logging` support (#103)
- Protocol version negotiation to server initialization (#223)
- Tool arguments to instrumentation data (#218)
- Client info to instrumentation callback (#221)
- `resource_templates` to `MCP::Client` (#225)

### Changed

- Extract `MCP::Annotations` into a dedicated file (#224)

### Fixed

- `Resource::Embedded` not setting `@resource` in `initialize` (#220)

## [0.6.0] - 2026-01-16

### Changed

- Update licensing to Apache 2.0 for new contributions (#213)

### Fixed

- Omit `icons` from responses when empty or nil to reduce context window usage (#212)

## [0.5.0] - 2026-01-11

### Added

- Protocol specification version "2025-11-25" support (#184)
- `icons` parameter support (#205)
- `websiteUrl` parameter in `serverInfo` (#188)
- `description` parameter in `serverInfo` (#201)
- `additionalProperties` support for schema validation (#198)
- "Draft" protocol version to supported versions (#179)
- `stateless` mode for high availability (#101)
- Exception messages for tool call errors (#194)
- Elicitation skeleton (#178)
- `prompts/list` and `prompts/get` support to client (#163)
- Accept header validation for HTTP client transport (#207)
- Ruby 2.7 - Ruby 3.1 support (#206)

### Changed

- Make tool names stricter (#204)

### Fixed

- Symlink path comparison in schema validation (#193)
- Duplicate tool names across namespaces now raise an error (#199)
- Tool error handling to follow MCP spec (#165)
- XSS vulnerability in json_rpc_handler (#175)

## [0.4.0] - 2025-10-15

### Added

- Client resources support with `resources/list` and `resources/read` methods (#160)
- `_meta` field support for Tool schema (#124)
- `_meta` field support for Prompt
- `title` field support for prompt arguments
- `call_tool_raw` method to client for accessing full tool responses (#149)
- Structured content support in tool responses (#147)
- AGENTS.md development guidance documentation (#134)
- Dependabot configuration for automated dependency updates (#138)

### Changed

- Set default `content` to empty array instead of `nil` (#150)
- Improved prompt spec compliance (#153)
- Allow output schema to be array of objects (#144)
- Return 202 response code for accepted JSON-RPC notifications (#114)
- Added validation to `MCP::Configuration` setters (#145)
- Updated metaschema URI format for cross-OS compatibility

### Fixed

- Client tools functionality and test coverage (#166)
- Client resources test for empty responses (#162)
- Documentation typos and incorrect examples (#157, #146)
- Removed redundant transport requires (#154)
- Cleaned up unused block parameters and magic comments

## [0.3.0] - 2025-09-14

### Added

- Tool output schema support with comprehensive validation (#122)
- HTTP client transport layer for MCP clients (#28)
- Tool annotations validation for protocol compatibility (#122)
- Server instructions support (#87)
- Title support in server info (#119)
- Default values for tool annotation hints (#118)
- Notifications/initialized method implementation (#84)

### Changed

- Make default protocol version the latest specification version (#83)
- Protocol version validation to ensure valid values (#80)
- Improved tool handling for tools with no arguments (#85, #86)
- Better error handling and response API (#109)

### Fixed

- JSON-RPC notification format in Streamable HTTP transport (#91)
- Errors when title is not specified (#126)
- Tools with missing arguments handling (#86)
- Namespacing issues in README examples (#89)

## [0.2.0] - 2025-07-15

### Added

- Custom methods support via `define_custom_method` (#75)
- Streamable HTTP transport implementation (#33)
- Tool argument validation against schemas (#43)

### Changed

- Server context is now optional for Tools and Prompts (#54)
- Improved capability handling and removed automatic capability determination (#61, #63)
- Refactored architecture in preparation for client support (#27)

### Fixed

- Input schema validation for schemas without required fields (#73)
- Error handling when sending notifications (#70)

## [0.1.0] - 2025-05-30

Initial release in collaboration with Shopify
