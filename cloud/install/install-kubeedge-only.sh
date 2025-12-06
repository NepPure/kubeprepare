#!/bin/bash
set -e

###############################################################################
# KubeEdge 云端组件独立安装脚本
# 
# 功能：
# - 自动探测已有的 K3s 或 K8s 集群
# - 加载 KubeEdge 相关容器镜像
# - 安装 KubeEdge CloudCore 组件
# - 配置 KubeEdge 云端服务
#
# 适用场景：
# - 宿主机已经安装了 K3s 或 K8s
# - 只需要在现有集群上添加 KubeEdge 云端功能
#
# 使用方法：
#   sudo ./install-kubeedge-only.sh [选项]
#
# 选项：
#   --advertise-address <IP>  指定 CloudCore 对外广播的 IP 地址（默认：自动探测）
#   --cloudcore-version <版本> 指定 KubeEdge 版本（默认：从包中探测）
#   --skip-images            跳过镜像加载（如果镜像已存在）
#   --dry-run                仅显示将要执行的操作，不实际安装
#   --help                   显示帮助信息
###############################################################################

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 默认配置
SKIP_IMAGES=false
DRY_RUN=false
ADVERTISE_ADDRESS=""
CLOUDCORE_VERSION=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(dirname "$SCRIPT_DIR")"

###############################################################################
# 工具函数
###############################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

show_help() {
    cat << EOF
KubeEdge 云端组件独立安装脚本

使用方法：
    sudo $0 [选项]

选项：
    --advertise-address <IP>   指定 CloudCore 对外广播的 IP 地址（默认：自动探测）
    --cloudcore-version <版本>  指定 KubeEdge 版本（默认：从包中探测）
    --skip-images              跳过镜像加载（如果镜像已存在）
    --dry-run                  仅显示将要执行的操作，不实际安装
    --help                     显示此帮助信息

示例：
    # 自动探测并安装
    sudo $0

    # 指定对外 IP 地址
    sudo $0 --advertise-address 192.168.1.100

    # 跳过镜像加载（镜像已存在）
    sudo $0 --skip-images

    # 预览安装步骤
    sudo $0 --dry-run

EOF
    exit 0
}

###############################################################################
# 参数解析
###############################################################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --advertise-address)
                ADVERTISE_ADDRESS="$2"
                shift 2
                ;;
            --cloudcore-version)
                CLOUDCORE_VERSION="$2"
                shift 2
                ;;
            --skip-images)
                SKIP_IMAGES=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help|-h)
                show_help
                ;;
            *)
                log_error "未知参数: $1"
                show_help
                ;;
        esac
    done
}

###############################################################################
# 环境检查函数
###############################################################################

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行"
        log_info "请使用: sudo $0"
        exit 1
    fi
}

detect_kubernetes() {
    log_info "探测 Kubernetes 集群..."
    
    local k8s_type=""
    local kubeconfig=""
    local kubectl_cmd=""
    
    # 检查 K3s
    if command -v k3s &> /dev/null; then
        k8s_type="k3s"
        kubeconfig="/etc/rancher/k3s/k3s.yaml"
        kubectl_cmd="k3s kubectl"
        log_success "检测到 K3s 集群"
    # 检查 Kubernetes
    elif command -v kubectl &> /dev/null; then
        k8s_type="k8s"
        if [[ -f /etc/kubernetes/admin.conf ]]; then
            kubeconfig="/etc/kubernetes/admin.conf"
        elif [[ -f ~/.kube/config ]]; then
            kubeconfig="~/.kube/config"
        fi
        kubectl_cmd="kubectl"
        log_success "检测到 Kubernetes 集群"
    else
        log_error "未检测到 K3s 或 Kubernetes 集群"
        log_info "请先安装 K3s 或 Kubernetes，或使用完整安装脚本"
        exit 1
    fi
    
    # 验证集群是否可用
    if ! $kubectl_cmd get nodes &> /dev/null; then
        log_error "Kubernetes 集群无法访问或未正常运行"
        log_info "请检查集群状态: $kubectl_cmd get nodes"
        exit 1
    fi
    
    # 显示集群信息
    local node_count=$($kubectl_cmd get nodes --no-headers 2>/dev/null | wc -l)
    local version=$($kubectl_cmd version --short 2>/dev/null | grep -i server | awk '{print $3}')
    
    log_info "集群类型: $k8s_type"
    log_info "集群版本: $version"
    log_info "节点数量: $node_count"
    log_info "kubeconfig: $kubeconfig"
    
    # 导出环境变量供后续使用
    export K8S_TYPE="$k8s_type"
    export KUBECONFIG="$kubeconfig"
    export KUBECTL_CMD="$kubectl_cmd"
    
    return 0
}

