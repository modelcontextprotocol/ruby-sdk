# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.24.0] - 2026-07-12

### Added

- Support SSE reconnection per SEP-1699 in the HTTP client transport (#426)
- Validate the RFC 9207 `iss` authorization response parameter per SEP-2468 (#431)
- Support `private_key_jwt` client authentication for the `client_credentials` grant (#432)
- Recognize multi round-trip `input_required` results per SEP-2322 (#433)
- Add opt-in `ttlMs` / `cacheScope` cache hints to List and Read results per SEP-2549 (#436)
- Add `server/discover` and stateless lifecycle error codes per SEP-2575 (#438)
- Associate server-to-client requests with the originating client request per SEP-2260 (#440)
- Add server-side MCP Apps helpers per SEP-1865 (#441)
- Support client-side elicitation with SEP-1034 schema defaults (#443)
- Support class-based Resource and ResourceTemplate definitions (#447)

### Changed

- Bind stored client credentials to the authorization server issuer per SEP-2352 (#439)

### Fixed

- Handle non-object JSON-RPC messages without raising (#448)
- Perform SSE stream writes outside the session mutex (#449)
- Validate required params for `initialize` and `resources/subscribe` (#451)

## [0.23.0] - 2026-07-07

### Added

- Add a session-ownership hook to `StreamableHTTPTransport`

### Changed

- Require calling `MCP::Client#connect` before sending requests on stdio transport (#427)

### Deprecated

- Annotate Roots, Sampling, and Logging APIs as deprecated per SEP-2577 (#429)

### Fixed

- Fix an incorrect `result: null` response to an id-bearing notification message (#435)
- Validate `Host` and `Origin` headers to prevent DNS rebinding per MCP 2025-11-25
- Bound stateful session retention to prevent an initialize-flood DoS
- Bound stdio frame reads with `max_line_bytes`
- Bound request body and frame reads to prevent memory-exhaustion DoS

## [0.22.0] - 2026-06-27

### Added

- Add `audience` role validation for `MCP::Annotations` per MCP specification (#422)
- Send SEP-2243 `Mcp-Method` and `Mcp-Name` headers per MCP specification (#423)
- Support client-side `notifications/cancelled` per MCP specification (#425)

### Changed

- Conform Tool Schemas to JSON Schema 2020-12 per SEP-2106 (#417)

### Fixed

- Fix a `SyntaxError` on Ruby 2.7.0 caused by arguments forwarding syntax (#419)

## [0.21.0] - 2026-06-20

### Added

- Support capability extensions per SEP-2133 (#405)
- Add range validation for `MCP::Annotations#priority` per MCP specification (#410)
- Isolate stateless requests in ephemeral sessions per SEP-2567 (#415)

### Changed

- Set OIDC `application_type` on Dynamic Client Registration per SEP-837 (#408)
- Fall back to legacy 2025-03-26 OAuth discovery for servers without PRM (#414)

## [0.20.0] - 2026-06-14

### Added

- Support W3C Trace Context Propagation via `_meta` per SEP-414 (#397)
- Support OAuth `client_credentials` grant in OAuth client (#399)
- Add `annotations` field to `MCP::Resource` and `MCP::ResourceTemplate` per MCP specification (#403)

### Changed

- Re-run OAuth flow on 403 `insufficient_scope` (step-up) (#368)
- Speed up `Tool::Schema` validation by 5x to 100x (#369)
- Use JSON-RPC error envelope for `StreamableHTTPTransport` errors (#371)
- Pin RFC 8414 default well-known suffix per SEP-2351 (#395)
- Default missing `MCP-Protocol-Version` to `2025-03-26` in `StreamableHTTPTransport` (#392)

### Fixed

- Preserve the request ID in invalid request error responses (#400)
- Standardize Resource Not Found errors on -32602 with URI data per SEP-2164 (#402)

## [0.19.0] - 2026-06-13

### Added

- Support Client ID Metadata Documents in OAuth client (#361)
- Request `offline_access` scope when supported (#365)
- Add `size` field to `MCP::Resource` per MCP specification (#393)

## [0.18.0] - 2026-05-30

### Added

- Support server-to-client `ping` per MCP specification (#358)

### Changed

- Warn on implicit stdio initialization (#338)
- Cache `Tool::Schema` validation to avoid re-validating identical schemas (#363)

### Fixed

- Fix case-sensitive `Accept` header comparison (#359)

## [0.17.0] - 2026-05-19

### Added

- Add OAuth 2.1 client support for MCP authorization flow (#353)

### Fixed

- Validate `MCP-Protocol-Version` header in `StreamableHTTPTransport` (#347)
- Reject duplicate `initialize` requests (#350)
- Reject non-Hash JSON-RPC bodies in `StreamableHTTPTransport` (#354)

## [0.16.0] - 2026-05-14

### Added

- Add opt-in tool output validation (#344)

### Changed

- Advertise JSON Schema 2020-12 dialect on emitted tool schemas (#342)

### Fixed

- Preserve client tool output schemas (#343)
- Fix missing `output_schema` argument in `define_tool` API (#301)

## [0.15.0] - 2026-05-05

### Added

- Support `notifications/cancelled` per MCP specification (#332)
- Add client-level `connect` for initialize handshake (#327)
- Add client-level `connect` handshake to stdio transport (#336)

### Changed

- Return tool argument validation failures as tool execution errors (#333)

### Removed

- Remove obsolete `MCP::Transports` module (#331)

## [0.14.0] - 2026-04-24

### Added

- Support pagination per MCP specification (#320)
- Support resource subscriptions per MCP specification (#313)
- Add `roots/list` and `notifications/roots/list_changed` support (#315)
- Support JSON response mode for `StreamableHTTPTransport` (#328)
- Add HTTP client close for explicit session termination (#326)
- Track `Mcp-Session-Id` and protocol version in HTTP client (#325)
- Support `ping` client API per MCP specification (#324)

### Fixed

- Handle 202 Accepted response in HTTP client (#323)

### Changed

- Parse SSE responses in HTTP client via `event_stream_parser` (#322)

## [0.13.0] - 2026-04-16

### Added

- Make `StreamableHTTPTransport` a Rack application (#263)
- Support `elicitation/create` per MCP specification (#312)
- Add `around_request` hook for request instrumentation (#309)
- Add `_meta` field to resource, content, and result classes (#310)

### Removed

- Remove `Server#create_sampling_message` direct call (#311)

## [0.12.0] - 2026-04-11

### Added

- Support customizing the Faraday client in `MCP::Client::HTTP` (#306)

### Changed

- Auto-set `server.transport` in `Transport#initialize` (#305)

### Fixed

- Validate Content-Type on POST requests (#304)

## [0.11.0] - 2026-04-06

### Added

- Support `sampling/createMessage` per MCP specification (#282)
- Support `completion/complete` per MCP specification (#289)

### Fixed

- Support POST response SSE streams for server-to-client messages (#294)
- Return protocol errors for invalid arguments and server errors (#285)
- Fix client methods silently swallowing JSON-RPC error responses (#281)
- Close streams outside mutex in session cleanup (#291)

## [0.10.0] - 2026-03-30

### Added

- Session expiry controls for `StreamableHTTPTransport` via `session_idle_timeout:` option (#268)

### Changed

- `ServerSession` for per-connection state (#275)

### Removed

- Remove `Server#notify_progress` broadcast API (#276)
- Remove undocumented handler override methods (#270)

### Fixed

- Reject POST requests without session ID in stateful mode (#274)

## [0.9.2] - 2026-03-27

### Fixed

- Use accessor method in `server_context_with_meta` instead of ivar (#273)
- Reject duplicate SSE connections with 409 to prevent stream hijacking

## [0.9.1] - 2026-03-23

### Added

- Allow `Client#call_tool` to accept a tool name (#266)

### Fixed

- Return 404 for invalid session ID in `handle_delete` (#261)

## [0.9.0] - 2026-03-20

### Added

- `MCP::Client::Stdio` transport (#262)
- Progress notifications per MCP specification (#254)
- Automatic `_meta` parameter extraction support (#172)
- CORS and Accept wildcard support for browser-based MCP clients (#253)

### Changed

- Use `autoload` to defer loading of unused subsystems (#255)
- Reduce release package size (#239)

### Fixed

- Return 404 for invalid session ID in `handle_regular_request` (#257)
- Use mutex-protected `session_exists?` in `handle_regular_request` (#258)

## [0.8.0] - 2026-03-03

### Added

- `Content::EmbeddedResource` class for embedded resource content type (#244)
- `Content::Audio` class for audio content type (#243)
- `$ref` support in `Tool::Schema` for protocol version 2025-11-25 (#242)
- MCP conformance test suite (#248)

### Fixed

- Handle `Errno::ECONNRESET` in SSE stream operations (#249)
- Fix default handler return values to comply with MCP spec (#247)
- Fix `Prompt#validate_arguments!` crash when arguments are `nil` (#246)
- Return 202 Accepted for SSE responses per MCP spec (#245)
- Fix `Content::Image#to_h` to return `mimeType` (camelCase) per MCP spec (#241)

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
