#!/usr/bin/env bash
# Quick script to create and push a release tag

set -euo pipefail

VERSION="${1:-}"

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 1.22.0"
    exit 1
fi

# Ensure version starts with 'v'
if [[ ! "$VERSION" =~ ^v ]]; then
    VERSION="v${VERSION}"
fi

echo "Creating and pushing release tag: $VERSION"
echo ""
echo "Current commits since last tag:"
git log --oneline $(git describe --tags --abbrev=0 2>/dev/null || echo "HEAD")..HEAD | head -10
echo ""

read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled"
    exit 1
fi

# Create tag
git tag -a "$VERSION" -m "Release $VERSION: KubeEdge offline package"

# Show tag info
echo ""
echo "Tag created:"
git show "$VERSION" --stat | head -20

echo ""
read -p "Push tag to remote? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Tag created locally but not pushed"
    echo "To push later, run: git push origin $VERSION"
    exit 0
fi

# Push tag
git push origin "$VERSION"

echo ""
echo "✓ Tag $VERSION pushed successfully"
echo ""
echo "View the build progress at:"
echo "https://github.com/$(git remote get-url origin | sed 's/.*github.com.\([^/]*\)\/\([^/]*\)\.git/\1\/\2/')/actions"