detect_container_runtime() {
    log_info "探测容器运行时..."
    
    local runtime=""
    
    if command -v ctr &> /dev/null; then
        runtime="containerd"
        log_success "检测到 containerd"
    elif command -v docker &> /dev/null; then
        runtime="docker"
        log_success "检测到 Docker"
    else
        log_warn "未检测到 containerd 或 Docker"
        log_info "将使用 ctr 命令（由 K3s/K8s 提供）"
        runtime="ctr"
    fi
    
    export CONTAINER_RUNTIME="$runtime"
    return 0
}

detect_advertise_address() {
    if [[ -n "$ADVERTISE_ADDRESS" ]]; then
        log_info "使用指定的广播地址: $ADVERTISE_ADDRESS"
        return 0
    fi
    
    log_info "自动探测主机 IP 地址..."
    
    # 尝试获取默认路由的 IP
    local ip=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+')
    
    if [[ -z "$ip" ]]; then
        # 备用方案：获取第一个非 lo 网卡的 IP
        ip=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n1)
    fi
    
    if [[ -z "$ip" ]]; then
        log_error "无法自动探测 IP 地址"
        log_info "请使用 --advertise-address 参数手动指定"
        exit 1
    fi
    
    ADVERTISE_ADDRESS="$ip"
    log_success "探测到主机 IP: $ADVERTISE_ADDRESS"
}

