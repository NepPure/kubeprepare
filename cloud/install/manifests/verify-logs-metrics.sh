#!/bin/bash
set -euo pipefail

# verify-logs-metrics.sh
# 验证 KubeEdge 日志采集和资源监控功能是否正常工作

echo "============================================"
echo "  KubeEdge 日志与监控功能验证"
echo "============================================"
echo ""

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

FAILED_CHECKS=0
PASSED_CHECKS=0

# 辅助函数
check_pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((PASSED_CHECKS++))
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
    ((FAILED_CHECKS++))
}

check_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# 1. 检查 CloudCore 状态
echo "[1/8] 检查 CloudCore 状态..."
if kubectl get pods -n kubeedge -l kubeedge=cloudcore --no-headers 2>/dev/null | grep -q "Running"; then
    check_pass "CloudCore Pod 运行正常"
else
    check_fail "CloudCore Pod 未运行"
fi

# 2. 检查 CloudStream 配置
echo ""
echo "[2/8] 检查 CloudStream 配置..."
if kubectl get cm cloudcore -n kubeedge -o yaml 2>/dev/null | grep -q "enable: true" && \
   kubectl get cm cloudcore -n kubeedge -o yaml 2>/dev/null | grep -q "streamPort: 10003"; then
    check_pass "CloudStream 已启用（端口 10003）"
else
    check_warn "CloudStream 配置需要确认"
fi

# 3. 检查边缘节点状态
echo ""
echo "[3/8] 检查边缘节点状态..."
EDGE_NODES=$(kubectl get nodes -l node-role.kubernetes.io/edge='' --no-headers 2>/dev/null | wc -l)
if [[ $EDGE_NODES -gt 0 ]]; then
    check_pass "发现 $EDGE_NODES 个边缘节点"
    kubectl get nodes -l node-role.kubernetes.io/edge='' -o wide
else
    check_fail "未发现边缘节点"
fi

# 4. 检查边缘节点上的 Pod
echo ""
echo "[4/8] 检查边缘节点上的 Pod..."
EDGE_PODS=$(kubectl get pods -A -o wide 2>/dev/null | grep -E "edge-node|edgecore" | wc -l)
if [[ $EDGE_PODS -gt 0 ]]; then
    check_pass "边缘节点上有 $EDGE_PODS 个 Pod"
else
    check_warn "边缘节点上暂无 Pod（可能正常）"
fi

# 5. 测试 kubectl logs 功能
echo ""
echo "[5/8] 测试 kubectl logs 功能..."
# 找一个在边缘节点运行的 Pod
EDGE_POD=$(kubectl get pods -A -o wide 2>/dev/null | grep -E "edge-node" | head -1 | awk '{print $1 ":" $2}')
if [[ -n "$EDGE_POD" ]]; then
    NAMESPACE=$(echo "$EDGE_POD" | cut -d':' -f1)
    POD_NAME=$(echo "$EDGE_POD" | cut -d':' -f2)
    
    if timeout 10 kubectl logs "$POD_NAME" -n "$NAMESPACE" --tail=5 &>/dev/null; then
        check_pass "kubectl logs 功能正常（测试 Pod: $NAMESPACE/$POD_NAME）"
    else
        check_fail "kubectl logs 功能异常"
        echo "  提示：请检查 CloudStream 和 EdgeStream 配置"
    fi
else
    check_warn "暂无边缘 Pod 可供测试 kubectl logs"
fi

# 6. 测试 kubectl exec 功能
echo ""
echo "[6/8] 测试 kubectl exec 功能..."
if [[ -n "$EDGE_POD" ]]; then
    NAMESPACE=$(echo "$EDGE_POD" | cut -d':' -f1)
    POD_NAME=$(echo "$EDGE_POD" | cut -d':' -f2)
    
    if timeout 10 kubectl exec "$POD_NAME" -n "$NAMESPACE" -- echo "test" &>/dev/null; then
        check_pass "kubectl exec 功能正常（测试 Pod: $NAMESPACE/$POD_NAME）"
    else
        check_fail "kubectl exec 功能异常"
        echo "  提示：请检查 CloudStream 和 EdgeStream 配置"
    fi
