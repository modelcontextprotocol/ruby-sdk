# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

Initial release
