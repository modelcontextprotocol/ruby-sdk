#!/bin/bash
set -e

# Generates versioned documentation links and commits to gh-pages branch
#
# PURPOSE:
#   This script generates a landing page with links to API documentation on
#   RubyDoc.info for a specific version tag. This script is invoked by the
#   publish-gh-pages job in the GitHub Actions workflow
#   (.github/workflows/release.yml) when a release is published.
#
# HOW IT WORKS:
#   - Creates isolated git worktrees for the specified tag and gh-pages branch
#   - Copies static Jekyll template files from docs/
#   - Generates _data/versions.yml with list of versions
#   - Commits changes to gh-pages (does not push automatically)
#
# WORKFLOW:
#   1. Run this script with a tag name: `generate-gh-pages.sh v1.2.3`
#   2. Script generates docs and commits to local gh-pages branch
#   3. Push gh-pages branch to deploy: `git push origin gh-pages`

# Parse semantic version from tag name (ignoring arbitrary prefixes)
if [[ "${1}" =~ ([0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?)$ ]]; then
  VERSION="v${BASH_REMATCH[1]}"
else
  echo "Error: Must specify a tag name that contains a valid semantic version"
  echo "Usage: ${0} <tag-name>"
  echo "Examples:"
  echo "  ${0} 1.2.3"
  echo "  ${0} v2.0.0-rc.1"
  exit 1
fi

TAG_NAME="${1}"
REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "Generating documentation for tag: ${TAG_NAME}"

# Create temporary directories for both worktrees
WORKTREE_DIR=$(mktemp -d)
GHPAGES_WORKTREE_DIR=$(mktemp -d)

# Set up trap to clean up both worktrees on exit
trap 'git worktree remove --force "${WORKTREE_DIR}" 2>/dev/null || true; \
      git worktree remove --force "${GHPAGES_WORKTREE_DIR}" 2>/dev/null || true' EXIT

echo "Creating worktree for ${TAG_NAME}..."
git worktree add --quiet "${WORKTREE_DIR}" "${TAG_NAME}"

# Check if gh-pages branch exists
if git show-ref --verify --quiet refs/heads/gh-pages; then
  echo "Creating worktree for existing gh-pages branch..."
  git worktree add --quiet "${GHPAGES_WORKTREE_DIR}" gh-pages
elif git ls-remote --exit-code --heads origin gh-pages > /dev/null 2>&1; then
  echo "Creating worktree for gh-pages branch from remote..."
  git worktree add --quiet "${GHPAGES_WORKTREE_DIR}" -b gh-pages origin/gh-pages
else
  echo "Creating worktree for new orphan gh-pages branch..."
  git worktree add --quiet --detach "${GHPAGES_WORKTREE_DIR}"
  git -C "${GHPAGES_WORKTREE_DIR}" checkout --orphan gh-pages
  git -C "${GHPAGES_WORKTREE_DIR}" rm -rf . > /dev/null 2>&1 || true
fi

# Change to gh-pages worktree
cd "${GHPAGES_WORKTREE_DIR}"

# Determine if this tag is the latest version
echo "Determining if ${VERSION} is the latest version..."

# Get all existing version tags from the repository (reverse sorted, newest first)
ALL_VERSIONS=$(
  git -C "${REPO_ROOT}" tag --list | \
  sed -nE 's/^[^0-9]*([0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?)$/v\1/p' | \
  sort -Vr
)

# Get the latest version from all version tags
LATEST_VERSION=$(echo "${ALL_VERSIONS}" | head -n 1)

if [ "${VERSION}" = "${LATEST_VERSION}" ]; then
  echo "${VERSION} is the latest version"
else
  echo "${VERSION} is not the latest version (latest is ${LATEST_VERSION})"
fi

# Update custom documentation for latest version
if [ "${VERSION}" = "${LATEST_VERSION}" ]; then
  echo "Updating custom documentation..."

  # Clean up old custom docs from gh-pages root
  echo "Cleaning gh-pages root..."
  git ls-tree --name-only HEAD | xargs -r git rm -rf

  # Copy custom docs from docs/ directory
  echo "Copying custom docs from ${WORKTREE_DIR}/docs/..."
  cp -r "${WORKTREE_DIR}/docs/." "${GHPAGES_WORKTREE_DIR}/"
fi

# Generate version data for Jekyll
echo "Generating _data/versions.yml..."
mkdir -p _data
echo "${ALL_VERSIONS}" | sed 's/^v/- /' > _data/versions.yml

# Stage all changes
git add .

# Commit if there are changes
if git diff --staged --quiet; then
  echo "No changes to commit"
else
  echo "Committing documentation for ${VERSION}..."
  git commit -m "Add ${VERSION} docs"

  echo "Documentation committed to gh-pages branch!"
  echo "Push to remote to deploy to GitHub Pages"
fi

echo "Done!"