else
    check_warn "暂无边缘 Pod 可供测试 kubectl exec"
fi

# 7. 检查 Metrics Server 状态
echo ""
echo "[7/8] 检查 Metrics Server 状态..."
if kubectl get deployment metrics-server -n kube-system &>/dev/null; then
    METRICS_READY=$(kubectl get deployment metrics-server -n kube-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "$METRICS_READY" -gt 0 ]]; then
        check_pass "Metrics Server 运行正常"
    else
        check_fail "Metrics Server Pod 未就绪"
    fi
else
    check_fail "Metrics Server 未部署"
fi

# 8. 测试 kubectl top 功能
echo ""
echo "[8/8] 测试 kubectl top 功能..."

# 测试 kubectl top node
if timeout 15 kubectl top node &>/dev/null; then
    check_pass "kubectl top node 功能正常"
    echo ""
    kubectl top node
else
    check_fail "kubectl top node 功能异常"
    echo "  提示：请检查 iptables 规则和 Metrics Server 配置"
fi

echo ""

# 测试 kubectl top pod（仅当有边缘 Pod 时）
if [[ $EDGE_PODS -gt 0 ]]; then
    if timeout 15 kubectl top pod -A --no-headers 2>/dev/null | grep -q .; then
        check_pass "kubectl top pod 功能正常"
    else
        check_warn "kubectl top pod 暂无数据（可能正在收集中）"
    fi
fi

# 9. 检查 iptables 规则
echo ""
echo "[9/8] 检查 iptables 规则..."
if sudo iptables -t nat -L OUTPUT -n 2>/dev/null | grep -q "10350"; then
    check_pass "iptables NAT 规则已配置"
    echo ""
    echo "当前规则："
    sudo iptables -t nat -L OUTPUT -n --line-numbers | grep -A 2 "10350" || true
else
    check_fail "iptables NAT 规则未配置"
    echo "  提示：运行 'sudo bash manifests/iptables-metrics-setup.sh <CLOUDCORE_IP>'"
fi

# 总结
echo ""
echo "============================================"
echo "  验证结果汇总"
echo "============================================"
echo -e "通过检查: ${GREEN}$PASSED_CHECKS${NC}"
echo -e "失败检查: ${RED}$FAILED_CHECKS${NC}"
echo ""

if [[ $FAILED_CHECKS -eq 0 ]]; then
    echo -e "${GREEN}✓ 所有功能验证通过！${NC}"
    echo ""
    echo "您现在可以："
    echo "  • 使用 'kubectl logs <pod-name>' 查看边缘 Pod 日志"
    echo "  • 使用 'kubectl exec <pod-name> -- <command>' 在边缘 Pod 中执行命令"
    echo "  • 使用 'kubectl top node' 查看节点资源使用情况"
    echo "  • 使用 'kubectl top pod -A' 查看 Pod 资源使用情况"
    exit 0
else
    echo -e "${RED}✗ 部分功能验证失败${NC}"
    echo ""
    echo "故障排查建议："
    echo ""
    echo "1. kubectl logs/exec 失败："
    echo "   - 检查 CloudCore CloudStream 配置（应默认启用）"
    echo "   - 检查边缘节点 EdgeStream 配置："
    echo "     ssh <edge-node> 'grep -A 10 edgeStream /etc/kubeedge/config/edgecore.yaml'"
    echo "   - 确认 EdgeStream 端口 10004 可访问"
    echo ""
    echo "2. kubectl top 失败："
    echo "   - 检查 iptables 规则："
    echo "     sudo iptables -t nat -L OUTPUT -n | grep 10350"
    echo "   - 检查 Metrics Server 日志："
    echo "     kubectl logs -n kube-system -l k8s-app=metrics-server"
    echo "   - 确认 CloudCore 10003 端口可访问"
    echo ""
    echo "3. 重新配置："
    echo "   - 云端: sudo bash manifests/iptables-metrics-setup.sh <CLOUDCORE_IP>"
    echo "   - 边缘: 在边缘节点安装脚本中会自动配置 EdgeStream"
    echo ""
    exit 1
fi
