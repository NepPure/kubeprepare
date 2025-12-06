# EdgeMesh 离线部署完善说明

## 概述

根据 EdgeMesh 官方文档的最佳实践，完善了云端和边缘端的离线部署流程。本次改进确保 EdgeMesh 能够正确运行，关键是添加了必需的 Istio CRDs 和 CloudCore dynamicController 配置。

## 主要改进

### 1. Cloud 端改进

#### 1.1 GitHub Actions Workflow (`.github/workflows/build-release-cloud.yml`)

**新增步骤 5.5: 下载 Istio CRDs**
- 位置: EdgeMesh Helm Chart 下载之后 (约 line 157-170)
- 内容: 下载 3 个必需的 Istio CRDs
  - `destinationrules.yaml`
  - `gateways.yaml`
  - `virtualservices.yaml`
- 来源: `https://raw.githubusercontent.com/kubeedge/edgemesh/main/build/crds/istio/`
- 目录: `crds/istio/`

**打包改进**
- 确保 `crds/` 目录被包含在离线安装包中
- 位置: 约 line 202-207

#### 1.2 安装脚本 (`cloud/install/install.sh`)

**新增步骤 5.5: 安装 Istio CRDs**
- 位置: namespace 创建后，KubeEdge CloudCore 安装前 (约 line 240-262)
- 功能:
  - 检查 `crds/istio/` 目录是否存在
  - 使用 `kubectl apply -f` 安装所有 CRD YAML 文件
  - 统计并报告安装的 CRD 数量
  - 如果目录不存在，发出警告

**新增步骤 6.5: 启用 CloudCore dynamicController**
- 位置: CloudCore 就绪后 (约 line 306-370)
- 功能:
  - 检查 CloudCore ConfigMap 是否存在
  - 使用 `kubectl patch` 启用 `dynamicController.enable: true`
  - 重启 CloudCore Pod 使配置生效
  - 如果 ConfigMap 不存在，尝试修改 `/etc/kubeedge/config/cloudcore.yaml`
  - 备份原配置文件为 `cloudcore.yaml.bak`

### 2. Edge 端验证

#### 2.1 GitHub Actions Workflow (`.github/workflows/build-release-edge.yml`)

✅ **已确认**: EdgeMesh Agent 镜像下载
- 位置: 步骤 4.5 (约 line 121-140)
- 镜像: `docker.io/kubeedge/edgemesh-agent:v1.17.0`
- 输出: `images/docker.io-kubeedge-edgemesh-agent-v1.17.0.tar`

#### 2.2 安装脚本 (`edge/install/install.sh`)

✅ **已确认**: EdgeMesh Agent 镜像导入
- 位置: 步骤 4.5 (约 line 300-328)
- 功能:
  - 查找 EdgeMesh Agent 镜像 tar 文件
  - 确保 containerd 正在运行
  - 使用 `ctr -n k8s.io images import` 导入镜像
  - 验证镜像已成功导入

## 技术细节

### Istio CRDs 的作用
EdgeMesh 使用 Istio 的流量管理 CRDs 来实现服务网格功能：
- **DestinationRule**: 定义流量策略和负载均衡
- **Gateway**: 配置边缘入口流量
- **VirtualService**: 定义路由规则

### CloudCore dynamicController 的作用
- 为边缘节点提供 metaServer 功能
- 允许边缘应用通过 127.0.0.1:10550 访问 Kubernetes API
- 是 EdgeMesh 正常工作的前置条件

### EdgeMesh 架构
```
Cloud Node                          Edge Nodes
┌─────────────┐                    ┌─────────────┐
│  K3s/K8s    │                    │  EdgeCore   │
│  CloudCore  │◄───────────────────┤  metaServer │
│  dynamicController: true │       │  edgeStream │
│                          │       │  clusterDNS │
│  Istio CRDs             │       └─────────────┘
│  EdgeMesh Agent (DaemonSet)      EdgeMesh Agent (DaemonSet)
└─────────────┘                    └─────────────┘
```

## 安装顺序

### Cloud 端安装顺序
1. K3s 安装
2. K3s 镜像导入
3. Kubernetes API 就绪等待
4. KubeEdge namespace 创建
5. **[新增] Istio CRDs 安装** ← 必须在 EdgeMesh 之前
6. KubeEdge CloudCore 安装
7. **[新增] CloudCore dynamicController 启用** ← 必须启用
8. Edge Token 生成
9. EdgeMesh 安装 (可选)

### Edge 端安装顺序
1. containerd/runc 安装
2. **[新增] EdgeMesh Agent 镜像预导入** ← DaemonSet 会使用
3. Mosquitto MQTT 镜像导入 (可选)
4. EdgeCore 安装和配置
5. EdgeCore 启动并加入集群

## 配置验证

### 验证 Istio CRDs 安装
```bash
kubectl get crd | grep istio
# 应该看到:
# destinationrules.networking.istio.io
# gateways.networking.istio.io
# virtualservices.networking.istio.io
```

