#!/usr/bin/env bash
set -euo pipefail


# 1. 获取所有 node 的 InternalIP（使用 k3s kubectl）
KUBECTL="/usr/local/bin/k3s kubectl"
NODE_IPS=$($KUBECTL get node -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address} {end}')

if [ -z "$NODE_IPS" ]; then
  echo "未获取到任何节点IP，退出。"
  exit 1
fi

echo "所有节点IP: $NODE_IPS"



# 2. 调用 certgen.sh 的 stream 命令（与本脚本同目录）并更新 cloudcore Secret
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CERTGEN_SCRIPT="$SCRIPT_DIR/certgen.sh"
if [ ! -f "$CERTGEN_SCRIPT" ]; then
  echo "未找到 certgen.sh: $CERTGEN_SCRIPT"
  exit 1
fi

export CLOUDCOREIPS="$NODE_IPS"
export K8SCA_FILE="/var/lib/rancher/k3s/server/tls/server-ca.crt"
export K8SCA_KEY_FILE="/var/lib/rancher/k3s/server/tls/server-ca.key"
chmod +x "$CERTGEN_SCRIPT"
"$CERTGEN_SCRIPT" stream

# 2.5. 用新证书内容更新 cloudcore Secret
echo "更新 cloudcore Secret..."
$KUBECTL -n kubeedge create secret generic cloudcore \
  --from-file=stream.crt=/etc/kubeedge/certs/stream.crt \
  --from-file=stream.key=/etc/kubeedge/certs/stream.key \
  --from-file=streamCA.crt=/etc/kubeedge/ca/streamCA.crt \
  --dry-run=client -o yaml | $KUBECTL apply -f -
echo "cloudcore Secret 已更新"




# 3. 完全停止再重启 cloudcore Deployment
echo "将 cloudcore deployment scale 到 0..."
$KUBECTL -n kubeedge scale deployment/cloudcore --replicas=0
echo "等待端口彻底释放..."
sleep 8
echo "将 cloudcore deployment scale 回 1..."
$KUBECTL -n kubeedge scale deployment/cloudcore --replicas=1
echo "cloudcore Deployment 已重启"
