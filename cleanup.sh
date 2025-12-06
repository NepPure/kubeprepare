#!/usr/bin/env bash
set -euo pipefail

# KubeEdge 组件清理脚本
# 用途：在重新安装前清理所有 KubeEdge 组件
# 说明：移除：edgecore、containerd、runc、CNI 插件 和 相关配置

if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 或 sudo 运行此脚本"
  exit 1
fi

echo "=== 正在清理 KubeEdge 组件 ==="

# 1) 停止并禁用 edgecore 服务
echo "停止 edgecore 服务..."
if systemctl is-active --quiet edgecore; then
  systemctl stop edgecore || true
fi
systemctl disable edgecore || true
rm -f /etc/systemd/system/edgecore.service
systemctl daemon-reload || true

# 2) 停止并禁用 containerd 服务
echo "停止 containerd 服务..."
if systemctl is-active --quiet containerd; then
  systemctl stop containerd || true
fi
systemctl disable containerd || true
rm -f /etc/systemd/system/containerd.service

# 3) 删除二进制文件
echo "删除二进制文件..."
rm -f /usr/local/bin/edgecore
rm -f /usr/local/bin/containerd
rm -f /usr/local/bin/containerd-shim
rm -f /usr/local/bin/containerd-shim-runc-v2
rm -f /usr/local/bin/ctr
rm -f /usr/local/bin/runc

# 4) 删除 CNI 插件
echo "删除 CNI 插件..."
rm -rf /opt/cni/bin/*

# 5) 删除配置文件
echo "删除配置文件..."
rm -rf /etc/kubeedge
rm -f /etc/containerd/config.toml

# 6) 删除数据目录 (可选 - 如需保留数据可注释此部分)
echo "删除数据目录..."
rm -rf /var/lib/kubeedge
rm -rf /var/lib/containerd
rm -rf /run/containerd

echo ""
echo "✓ 清理完成！"
echo ""
echo "现在可以重新运行安装脚本："
echo "  云端安装: sudo bash cloud/install/install.sh --package <package> --cloud-ip <ip>"
echo "  边缘端安装: sudo bash edge/install/install.sh --package <package> --cloud-url <url> --token <token> --node-name <name>"
echo ""
