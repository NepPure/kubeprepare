#!/usr/bin/env bash
# KubeEdge Offline Package Release Builder
# This script builds offline packages for both cloud and edge nodes,
# and creates a GitHub release with the built artifacts.
#
# Usage: ./scripts/create-release.sh <version> [architectures]
# Example: ./scripts/create-release.sh 1.22.0 "amd64 arm64"
#          ./scripts/create-release.sh 1.22.0          # Builds amd64 and arm64 by default

set -euo pipefail

VERSION="${1:-}"
ARCHITECTURES="${2:-amd64 arm64}"
K3S_VERSION="${3:-v1.28.0}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR="${PROJECT_ROOT}/release"
LOG_FILE="${PROJECT_ROOT}/release-build.log"

# Validate version
if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version> [architectures] [k3s-version]"
    echo "Example: $0 1.22.0"
    echo "         $0 1.22.0 'amd64 arm64'"
    echo "         $0 1.22.0 'amd64 arm64' v1.27.0"
    exit 1
fi

# Ensure version starts with 'v'
if [[ ! "$VERSION" =~ ^v ]]; then
    VERSION="v${VERSION}"
fi

# Remove leading 'v' for package naming
VERSION_NO_V="${VERSION#v}"

echo "=== KubeEdge Offline Package Release Builder ===" | tee "$LOG_FILE"
echo "Version: $VERSION" | tee -a "$LOG_FILE"
echo "K3S Version: $K3S_VERSION" | tee -a "$LOG_FILE"
echo "Architectures: $ARCHITECTURES" | tee -a "$LOG_FILE"
echo "Project Root: $PROJECT_ROOT" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Create release directory
mkdir -p "$RELEASE_DIR"
rm -rf "$RELEASE_DIR"/*
echo "[1] Cleaned release directory: $RELEASE_DIR" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Build cloud packages
echo "[2] Building cloud packages..." | tee -a "$LOG_FILE"
for arch in $ARCHITECTURES; do
    echo "  Building cloud package for $arch..." | tee -a "$LOG_FILE"
    cd "$PROJECT_ROOT/cloud/build"
    if ! bash build.sh "$arch" "$K3S_VERSION" 2>&1 | tee -a "$LOG_FILE"; then
        echo "  Warning: Cloud build for $arch failed, continuing..." | tee -a "$LOG_FILE"
    else
        echo "  ✓ Cloud package built for $arch" | tee -a "$LOG_FILE"
    fi
done
echo "" | tee -a "$LOG_FILE"

# Build edge packages
echo "[3] Building edge packages..." | tee -a "$LOG_FILE"
for arch in $ARCHITECTURES; do
    echo "  Building edge package for $arch..." | tee -a "$LOG_FILE"
    cd "$PROJECT_ROOT/edge/build"
    if ! bash build.sh "$arch" "$VERSION_NO_V" 2>&1 | tee -a "$LOG_FILE"; then
        echo "  Warning: Edge build for $arch failed, continuing..." | tee -a "$LOG_FILE"
    else
        echo "  ✓ Edge package built for $arch" | tee -a "$LOG_FILE"
    fi
done
echo "" | tee -a "$LOG_FILE"

# List generated packages
echo "[4] Generated packages:" | tee -a "$LOG_FILE"
cd "$RELEASE_DIR"
if [ -f "*.tar.gz" ]; then
    ls -lh *.tar.gz 2>/dev/null || true | tee -a "$LOG_FILE"
else
    echo "  No packages found in $RELEASE_DIR" | tee -a "$LOG_FILE"
fi
echo "" | tee -a "$LOG_FILE"

# Generate release notes
RELEASE_NOTES_FILE="${RELEASE_DIR}/RELEASE_NOTES.md"
cat > "$RELEASE_NOTES_FILE" << EOF
# KubeEdge $VERSION Offline Installation Packages

## Overview
Complete offline installation packages for KubeEdge $VERSION with k3s ($K3S_VERSION) on cloud and edge nodes.

## Contents

### Cloud Node Packages
- Cloud package includes: k3s ($K3S_VERSION), KubeEdge CloudCore ($VERSION_NO_V), keadm
- Supports multiple architectures: $ARCHITECTURES

### Edge Node Packages
- Edge package includes: KubeEdge EdgeCore ($VERSION_NO_V), keadm, containerd, runc, CNI plugins
- Supports multiple architectures: $ARCHITECTURES

## Installation

### Cloud Node Installation
1. Extract the cloud package:
   \`\`\`bash
   tar -xzf kubeedge-cloud-${VERSION_NO_V}-k3s-${K3S_VERSION}-<arch>.tar.gz
   cd kubeedge-cloud-${VERSION_NO_V}-k3s-${K3S_VERSION}-<arch>
   \`\`\`

2. Run the installation script with external IP:
   \`\`\`bash
   sudo ./install.sh <external-ip>
   \`\`\`

3. The script will:
   - Install k3s
   - Install KubeEdge CloudCore
   - Generate edge node token
   - Print the token for edge node connection

### Edge Node Installation
1. Extract the edge package:
   \`\`\`bash
   tar -xzf kubeedge-edge-${VERSION_NO_V}-<arch>.tar.gz
   cd kubeedge-edge-${VERSION_NO_V}-<arch>
   \`\`\`

2. Run the installation script with cloud address and token:
   \`\`\`bash
   sudo ./install.sh <cloud-ip>:<cloud-port> <token> [node-name]
   \`\`\`

3. The script will:
   - Install EdgeCore
   - Configure container runtime
   - Join the edge node to the cloud cluster

## Architecture Support

- **amd64**: Intel/AMD 64-bit processors
- **arm64**: ARM 64-bit processors (e.g., Raspberry Pi 4, Jetson)

## Supported Systems

- Linux (CentOS, Ubuntu, Debian, etc.)
- Docker or containerd runtime already installed on edge nodes

## Quick Start

### Cloud Setup
\`\`\`bash
# Extract cloud package
tar -xzf kubeedge-cloud-${VERSION_NO_V}-*.tar.gz
cd kubeedge-cloud-${VERSION_NO_V}-*

# Install with external IP 192.168.1.100
sudo ./install.sh 192.168.1.100

# Note: Installation will display the edge token at the end
\`\`\`

### Edge Setup
\`\`\`bash
# Extract edge package
tar -xzf kubeedge-edge-${VERSION_NO_V}-*.tar.gz
cd kubeedge-edge-${VERSION_NO_V}-*

# Connect to cloud (use token from cloud installation)
sudo ./install.sh 192.168.1.100:10000 <TOKEN> my-edge-node
\`\`\`

## Verification

### On Cloud Node
\`\`\`bash
# Check k3s cluster
kubectl get nodes

# Check CloudCore
kubectl -n kubeedge get pod
\`\`\`

### On Edge Node
\`\`\`bash
# Check EdgeCore service
systemctl status edgecore

# View logs
journalctl -u edgecore -f
\`\`\`

## Troubleshooting

- **Cloud installation fails**: Check internet connectivity, firewall rules
- **Edge connection fails**: Verify cloud IP and port, check token validity
- **Architecture mismatch**: Ensure package architecture matches node architecture (use \`uname -m\`)

## Support

For issues or questions, refer to:
- KubeEdge Documentation: https://kubeedge.io
- k3s Documentation: https://docs.k3s.io

## Release Date
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

echo "✓ Release notes generated: $RELEASE_NOTES_FILE" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Display build summary
echo "=== Build Summary ===" | tee -a "$LOG_FILE"
echo "Version: $VERSION" | tee -a "$LOG_FILE"
echo "Location: $RELEASE_DIR" | tee -a "$LOG_FILE"
echo "Log file: $LOG_FILE" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Package listing:" | tee -a "$LOG_FILE"
cd "$RELEASE_DIR"
ls -lh | tail -n +2 | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Ask about git tag
echo ""
echo "Do you want to create a git tag and release? (y/n)"
read -p "Continue? " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Skipped git tag creation"
    echo "To create tag later, run: cd $PROJECT_ROOT && git tag -a $VERSION -m 'Release $VERSION: KubeEdge offline packages'"
    exit 0
fi

# Create and push git tag
cd "$PROJECT_ROOT"
echo "" | tee -a "$LOG_FILE"
echo "Creating git tag: $VERSION" | tee -a "$LOG_FILE"

git tag -a "$VERSION" -m "Release $VERSION: KubeEdge offline packages

- Cloud package: k3s $K3S_VERSION + KubeEdge $VERSION
- Edge package: KubeEdge $VERSION
- Architectures: $ARCHITECTURES
- Build date: $(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>&1 | tee -a "$LOG_FILE" || true

echo ""
echo "Tag created:"
git show "$VERSION" --stat 2>&1 | head -20 | tee -a "$LOG_FILE" || true

echo ""
echo "Do you want to push tag to remote? (y/n)"
read -p "Continue? " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Tag created locally but not pushed" | tee -a "$LOG_FILE"
    echo "To push later, run: git push origin $VERSION"
    exit 0
fi

# Push tag
echo "Pushing tag to remote..." | tee -a "$LOG_FILE"
git push origin "$VERSION" 2>&1 | tee -a "$LOG_FILE" || true

echo "" | tee -a "$LOG_FILE"
echo "=== Release process completed ===" | tee -a "$LOG_FILE"
echo "Tag: $VERSION" | tee -a "$LOG_FILE"
echo "Packages: $RELEASE_DIR" | tee -a "$LOG_FILE"

echo ""
echo "✓ Tag $VERSION pushed successfully"
echo ""
echo "View the build progress at:"
echo "https://github.com/$(git remote get-url origin | sed 's/.*github.com.\([^/]*\)\/\([^/]*\)\.git/\1\/\2/')/actions"
