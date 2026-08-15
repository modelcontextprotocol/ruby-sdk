# Roadmap

This roadmap outlines the MCP Ruby SDK's path toward SEP-1730 Tier 1.
It is a living document and will evolve as the SDK matures.

## Current Status

The SDK implements the 2025-06-18, 2025-11-25, and 2026-07-28 spec revisions, and passes all scored server
and client conformance scenarios for each revision's requirement set.
Optional protocol extensions (such as DPoP, workload identity federation, and the tasks extension)
are not yet implemented; SEP-1730 does not require extensions for any tier.

## API Stability

The 1.0.0 release marked the public API as stable: breaking changes ship only in major releases,
apart from the narrow exceptions documented in [VERSIONING.md](VERSIONING.md),
which also defines the Semantic Versioning scheme and breaking-change policy.

## Deprecated Features

The 2026-07-28 spec revision deprecates Roots, Sampling, and Logging (SEP-2577).
These features remain fully supported throughout 1.x, and the SDK emits deprecation warnings when they are used
with protocol version 2026-07-28 or newer.
Under Semantic Versioning their removal requires a major release, but no removal is scheduled yet:
whether 2.0.0 removes them depends on how future MCP spec revisions treat these features
and on adoption of their replacements.

## Conformance

The SDK maintains a 100% conformance pass rate as new scenarios are added to the conformance suite.
Legacy SSE transport (2024-11-05) is intentionally out of scope; the SDK provides modern Streamable HTTP only.

## Documentation

Reference documentation covers all non-experimental features with examples.

## Tracking New Spec Revisions

The SDK aims to support each new MCP specification revision, with the implementation timeline agreed per
release based on feature complexity.
The 2026-07-28 revision shipped during 1.x: the server serves both lifecycle eras side by side,
so the SEP-2575 stateless lifecycle (including `server/discover` and `subscriptions/listen`),
SEP-2322 multi round-trip requests, SEP-2549 cache hints, and SEP-2243 custom headers are available alongside
the legacy handshake. The few incompatible adjustments the revision required shipped in
a minor release under the spec-conformance and security exceptions described in [VERSIONING.md](VERSIONING.md).
Removing legacy-era support is reserved for a future major release.
The tasks extension (SEP-2663) remains planned ([#391](https://github.com/modelcontextprotocol/ruby-sdk/issues/391)).
