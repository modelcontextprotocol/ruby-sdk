# Roadmap

This roadmap outlines the MCP Ruby SDK's path toward SEP-1730 Tier 1.
It is a living document and will evolve as the SDK matures.

## Current Status

The SDK implements the 2025-06-18 and 2025-11-25 spec revisions, and passes all server and client conformance scenarios.

## API Stability

The 1.0.0 release will mark the public API as stable: breaking changes then ship only in major releases,
apart from the narrow exceptions documented in [VERSIONING.md](VERSIONING.md),
which also defines the Semantic Versioning scheme and breaking-change policy.

## Deprecated Features

The 2026-07-28 spec revision deprecates Roots, Sampling, and Logging (SEP-2577).
These features remain fully supported throughout 1.x, and deprecation warnings will be added in a future minor release.
Under Semantic Versioning their removal requires a major release, but no removal is scheduled yet:
whether 2.0.0 removes them depends on how future MCP spec revisions treat these features
and on adoption of their replacements.

## Conformance

The SDK maintains a 100% conformance pass rate as new scenarios are added to the conformance suite.
Legacy SSE transport (2024-11-05) is intentionally out of scope; the SDK provides modern Streamable HTTP only.

## Documentation

Reference documentation covers all core features.

## Tracking New Spec Revisions

The SDK aims to support each new MCP specification revision, with the implementation timeline agreed per
release based on feature complexity.
Additive features from the 2026-07-28 revision (such as `server/discover`, multi round-trip requests,
and the tasks extension) ship as opt-in functionality during 1.x. Breaking parts of that revision,
such as the SEP-2575 stateless lifecycle rewrite, are reserved for 2.0.