### 验证 CloudCore dynamicController
```bash
# 方法 1: 检查 ConfigMap
kubectl -n kubeedge get cm cloudcore -o yaml | grep -A 2 dynamicController

# 方法 2: 检查配置文件
grep -A 2 "dynamicController:" /etc/kubeedge/config/cloudcore.yaml

# 应该看到:
# dynamicController:
#   enable: true
```

### 验证 EdgeMesh Agent 镜像
```bash
# 在 edge 节点上
ctr -n k8s.io images ls | grep edgemesh
# 应该看到:
# docker.io/kubeedge/edgemesh-agent:v1.17.0
```

### 验证 EdgeMesh 运行
```bash
# 在 cloud 节点上
kubectl -n kubeedge get pod -l app=edgemesh-agent
# 应该看到所有节点上的 edgemesh-agent pod 都在 Running 状态
```

## 离线包结构变化

### Cloud 端离线包
```
kubeedge-cloud-1.22.0-k3s-1.34.2+k3s1-amd64.tar.gz
├── k3s-amd64
├── cloudcore
├── keadm
├── images/
│   ├── (K3s 镜像)
│   ├── (KubeEdge 镜像)
│   └── (EdgeMesh 镜像)
├── helm-charts/
│   └── edgemesh.tgz
├── crds/                    # [新增]
│   └── istio/              # [新增]
│       ├── destinationrules.yaml  # [新增]
│       ├── gateways.yaml         # [新增]
│       └── virtualservices.yaml  # [新增]
├── install.sh
├── install-kubeedge-only.sh
├── cleanup.sh
└── README.txt
```

### Edge 端离线包
```
kubeedge-edge-1.22.0-amd64.tar.gz
├── edgecore
├── keadm
├── bin/
│   ├── containerd
│   ├── containerd-shim-runc-v2
│   └── ctr
├── runc
├── images/
│   ├── docker.io-kubeedge-edgemesh-agent-v1.17.0.tar  # [已存在]
│   └── eclipse-mosquitto-2.0.tar
├── meta/
│   └── version.txt
├── install.sh
└── cleanup.sh
```

## 兼容性说明

- **KubeEdge**: v1.22.0
- **EdgeMesh**: v1.17.0
- **K3s**: v1.34.2+k3s1
- **Istio CRDs**: 来自 EdgeMesh v1.17.0 官方仓库
- **架构**: amd64, arm64

## 测试建议

1. **Cloud 端测试**:
   ```bash
   # 安装后检查
   kubectl get crd | grep istio
   kubectl -n kubeedge get cm cloudcore -o yaml | grep dynamicController
   kubectl -n kubeedge get pod
   ```

2. **Edge 端测试**:
   ```bash
   # 安装前检查
   ctr -n k8s.io images ls | grep edgemesh
   
   # 安装后检查
   systemctl status edgecore
   kubectl get nodes
   ```

3. **EdgeMesh 功能测试**:
   ```bash
   # 部署测试应用
   kubectl apply -f test-app.yaml
   
   # 检查 EdgeMesh 代理状态
   kubectl -n kubeedge get pod -l app=edgemesh-agent
   
   # 测试边缘节点间通信
   kubectl exec -it <edge-pod> -- curl http://service-name
   ```

## 参考文档

- [EdgeMesh 官方文档](https://edgemesh.netlify.app/)
- [EdgeMesh GitHub](https://github.com/kubeedge/edgemesh)
- [EdgeMesh 快速入门](https://edgemesh.netlify.app/guide/)
- [KubeEdge 文档](https://kubeedge.io/docs/)

## 故障排查

### 问题 1: EdgeMesh Pod CrashLoopBackOff
**可能原因**: Istio CRDs 未安装
**解决方案**:
```bash
# 检查 CRDs
kubectl get crd | grep istio

# 如果缺失，手动安装
kubectl apply -f crds/istio/destinationrules.yaml
kubectl apply -f crds/istio/gateways.yaml
kubectl apply -f crds/istio/virtualservices.yaml
```

### 问题 2: 边缘节点 metaServer 无法访问
**可能原因**: CloudCore dynamicController 未启用
**解决方案**:
```bash
# 检查配置
kubectl -n kubeedge get cm cloudcore -o yaml | grep -A 2 dynamicController

# 如果为 false，手动启用
kubectl -n kubeedge edit cm cloudcore
# 修改 dynamicController.enable 为 true

# 重启 CloudCore
kubectl -n kubeedge delete pod -l kubeedge=cloudcore
```

### 问题 3: EdgeMesh Agent 镜像拉取失败
**可能原因**: 边缘节点未预导入镜像
**解决方案**:
```bash
# 在 edge 节点上手动导入
ctr -n k8s.io images import images/docker.io-kubeedge-edgemesh-agent-v1.17.0.tar

# 验证
ctr -n k8s.io images ls | grep edgemesh
```

## 总结

本次完善确保了 EdgeMesh 离线部署遵循官方最佳实践：
- ✅ Istio CRDs 在 EdgeMesh 安装前就位
- ✅ CloudCore dynamicController 正确启用
- ✅ 边缘节点预导入 EdgeMesh Agent 镜像
- ✅ 完整的离线部署流程
- ✅ 详细的验证和故障排查指南
