## Releases

This gem is published to [RubyGems.org](https://rubygems.org/gems/mcp)

Releases are triggered by PRs to the `main` branch updating the version number in `lib/mcp/version.rb`.

1. **Update the version number** in `lib/mcp/version.rb`, following [semver](https://semver.org/)
2. **Update CHANGELOG.md**, backfilling the changes since the last release if necessary, and adding a new section for the new version, clearing out the Unreleased section
3. **Create a PR and get approval from a maintainer**
4. **Merge your PR to the main branch** - This will automatically trigger the release workflow via GitHub Actions

When changes are merged to the `main` branch, the GitHub Actions workflow (`.github/workflows/release.yml`) is triggered and the gem is published to RubyGems.
