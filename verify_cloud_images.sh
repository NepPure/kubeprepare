#!/bin/bash
# 验证cloud离线包是否包含所有必需镜像

set -e

PACKAGE_FILE="$1"

if [ -z "$PACKAGE_FILE" ]; then
    echo "用法: $0 <cloud离线包路径>"
    echo "示例: $0 kubeedge-cloud-1.22.0-k3s-v1.34.2+k3s1-amd64.tar.gz"
    exit 1
fi

if [ ! -f "$PACKAGE_FILE" ]; then
    echo "错误: 文件不存在: $PACKAGE_FILE"
    exit 1
fi

echo "=== 验证Cloud离线包镜像完整性 ==="
echo "包文件: $PACKAGE_FILE"
echo ""

# 定义必需的KubeEdge镜像
REQUIRED_KUBEEDGE_IMAGES=(
    "docker.io-kubeedge-cloudcore-v1.22.0.tar"
    "docker.io-kubeedge-iptables-manager-v1.22.0.tar"
    "docker.io-kubeedge-controller-manager-v1.22.0.tar"
    "docker.io-kubeedge-admission-v1.22.0.tar"
)

# 定义必需的K3s镜像
REQUIRED_K3S_IMAGES=(
    "docker.io-rancher-klipper-helm-v0.9.10-build20251111.tar"
    "docker.io-rancher-klipper-lb-v0.4.13.tar"
    "docker.io-rancher-local-path-provisioner-v0.0.32.tar"
    "docker.io-rancher-mirrored-coredns-coredns-1.13.1.tar"
    "docker.io-rancher-mirrored-library-busybox-1.36.1.tar"
    "docker.io-rancher-mirrored-library-traefik-3.5.1.tar"
    "docker.io-rancher-mirrored-metrics-server-v0.8.0.tar"
    "docker.io-rancher-mirrored-pause-3.6.tar"
)

# 列出包中的镜像文件
echo "[1/4] 列出包中的镜像文件..."
IMAGES_IN_PACKAGE=$(tar -tzf "$PACKAGE_FILE" | grep "^images/.*\.tar$" | sed 's|^images/||')
IMAGE_COUNT=$(echo "$IMAGES_IN_PACKAGE" | grep -c "\.tar$" || echo "0")
echo "✓ 发现 $IMAGE_COUNT 个镜像文件"
echo ""

# 检查KubeEdge镜像
echo "[2/4] 检查KubeEdge组件镜像..."
KUBEEDGE_MISSING=0
for image in "${REQUIRED_KUBEEDGE_IMAGES[@]}"; do
    if echo "$IMAGES_IN_PACKAGE" | grep -q "^$image\$"; then
        echo "  ✓ $image"
    else
        echo "  ✗ 缺失: $image"
        KUBEEDGE_MISSING=$((KUBEEDGE_MISSING + 1))
    fi
done

if [ $KUBEEDGE_MISSING -eq 0 ]; then
    echo "✓ 所有KubeEdge镜像完整 (4/4)"
else
    echo "✗ 缺失 $KUBEEDGE_MISSING 个KubeEdge镜像"
fi
echo ""

# 检查K3s镜像
echo "[3/4] 检查K3s系统镜像..."
K3S_MISSING=0
for image in "${REQUIRED_K3S_IMAGES[@]}"; do
    if echo "$IMAGES_IN_PACKAGE" | grep -q "^$image\$"; then
        echo "  ✓ $image"
    else
        echo "  ✗ 缺失: $image"
        K3S_MISSING=$((K3S_MISSING + 1))
    fi
done

if [ $K3S_MISSING -eq 0 ]; then
    echo "✓ 所有K3s镜像完整 (8/8)"
else
    echo "✗ 缺失 $K3S_MISSING 个K3s镜像"
fi
echo ""

# 检查其他必需文件
echo "[4/4] 检查其他必需文件..."
REQUIRED_FILES=(
    "k3s-amd64"
    "cloudcore"
    "keadm"
    "install.sh"
    "config/kubeedge/cloudcore-config.yaml"
)

FILES_MISSING=0
for file in "${REQUIRED_FILES[@]}"; do
    # 处理可能的架构变体
    if [[ "$file" == "k3s-amd64" ]]; then
        if tar -tzf "$PACKAGE_FILE" | grep -q "k3s-\(amd64\|arm64\)"; then
            echo "  ✓ k3s 二进制文件"
            continue
        fi
    fi
    
    if tar -tzf "$PACKAGE_FILE" | grep -q "^$file\$"; then
        echo "  ✓ $file"
    else
        echo "  ✗ 缺失: $file"
        FILES_MISSING=$((FILES_MISSING + 1))
    fi
done

if [ $FILES_MISSING -eq 0 ]; then
    echo "✓ 所有必需文件完整"
else
    echo "✗ 缺失 $FILES_MISSING 个必需文件"
fi
echo ""

# 总结
echo "=== 验证总结 ==="
TOTAL_MISSING=$((KUBEEDGE_MISSING + K3S_MISSING + FILES_MISSING))

if [ $TOTAL_MISSING -eq 0 ]; then
    echo "✅ 验证通过！离线包完整，可用于完全离线安装。"
    echo ""
    echo "包含内容:"
    echo "  - KubeEdge组件镜像: 4个"
    echo "  - K3s系统镜像: 8个"
    echo "  - 二进制文件和配置: 完整"
    echo ""
    echo "此包支持在无网络环境下部署KubeEdge CloudCore。"
    exit 0
else
    echo "❌ 验证失败！离线包不完整，缺失 $TOTAL_MISSING 项内容。"
    echo ""
    echo "问题详情:"
    [ $KUBEEDGE_MISSING -gt 0 ] && echo "  - 缺失 $KUBEEDGE_MISSING 个KubeEdge镜像"
    [ $K3S_MISSING -gt 0 ] && echo "  - 缺失 $K3S_MISSING 个K3s镜像"
    [ $FILES_MISSING -gt 0 ] && echo "  - 缺失 $FILES_MISSING 个必需文件"
    echo ""
    echo "此包无法用于完全离线安装，请重新构建。"
    exit 1
fi
