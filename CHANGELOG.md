# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
