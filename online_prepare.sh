#!/usr/bin/env bash
set -euo pipefail

# Usage: ./online_prepare.sh [output_dir]
# Example: ./online_prepare.sh /tmp/kubeedge-offline

OUTDIR=${1:-"./kubeedge-offline"}
KUBEEDGE_VER="v1.22.0"
CONTAINERD_VER="v1.6.20"
CNI_PLUGINS_VER="v1.4.0"
RUNC_VER="v1.1.9"

mkdir -p "$OUTDIR"
cd "$OUTDIR"

echo "Preparing offline package in: $OUTDIR"

# 1) Download kubeedge
if [ ! -f "kubeedge-${KUBEEDGE_VER}-linux-amd64.tar.gz" ]; then
  echo "Downloading KubeEdge ${KUBEEDGE_VER}..."
  wget -q --show-progress "https://github.com/kubeedge/kubeedge/releases/download/${KUBEEDGE_VER}/kubeedge-${KUBEEDGE_VER}-linux-amd64.tar.gz"
fi

# 2) Download containerd
if [ ! -f "containerd-${CONTAINERD_VER}-linux-amd64.tar.gz" ]; then
  echo "Downloading containerd ${CONTAINERD_VER}..."
  wget -q --show-progress "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VER}/containerd-${CONTAINERD_VER}-linux-amd64.tar.gz"
fi

# 3) Download runc
if [ ! -f "runc.amd64" ]; then
  echo "Downloading runc ${RUNC_VER}..."
  wget -q --show-progress -O runc.amd64 "https://github.com/opencontainers/runc/releases/download/v${RUNC_VER}/runc.amd64"
  chmod +x runc.amd64
fi

# 4) Download CNI plugins
if [ ! -f "cni-plugins-linux-amd64-v${CNI_PLUGINS_VER}.tgz" ]; then
  echo "Downloading CNI plugins ${CNI_PLUGINS_VER}..."
  wget -q --show-progress "https://github.com/containernetworking/plugins/releases/download/v${CNI_PLUGINS_VER}/cni-plugins-linux-amd64-v${CNI_PLUGINS_VER}.tgz"
fi

# 5) Extract edgecore binary
if [ ! -d "kubeedge" ]; then
  tar -zxf "kubeedge-${KUBEEDGE_VER}-linux-amd64.tar.gz"
fi

mkdir -p pkg/bin pkg/containerd pkg/cni pkg/etc

# Copy edgecore
cp kubeedge/edge/edgecore pkg/bin/
chmod +x pkg/bin/edgecore

# Copy containerd bins
mkdir -p pkg/containerd/bin
tar -zxf "containerd-${CONTAINERD_VER}-linux-amd64.tar.gz" -C pkg/containerd
# containerd tar usually has bin/*

# copy runc
cp runc.amd64 pkg/containerd/bin/runc
chmod +x pkg/containerd/bin/runc

# copy cni
mkdir -p pkg/cni/bin
tar -zxf "cni-plugins-linux-amd64-v${CNI_PLUGINS_VER}.tgz" -C pkg/cni/bin

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

# Make a small install helper script stub for offline side
cat > pkg/install_helper.sh <<'HELP'
#!/usr/bin/env bash
set -euo pipefail
# This helper will be executed on the edge node by offline_install.sh
HELP
chmod +x pkg/install_helper.sh

# Package everything
OUTPUT_TAR="kubeedge-edge-offline-${KUBEEDGE_VER}.tar.gz"
rm -f "$OUTPUT_TAR"

tar -zcf "$OUTPUT_TAR" -C pkg .

echo "Created offline package: $(pwd)/$OUTPUT_TAR"

echo "Done. 请将 $OUTPUT_TAR 传到边缘机并运行 offline_install.sh（见下）。"
