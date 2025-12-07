#!/bin/bash
set -euo pipefail

# iptables-metrics-setup.sh
# 配置 iptables 规则，将 Metrics Server 的请求转发到 CloudCore Stream 端口
# 这使得 Metrics Server 可以通过 CloudStream 隧道访问边缘节点的 kubelet

CLOUDCORE_IP="${1:-}"

if [[ -z "$CLOUDCORE_IP" ]]; then
    echo "错误：必须提供 CloudCore IP 地址"
    echo "用法: $0 <CLOUDCORE_IP>"
    exit 1
fi

echo "============================================"
echo "  配置 Metrics Server iptables 规则"
echo "============================================"

# 检查 iptables 是否可用
if ! command -v iptables &> /dev/null; then
    echo "错误：iptables 未安装"
    exit 1
fi

echo "[1/4] 检查现有规则..."
# 检查规则是否已存在
if iptables -t nat -L OUTPUT -n | grep -q "10350.*$CLOUDCORE_IP:10003"; then
    echo "  ⚠ 规则已存在，跳过添加"
else
    echo "[2/4] 添加 NAT 规则..."
    # 添加 NAT 规则：将发往端口 10350 的流量转发到 CloudCore 的 10003 端口（CloudStream）
    iptables -t nat -A OUTPUT -p tcp --dport 10350 -j DNAT --to "$CLOUDCORE_IP:10003" || {
        echo "错误：无法添加 iptables 规则"
        exit 1
    }
    echo "  ✓ NAT 规则添加成功"
fi

echo "[3/4] 验证规则..."
if iptables -t nat -L OUTPUT -n | grep -q "10350"; then
    echo "  ✓ 规则验证成功"
    echo ""
    echo "当前 NAT OUTPUT 规则："
    iptables -t nat -L OUTPUT -n --line-numbers | grep -A 2 "10350" || true
else
    echo "错误：规则验证失败"
    exit 1
fi

echo ""
echo "[4/4] 持久化规则..."
# 持久化 iptables 规则
if command -v iptables-save &> /dev/null; then
    iptables-save > /etc/iptables.rules || {
        echo "警告：无法保存 iptables 规则到 /etc/iptables.rules"
    }
    echo "  ✓ 规则已保存到 /etc/iptables.rules"
    
    # 创建恢复脚本
    cat > /etc/network/if-pre-up.d/iptables <<'EOF'
#!/bin/sh
if [ -f /etc/iptables.rules ]; then
    iptables-restore < /etc/iptables.rules
fi
EOF
    chmod +x /etc/network/if-pre-up.d/iptables 2>/dev/null || true
    echo "  ✓ 已创建自动恢复脚本"
fi

echo ""
echo "============================================"
echo "  ✓ Metrics Server iptables 配置完成"
echo "============================================"
echo ""
echo "规则说明："
echo "  - 目标端口: 10350 (Metrics Server → Kubelet)"
echo "  - 转发到: $CLOUDCORE_IP:10003 (CloudCore Stream)"
echo "  - 协议: TCP"
echo ""
echo "测试方法："
echo "  1. 部署 Metrics Server: kubectl apply -f manifests/metrics-server.yaml"
echo "  2. 等待 Pod 运行: kubectl wait --for=condition=ready pod -l k8s-app=metrics-server -n kube-system --timeout=300s"
echo "  3. 查看节点指标: kubectl top node"
echo "  4. 查看 Pod 指标: kubectl top pod -A"
echo ""
