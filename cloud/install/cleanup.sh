#!/usr/bin/env bash
set -euo pipefail

# KubeEdge Cloud 清理脚本
# 用途：清理 K3s 和 CloudCore 组件
# 说明：移除 K3s、CloudCore 和相关配置

if [ "$EUID" -ne 0 ]; then
  echo "错误：请使用 root 或 sudo 运行此脚本"
  exit 1
fi

echo "=========================================="
echo "=== KubeEdge Cloud 清理脚本 ==="
echo "=========================================="
echo ""

HAS_DOCKER=false

# 检查 Docker
if systemctl list-units --full -all 2>/dev/null | grep -q "docker.service" || command -v docker &> /dev/null; then
  HAS_DOCKER=true
fi

echo "检测到的组件："
echo "  - K3s (云端)"
echo "  - CloudCore"
[ "$HAS_DOCKER" = true ] && echo "  - Docker (系统安装)"

# 如果检测到 Docker，警告用户
if [ "$HAS_DOCKER" = true ]; then
  echo ""
  echo "⚠️  警告: 检测到系统已安装 Docker"
  echo "   Docker 依赖 containerd，清理 K3s 可能不会影响 Docker"
  echo "   但如果您想完全卸载 Docker，请手动执行："
  echo "   - apt-get remove docker-ce docker-ce-cli docker.io"
  echo "   - systemctl stop docker && systemctl disable docker"
  echo ""
fi

echo ""
read -p "确认清理 K3s 和 CloudCore？(y/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "❌ 用户取消清理"
  exit 0
fi

echo ""
echo "[云端] 开始清理 K3s 和 CloudCore..."
echo ""

# 1. 运行 K3s 卸载脚本
echo "[1/9] 运行 K3s 卸载脚本..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
  /usr/local/bin/k3s-uninstall.sh || true
  echo "  ✓ K3s 卸载脚本已执行"
elif [ -f "$SCRIPT_DIR/../../k3s-uninstall.sh" ]; then
  "$SCRIPT_DIR/../../k3s-uninstall.sh" || true
  echo "  ✓ K3s 卸载脚本已执行（使用项目脚本）"
else
  echo "  - K3s 卸载脚本不存在，手动清理"
fi

# 2. 停止 K3s 服务
echo "[2/9] 停止 K3s 服务..."
systemctl stop k3s 2>/dev/null || true

# 强制杀死所有 k3s 和 containerd 进程
CONTAINERD_PIDS=$(ps -e -o pid= -o comm= | awk '{print $1, $2}' | grep -E 'k3s|containerd' | awk '{print $1}')
if [ -n "$CONTAINERD_PIDS" ]; then
  kill -9 $CONTAINERD_PIDS 2>/dev/null || true
fi
sleep 1
echo "  ✓ K3s 服务已停止"

systemctl disable k3s 2>/dev/null || true
echo "  ✓ K3s 服务已禁用"

# 3. 杀死残留进程
echo "[3/9] 杀死残留进程..."
pkill -9 k3s || true
pkill -9 containerd || true
pkill -9 containerd-shim || true
sleep 2
echo "  ✓ 进程已清理"

# 4. 卸载挂载点
echo "[4/9] 卸载k3s挂载点..."
for mount in $(mount | grep '/run/k3s\|/var/lib/rancher/k3s\|/var/lib/kubelet' | cut -d ' ' -f 3); do
  umount "$mount" 2>/dev/null || true
done
echo "  ✓ 挂载点已卸载"

# 5. 删除 K3s 文件
echo "[5/9] 删除 K3s 相关文件..."
rm -f /usr/local/bin/k3s
rm -f /usr/local/bin/kubectl
rm -f /usr/local/bin/crictl
rm -f /usr/local/bin/ctr
rm -f /usr/local/bin/k3s-killall.sh
rm -f /usr/local/bin/k3s-uninstall.sh
echo "  ✓ K3s 二进制文件已删除"

# 6. 删除 K3s 数据目录
echo "[6/9] 删除 K3s 数据目录..."
rm -rf /var/lib/rancher/k3s
rm -rf /etc/rancher
rm -rf /run/k3s
echo "  ✓ K3s 数据已删除"

# 7. 清理 CloudCore
echo "[7/9] 清理 CloudCore..."
rm -f /usr/local/bin/cloudcore
rm -f /usr/local/bin/keadm
rm -rf /etc/kubeedge
rm -rf /var/lib/kubeedge
echo "  ✓ CloudCore 已删除"

# 8. 清理网络接口
echo "[8/9] 清理网络接口..."
ip link delete cni0 2>/dev/null || true
ip link delete flannel.1 2>/dev/null || true
ip link delete kube-bridge 2>/dev/null || true
echo "  ✓ 网络接口已清理"

# 9. 清理 iptables 规则
echo "[9/9] 清理 iptables 规则..."
iptables -t nat -F 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -F 2>/dev/null || true
iptables -X 2>/dev/null || true
echo "  ✓ iptables 规则已清理"

echo ""
echo "✓ 云端清理完成！"
echo ""

# 通用清理
echo "[通用] 执行通用清理..."
systemctl daemon-reload
echo "  ✓ systemd 已重载"

rm -f /var/log/kubeedge-*.log
echo "  ✓ 日志文件已清理"

echo ""
echo "=========================================="
echo "✓✓✓ 清理完成！系统已重置 ✓✓✓"
echo "=========================================="
echo ""
echo "现在可以重新安装云端："
echo "  cd /data && sudo ./install.sh <对外IP> [节点名称]"
echo ""
echo "提示：如需完全重启系统，建议执行："
echo "  sudo reboot"
