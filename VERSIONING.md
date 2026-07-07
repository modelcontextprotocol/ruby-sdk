# Versioning Policy

The MCP Ruby SDK follows [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).
This document describes what each version component means for users of the `mcp` gem,
what counts as a breaking change, and how breaking changes are communicated.

## Version Scheme

Given a version number `MAJOR.MINOR.PATCH`:

- **MAJOR** is incremented for incompatible changes to the public API.
- **MINOR** is incremented for backwards-compatible new functionality.
- **PATCH** is incremented for backwards-compatible bug fixes.

### Current 0.x Phase

While the SDK is at version 0.x, the public API is not yet considered stable.
Following SemVer conventions for initial development, minor releases (0.x -> 0.y) may contain breaking changes.
All breaking changes are recorded in [CHANGELOG.md](CHANGELOG.md).

### After 1.0.0

Once 1.0.0 is released, breaking changes will only ship in major releases, with the exceptions described below.

## What Counts as a Breaking Change

A breaking change is any change that requires users to modify their code when upgrading, including:

- Removing or renaming a public class, module, method, or constant
- Changing a public method's signature in a way that rejects previously valid arguments
- Changing documented behavior that users can reasonably depend on

New functionality that is purely additive (new classes, new methods, new optional keyword arguments)
is not a breaking change.

## Exceptions: Spec Compliance, Security, and Clear Defects

Minor releases avoid incompatible changes as much as possible. However, the SDK's primary contract is
conformance to the [MCP specification](https://modelcontextprotocol.io/specification/).
Behavior that deviates from the specification is treated as a bug, even when users may have come to rely on it.
Therefore, incompatible changes may be shipped in a minor release when they are required to:

- Fix incorrect conformance to the MCP specification
- Address a security vulnerability
- Fix a clear defect, such as behavior that contradicts the documentation, a crash,
  or data corruption, where compatibility would mean preserving the defect

When such a change ships, the release notes and CHANGELOG entry explicitly call out the incompatibility
and describe how to migrate.

## How Breaking Changes Are Communicated

- [CHANGELOG.md](CHANGELOG.md) records every release in [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format;
  breaking changes appear under the "Changed" or "Removed" headings
- [GitHub Releases](https://github.com/modelcontextprotocol/ruby-sdk/releases) mirror the changelog for each release
- Where practical, deprecation warnings are added at least one minor release before removal
