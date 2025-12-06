#!/usr/bin/env bash
set -euo pipefail

# Usage: ./online_prepare.sh [output_dir]
# Example: ./online_prepare.sh /tmp/kubeedge-offline

OUTDIR=${1:-"./kubeedge-offline"}
KUBEEDGE_VER="1.22.0"
CONTAINERD_VER="1.6.20"
CNI_PLUGINS_VER="1.4.0"
RUNC_VER="1.1.9"

mkdir -p "$OUTDIR"
cd "$OUTDIR"

echo "Preparing offline package in: $OUTDIR"

# 1) Download kubeedge
if [ ! -f "kubeedge-v${KUBEEDGE_VER}-linux-amd64.tar.gz" ]; then
  echo "Downloading KubeEdge v${KUBEEDGE_VER}..."
  wget -q --show-progress "https://github.com/kubeedge/kubeedge/releases/download/v${KUBEEDGE_VER}/kubeedge-v${KUBEEDGE_VER}-linux-amd64.tar.gz" || {
    echo "Failed to download KubeEdge. Check network connection."
    exit 1
  }
fi

# 2) Download containerd
if [ ! -f "containerd-${CONTAINERD_VER}-linux-amd64.tar.gz" ]; then
  echo "Downloading containerd v${CONTAINERD_VER}..."
  wget -q --show-progress "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VER}/containerd-${CONTAINERD_VER}-linux-amd64.tar.gz" || {
    echo "Failed to download containerd. Check network connection."
    exit 1
  }
fi

# 3) Download runc
if [ ! -f "runc.amd64" ]; then
  echo "Downloading runc v${RUNC_VER}..."
  wget -q --show-progress -O runc.amd64 "https://github.com/opencontainers/runc/releases/download/v${RUNC_VER}/runc.amd64" || {
    echo "Failed to download runc. Check network connection."
    exit 1
  }
  chmod +x runc.amd64
fi

# 4) Download CNI plugins
if [ ! -f "cni-plugins-linux-amd64-v${CNI_PLUGINS_VER}.tgz" ]; then
  echo "Downloading CNI plugins v${CNI_PLUGINS_VER}..."
  wget -q --show-progress "https://github.com/containernetworking/plugins/releases/download/v${CNI_PLUGINS_VER}/cni-plugins-linux-amd64-v${CNI_PLUGINS_VER}.tgz" || {
    echo "Failed to download CNI plugins. Check network connection."
    exit 1
  }
fi

# 5) Extract edgecore binary
echo "Extracting components..."
if [ ! -d "kubeedge-v${KUBEEDGE_VER}-linux-amd64" ]; then
  tar -zxf "kubeedge-v${KUBEEDGE_VER}-linux-amd64.tar.gz" || {
    echo "Failed to extract KubeEdge archive."
    exit 1
  }
fi

if [ ! -f "kubeedge-v${KUBEEDGE_VER}-linux-amd64/edge/edgecore" ]; then
  echo "edgecore binary not found in kubeedge archive!"
  exit 1
fi

mkdir -p pkg/bin pkg/containerd/bin pkg/cni/bin pkg/etc

# Copy edgecore
echo "Copying edgecore binary..."
cp "kubeedge-v${KUBEEDGE_VER}-linux-amd64/edge/edgecore" pkg/bin/
chmod +x pkg/bin/edgecore

# Copy containerd bins
echo "Extracting containerd..."
tar -zxf "containerd-${CONTAINERD_VER}-linux-amd64.tar.gz" -C pkg/containerd || {
  echo "Failed to extract containerd archive."
  exit 1
}
# containerd tar usually has bin/* - verify it exists
if [ ! -f "pkg/containerd/bin/containerd" ] && [ ! -f "pkg/bin/containerd" ]; then
  echo "Warning: containerd binary not found in expected locations"
fi

# copy runc
echo "Copying runc binary..."
cp runc.amd64 pkg/containerd/bin/runc
chmod +x pkg/containerd/bin/runc

# copy cni
echo "Extracting CNI plugins..."
tar -zxf "cni-plugins-linux-amd64-v${CNI_PLUGINS_VER}.tgz" -C pkg/cni/bin || {
  echo "Failed to extract CNI plugins archive."
  exit 1
}

# Provide a default edgecore.yaml template (will be adjusted by offline installer)
cat > pkg/etc/edgecore.yaml.tmpl <<'YAML'
# minimal edgecore config template. offline_install.sh will replace the placeholders:
# __CLOUD_URL__  -> wss://cloud.example:10000/edge/<nodeID>
# __TOKEN__      -> token string
# __NODE_NAME__  -> node hostname override

modules:
  edged:
    hostnameOverride: "__NODE_NAME__"

edgeHub:
  websocket:
    url: "__CLOUD_URL__"
  token: "__TOKEN__"
YAML

# Copy offline_install.sh into the package
echo "Copying offline_install.sh..."
if [ -f "../offline_install.sh" ]; then
  cp ../offline_install.sh pkg/
  chmod +x pkg/offline_install.sh
else
  echo "Warning: offline_install.sh not found in parent directory"
fi

# Package everything
echo ""
echo "Creating offline package..."
OUTPUT_TAR="kubeedge-edge-offline-v${KUBEEDGE_VER}.tar.gz"
rm -f "$OUTPUT_TAR"

tar -zcf "$OUTPUT_TAR" -C pkg . || {
  echo "Failed to create offline package."
  exit 1
}

echo ""
echo "✓ Offline package created successfully!"
echo "  Location: $(pwd)/$OUTPUT_TAR"
echo "  Size: $(du -h "$OUTPUT_TAR" | cut -f1)"
echo ""
echo "Next steps:"
echo "  1. Transfer $OUTPUT_TAR to the edge node"
echo "  2. Extract: tar -zxf $OUTPUT_TAR"
echo "  3. Enter directory: cd kubeedge-edge-offline-v${KUBEEDGE_VER}"
echo "  4. Run: sudo ./offline_install.sh \"wss://CLOUD_IP:10000/edge/NODE_ID\" \"TOKEN\" [NODE_NAME]"
echo ""