detect_kubeedge_version() {
    if [[ -n "$CLOUDCORE_VERSION" ]]; then
        log_info "使用指定的 KubeEdge 版本: $CLOUDCORE_VERSION"
        return 0
    fi
    
    # 从 cloudcore 二进制文件探测版本
    if [[ -f "$PACKAGE_ROOT/cloudcore" ]]; then
        CLOUDCORE_VERSION=$("$PACKAGE_ROOT/cloudcore" version 2>/dev/null | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    fi
    
    # 从 meta/version.txt 读取版本
    if [[ -z "$CLOUDCORE_VERSION" && -f "$PACKAGE_ROOT/meta/version.txt" ]]; then
        CLOUDCORE_VERSION=$(grep -oP 'kubeedge_version=\K.*' "$PACKAGE_ROOT/meta/version.txt")
    fi
    
    # 默认版本
    if [[ -z "$CLOUDCORE_VERSION" ]]; then
        CLOUDCORE_VERSION="1.22.0"
        log_warn "无法探测版本，使用默认版本: $CLOUDCORE_VERSION"
    else
        log_info "探测到 KubeEdge 版本: $CLOUDCORE_VERSION"
    fi
}

###############################################################################
# 安装函数
###############################################################################

load_images() {
    if [[ "$SKIP_IMAGES" == "true" ]]; then
        log_info "跳过镜像加载（--skip-images）"
        return 0
    fi
    
    local images_dir="$PACKAGE_ROOT/images"
    
    if [[ ! -d "$images_dir" ]]; then
        log_warn "镜像目录不存在: $images_dir"
        log_info "将跳过镜像加载"
        return 0
    fi
    
    local image_count=$(find "$images_dir" -name "*.tar" | wc -l)
    
    if [[ $image_count -eq 0 ]]; then
        log_warn "未找到任何镜像文件"
        return 0
    fi
    
    log_info "开始加载 KubeEdge 相关镜像 (共 $image_count 个)..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将加载以下镜像:"
        find "$images_dir" -name "*.tar" -exec basename {} \;
        return 0
    fi
    
    local loaded=0
    local failed=0
    
    for image_tar in "$images_dir"/*.tar; do
        [[ -f "$image_tar" ]] || continue
        
        local image_name=$(basename "$image_tar" .tar)
        echo -n "  加载镜像: $image_name ... "
        
        case "$CONTAINER_RUNTIME" in
            docker)
                if docker load -i "$image_tar" &> /dev/null; then
                    echo -e "${GREEN}✓${NC}"
                    ((loaded++))
                else
                    echo -e "${RED}✗${NC}"
                    ((failed++))
                fi
                ;;
            containerd|ctr)
                # K3s 使用 k3s ctr，K8s 使用 ctr
                local ctr_cmd="ctr"
                if [[ "$K8S_TYPE" == "k3s" ]]; then
                    ctr_cmd="k3s ctr"
                fi
                
                if $ctr_cmd images import "$image_tar" &> /dev/null; then
                    echo -e "${GREEN}✓${NC}"
                    ((loaded++))
                else
                    echo -e "${RED}✗${NC}"
                    ((failed++))
                fi
                ;;
        esac
    done
    
    log_success "镜像加载完成: 成功 $loaded 个, 失败 $failed 个"
}

install_cloudcore_binary() {
    log_info "安装 CloudCore 二进制文件..."
    
    if [[ ! -f "$PACKAGE_ROOT/cloudcore" ]]; then
        log_error "找不到 cloudcore 二进制文件: $PACKAGE_ROOT/cloudcore"
        exit 1
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将复制 cloudcore 到 /usr/local/bin/"
        return 0
    fi
    
    cp "$PACKAGE_ROOT/cloudcore" /usr/local/bin/
    chmod +x /usr/local/bin/cloudcore
    
    log_success "CloudCore 二进制文件已安装到 /usr/local/bin/cloudcore"
}

install_keadm_binary() {
    log_info "安装 keadm 工具..."
    
    if [[ ! -f "$PACKAGE_ROOT/keadm" ]]; then
        log_warn "找不到 keadm 二进制文件，跳过"
        return 0
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将复制 keadm 到 /usr/local/bin/"
        return 0
    fi
    
    cp "$PACKAGE_ROOT/keadm" /usr/local/bin/
    chmod +x /usr/local/bin/keadm
    
    log_success "keadm 工具已安装到 /usr/local/bin/keadm"
}

generate_cloudcore_config() {
    log_info "生成 CloudCore 配置文件..."
    
    local config_dir="/etc/kubeedge"
    local config_file="$config_dir/cloudcore.yaml"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将在 $config_file 创建配置文件"
        return 0
    fi
    
    mkdir -p "$config_dir"
    
    # 在脚本内生成完整配置
    cat > "$config_file" << EOF
apiVersion: cloudcore.config.kubeedge.io/v1alpha2
kind: CloudCore
kubeAPIConfig:
  kubeConfig: "$KUBECONFIG"
  master: ""
  contentType: application/vnd.kubernetes.protobuf
  qps: 100
  burst: 200
databases:
  redis:
    enable: false
cloudHub:
  advertiseAddress:
    - $ADVERTISE_ADDRESS
  tlsCAFile: /etc/kubeedge/ca/rootCA.crt
  tlsCertFile: /etc/kubeedge/certs/server.crt
  tlsPrivateKeyFile: /etc/kubeedge/certs/server.key
  listenAddr: 0.0.0.0
  port: 10000
  protocol: websocket
  nodeLimit: 1000
cloudStream:
  enable: true
  streamPort: 10003
  tlsStreamCAFile: /etc/kubeedge/ca/rootCA.crt
  tlsStreamCertFile: /etc/kubeedge/certs/stream.crt
  tlsStreamPrivateKeyFile: /etc/kubeedge/certs/stream.key
  tlsEnable: true
authentication:
  address: 127.0.0.1:10003
modules:
  cloudHub:
    enable: true
  edgeController:
    enable: true
  deviceController:
    enable: true
    nodeStatusUpdateFrequency: 10
EOF
    
    log_success "CloudCore 配置文件已创建: $config_file"
}

init_cloudcore() {
    log_info "初始化 CloudCore（生成证书和 CRD）..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将执行: keadm init --kube-config=$KUBECONFIG --advertise-address=$ADVERTISE_ADDRESS"
        return 0
    fi
    
    # 使用 keadm 初始化
    if command -v keadm &> /dev/null; then
        keadm init \
            --kube-config="$KUBECONFIG" \
            --advertise-address="$ADVERTISE_ADDRESS" \
            --kubeedge-version="v$CLOUDCORE_VERSION" \
            --set cloudCore.modules.cloudStream.enable=true
        
        log_success "CloudCore 初始化完成"
    else
        log_error "keadm 命令不可用，无法初始化 CloudCore"
        log_info "请确保 keadm 已正确安装"
        exit 1
    fi
}

create_systemd_service() {
    log_info "创建 CloudCore systemd 服务..."
    
    local service_file="/etc/systemd/system/cloudcore.service"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将创建 systemd 服务: $service_file"
        return 0
    fi
    
    cat > "$service_file" << 'EOF'
[Unit]
Description=KubeEdge CloudCore
Documentation=https://kubeedge.io
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudcore --config=/etc/kubeedge/cloudcore.yaml
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=cloudcore

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable cloudcore.service
    
    log_success "CloudCore systemd 服务已创建并设置为开机自启"
}

start_cloudcore() {
    log_info "启动 CloudCore 服务..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将执行: systemctl start cloudcore"
        return 0
    fi
    
    systemctl start cloudcore.service
    
    # 等待服务启动
    sleep 3
    
    if systemctl is-active --quiet cloudcore.service; then
        log_success "CloudCore 服务已成功启动"
    else
        log_error "CloudCore 服务启动失败"
        log_info "查看日志: journalctl -u cloudcore -f"
        exit 1
    fi
}

show_token() {
    log_info "获取边缘节点接入 Token..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将执行: kubectl get secret tokensecret"
        return 0
    fi
    
    # 首选方法：直接从K8s secret获取完整的JWT token
    EDGE_TOKEN=$(kubectl get secret -n kubeedge tokensecret -o jsonpath='{.data.tokendata}' 2>/dev/null | base64 -d)
    
    # 备选方法：使用keadm
    if [ -z "$EDGE_TOKEN" ] && command -v keadm &> /dev/null; then
        EDGE_TOKEN=$(keadm gettoken --kube-config="$KUBECONFIG" 2>/dev/null)
    fi
    
    if [ -n "$EDGE_TOKEN" ]; then
        echo ""
        echo "=============================================="
        echo "边缘节点接入信息"
        echo "=============================================="
        echo ""
        echo "CloudCore 地址: $ADVERTISE_ADDRESS:10000"
        echo ""
        echo "Token (用于边缘节点接入):"
        echo "$EDGE_TOKEN"
        echo ""
        if [[ "$EDGE_TOKEN" == *"."* ]]; then
            echo "✓ Token格式: JWT (正确)"
        else
            echo "⚠ Token格式可能不正确，请检查"
        fi
        echo ""
        echo "使用方法:"
        echo "  sudo ./install.sh $ADVERTISE_ADDRESS:10000 '$EDGE_TOKEN' <节点名称>"
        echo ""
        echo "=============================================="
        echo ""
    else
        log_warn "无法获取 Token"
        log_info "请手动执行: kubectl get secret -n kubeedge tokensecret -o jsonpath='{.data.tokendata}' | base64 -d"
    fi
}

###############################################################################
# 主流程
###############################################################################

main() {
    echo "=============================================="
    echo "KubeEdge 云端组件独立安装脚本"
    echo "=============================================="
    echo ""
    
    # 解析参数
    parse_args "$@"
    
    # 环境检查
    check_root
    detect_kubernetes
    detect_container_runtime
    detect_advertise_address
    detect_kubeedge_version
    
    echo ""
    echo "=============================================="
    echo "安装信息确认"
    echo "=============================================="
    echo "集群类型: $K8S_TYPE"
    echo "容器运行时: $CONTAINER_RUNTIME"
    echo "KubeEdge 版本: $CLOUDCORE_VERSION"
    echo "广播地址: $ADVERTISE_ADDRESS"
    echo "Kubeconfig: $KUBECONFIG"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo ""
        echo -e "${YELLOW}*** DRY-RUN 模式 - 仅预览，不执行实际安装 ***${NC}"
    fi
    
    echo "=============================================="
    echo ""
    
    if [[ "$DRY_RUN" == "false" ]]; then
        read -p "确认开始安装? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "安装已取消"
            exit 0
        fi
    fi
    
    echo ""
    
    # 执行安装步骤
    load_images
    install_cloudcore_binary
    install_keadm_binary
    generate_cloudcore_config
    init_cloudcore
    create_systemd_service
    start_cloudcore
    show_token
    
    echo ""
    log_success "=============================================="
    log_success "KubeEdge CloudCore 安装完成！"
    log_success "=============================================="
    echo ""
    log_info "常用命令:"
    log_info "  查看服务状态: systemctl status cloudcore"
    log_info "  查看日志: journalctl -u cloudcore -f"
    log_info "  重启服务: systemctl restart cloudcore"
    log_info "  获取 Token: keadm gettoken --kube-config=$KUBECONFIG"
    log_info "  查看边缘节点: $KUBECTL_CMD get nodes"
    echo ""
}

# 执行主流程
main "$@"
