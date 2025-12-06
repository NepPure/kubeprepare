# K3s 网络和证书配置说明

## 配置概览

k3s已配置为监听所有网络接口，并在TLS证书中包含公网IP地址，支持远程访问。

## 关键配置参数

### 1. 主要参数

```bash
--advertise-address=$EXTERNAL_IP    # 节点对外通告的IP地址
--node-name=$NODE_NAME              # 节点名称
--tls-san=$EXTERNAL_IP              # 添加公网IP到证书SAN列表
--bind-address=0.0.0.0              # 监听所有网络接口
```

### 2. API Server 参数

```bash
--kube-apiserver-arg=bind-address=0.0.0.0                # API Server监听所有接口
--kube-apiserver-arg=advertise-address=$EXTERNAL_IP     # API Server对外通告地址
```

### 3. Controller Manager 参数

```bash
--kube-controller-manager-arg=bind-address=0.0.0.0      # Controller Manager监听所有接口
```

### 4. Scheduler 参数

```bash
--kube-scheduler-arg=bind-address=0.0.0.0               # Scheduler监听所有接口
```

### 5. 保留的k3s组件

k3s保留所有默认组件，提供完整的Kubernetes集群功能：

```bash
# ✅ 保留所有k3s默认组件（无--disable参数）
# - Traefik        (Ingress Controller)
# - ServiceLB      (Klipper LoadBalancer)
# - Local Storage  (本地存储Provisioner)
# - CoreDNS        (DNS服务)
# - Metrics Server (监控指标)
```

#### 为什么保留所有组件？

##### 架构理解

**云端k3s集群** = 完整的Kubernetes集群（可能多节点，可扩展）
- 运行云端应用和管理组件
- 提供完整的K8s功能（Ingress、LoadBalancer、PVC等）
- 可以多节点部署，支持高可用

**边缘节点** = 通过KubeEdge扩展的轻量级节点
- 运行边缘应用
- 通过nodeSelector明确调度
- 不运行重量级云端组件

##### ✅ Traefik (Ingress Controller)

**为什么保留**:
1. **云端应用需要Ingress**
   ```yaml
   # 云端Dashboard/监控系统使用Ingress
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: cloud-dashboard
   spec:
     rules:
     - host: dashboard.example.com
       http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: dashboard
               port:
                 number: 80
   ```

2. **边缘应用通过nodeSelector部署**
   ```yaml
   # 边缘应用明确部署到边缘节点
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: edge-app
   spec:
     template:
       spec:
         nodeSelector:
           node-role.kubernetes.io/edge: ""  # 只部署到边缘
   ```

##### ✅ ServiceLB (Klipper LoadBalancer)

**为什么保留**:
1. **简化云端服务暴露**
   ```yaml
   # CloudCore使用LoadBalancer类型
   apiVersion: v1
   kind: Service
   metadata:
     name: cloudcore
     namespace: kubeedge
   spec:
     type: LoadBalancer
     ports:
     - name: websocket
       port: 10000
     - name: stream
       port: 10003
   ```

2. **兼容云厂商LoadBalancer**
   - 在云环境自动使用云厂商LB
   - 在裸机环境使用klipper-lb
   - 无需手动区分环境

##### ✅ Local Storage (本地存储)

**为什么保留**:
1. **云端应用需要持久化**
   ```yaml
   # 云端应用使用PVC
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: cloud-data
   spec:
     accessModes:
     - ReadWriteOnce
     resources:
       requests:
         storage: 10Gi
     storageClassName: local-path
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: cloud-app
   spec:
     nodeSelector:
       node-role.kubernetes.io/master: "true"  # 部署到云端
     volumes:
     - name: data
       persistentVolumeClaim:
         claimName: cloud-data
   ```

2. **边缘使用HostPath**
   ```yaml
   # 边缘应用使用HostPath，数据在边缘本地
   apiVersion: v1
   kind: Pod
   metadata:
     name: edge-app
   spec:
     nodeSelector:
       node-role.kubernetes.io/edge: ""  # 部署到边缘
     volumes:
     - name: data
       hostPath:
         path: /var/lib/edge-data
         type: DirectoryOrCreate
   ```

#### 云边应用调度策略

通过nodeSelector实现云边隔离，而非禁用组件：

```
┌─────────────────────────────────────────────┐
│         云端K3s集群（完整功能）              │
│  ┌────────────────────────────────────────┐ │
│  │  Cloud Node 1    Cloud Node 2         │ │
│  │  ────────────    ────────────          │ │
│  │  • Traefik ✅    • Traefik ✅          │ │
│  │  • ServiceLB ✅  • ServiceLB ✅        │ │
│  │  • Storage ✅    • Storage ✅          │ │
│  │                                        │ │
│  │  nodeSelector:                         │ │
│  │  master: "true"                        │ │
│  └────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────┐ │
│  │         CloudCore (云端部署)           │ │
│  │  nodeSelector: master: "true"         │ │
│  └────────────────────────────────────────┘ │
└─────────────────────────────────────────────┘
                    │
        ┌───────────┴───────────┐
        │                       │
┌───────▼─────┐         ┌───────▼─────┐
│ Edge Node 1 │         │ Edge Node 2 │
│ • EdgeCore  │         │ • EdgeCore  │
│ • 轻量级    │         │ • 轻量级    │
│                       │             │
│ nodeSelector:         │ nodeSelector:│
│ edge: ""    │         │ edge: ""    │
└─────────────┘         └─────────────┘
```

#### 应用部署最佳实践

##### 1. 云端应用（完整K8s功能）

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: monitoring
spec:
  replicas: 2
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
    spec:
      nodeSelector:
        node-role.kubernetes.io/master: "true"  # 云端
      containers:
      - name: prometheus
        image: prom/prometheus:latest
        volumeMounts:
        - name: data
          mountPath: /prometheus
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: prometheus-data  # 使用PVC
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus
spec:
  type: LoadBalancer  # 使用LoadBalancer
  ports:
  - port: 9090
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prometheus
spec:
  rules:
  - host: prometheus.example.com  # 使用Ingress
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: prometheus
            port:
              number: 9090
```

##### 2. 边缘应用（轻量级）

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: edge-collector
  namespace: edge
spec:
  replicas: 1
  selector:
    matchLabels:
      app: edge-collector
  template:
    metadata:
      labels:
        app: edge-collector
    spec:
      nodeSelector:
        node-role.kubernetes.io/edge: ""  # 边缘
      hostNetwork: true  # 使用主机网络
      containers:
      - name: collector
        image: edge-collector:latest
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        hostPath:  # 使用HostPath
          path: /var/lib/edge-data
          type: DirectoryOrCreate
```

#### 组件使用对比

| 组件 | 云端使用 | 边缘使用 | 隔离方式 |
|------|---------|---------|---------|
| Traefik | ✅ 云端Ingress | ❌ 不调度到边缘 | nodeSelector |
| ServiceLB | ✅ 云端LoadBalancer | ❌ 不调度到边缘 | nodeSelector |
| Local Storage | ✅ 云端PVC | ❌ 边缘用HostPath | nodeSelector + volume类型 |
| CoreDNS | ✅ 全局DNS | ✅ 边缘可用 | 系统组件 |
| Metrics Server | ✅ 全局监控 | ✅ 边缘可用 | 系统组件 |

#### 节点标签管理

```bash
# 云端节点（k3s自动添加）
kubectl label nodes cloud-node-1 node-role.kubernetes.io/master=true

# 边缘节点（EdgeCore自动添加）
# node-role.kubernetes.io/edge=""

# 查看所有节点标签
kubectl get nodes --show-labels

# 示例输出：
# NAME          STATUS   ROLES    LABELS
# cloud-node-1  Ready    master   node-role.kubernetes.io/master=true
# edge-node-1   Ready    edge     node-role.kubernetes.io/edge=""
# edge-node-2   Ready    edge     node-role.kubernetes.io/edge=""
```

## 配置效果

### ✅ 证书包含公网IP

通过 `--tls-san=$EXTERNAL_IP` 参数，k3s生成的API Server证书的Subject Alternative Names (SAN)字段将包含公网IP地址。

**效果**:
- 从公网通过IP地址访问API Server时不会出现证书验证错误
- kubectl可以使用公网IP连接集群
- 边缘节点可以通过公网IP安全连接云端

**验证方法**:
```bash
# 查看证书SAN列表
openssl s_client -connect $EXTERNAL_IP:6443 -showcerts 2>/dev/null | \
  openssl x509 -noout -text | grep -A 1 "Subject Alternative Name"

# 应该包含:
# DNS:kubernetes, DNS:kubernetes.default, DNS:kubernetes.default.svc, 
# DNS:kubernetes.default.svc.cluster.local, DNS:localhost, 
# IP Address:$EXTERNAL_IP, IP Address:10.43.0.1, IP Address:127.0.0.1
```

### ✅ 监听所有网络接口

通过 `--bind-address=0.0.0.0` 参数，所有组件都绑定到0.0.0.0，接受来自任何网络接口的连接。

**效果**:
- 内网可以访问
- 公网可以访问（需要防火墙规则配合）
- Docker网络可以访问
- 回环地址可以访问

**验证方法**:
```bash
# 检查k3s监听的端口
sudo netstat -tlnp | grep k3s

# 应该显示:
# 0.0.0.0:6443    (API Server)
# 0.0.0.0:10250   (Kubelet)
# 0.0.0.0:10251   (Scheduler)
# 0.0.0.0:10252   (Controller Manager)
```

### ✅ API Server对外通告正确地址

通过 `--kube-apiserver-arg=advertise-address=$EXTERNAL_IP` 参数，API Server会向集群通告正确的外部访问地址。

**效果**:
- 集群组件知道如何连接API Server
- 生成的kubeconfig包含正确的server地址
- 边缘节点可以直接使用通告地址连接

**验证方法**:
```bash
# 检查kubeconfig中的server地址
cat /etc/rancher/k3s/k3s.yaml | grep server:

# 应该显示:
# server: https://$EXTERNAL_IP:6443
```

## 网络访问配置

### 内网访问

从内网机器访问k3s集群：

```bash
# 1. 复制kubeconfig
scp root@$EXTERNAL_IP:/etc/rancher/k3s/k3s.yaml ~/.kube/config

# 2. 修改server地址（如果需要）
sed -i "s/127.0.0.1/$EXTERNAL_IP/g" ~/.kube/config

# 3. 测试访问
kubectl get nodes
```

### 公网访问

从公网访问k3s集群需要配置防火墙：

```bash
# 防火墙规则示例 (firewalld)
sudo firewall-cmd --permanent --add-port=6443/tcp     # API Server
sudo firewall-cmd --permanent --add-port=10250/tcp    # Kubelet
sudo firewall-cmd --reload

# 或使用iptables
sudo iptables -A INPUT -p tcp --dport 6443 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 10250 -j ACCEPT
```

### 安全建议

🔒 **生产环境安全配置**:

1. **限制API Server访问源**
   ```bash
   # 只允许特定IP访问
   sudo iptables -A INPUT -p tcp -s $TRUSTED_IP --dport 6443 -j ACCEPT
   sudo iptables -A INPUT -p tcp --dport 6443 -j DROP
   ```

2. **使用VPN**
   - 不要直接暴露API Server到公网
   - 使用VPN或SSH隧道访问

3. **启用RBAC**
   - k3s默认启用RBAC
   - 配置适当的ServiceAccount权限

4. **定期轮换证书**
   ```bash
   # k3s会自动管理证书，默认有效期365天
   # 查看证书过期时间
   sudo k3s certificate list
   ```

## 与KubeEdge的集成

### CloudCore连接

KubeEdge CloudCore会通过以下方式连接k3s API Server：

```yaml
# CloudCore配置
kubeAPIConfig:
  master: "https://$EXTERNAL_IP:6443"
  kubeConfig: "/etc/rancher/k3s/k3s.yaml"
  contentType: "application/vnd.kubernetes.protobuf"
```

由于证书已包含公网IP，CloudCore可以正常验证证书。

### 边缘节点连接

边缘节点通过CloudCore连接到云端：

```
EdgeCore → CloudCore (10000/10003) → k3s API Server (6443)
```

k3s的公网IP配置确保CloudCore能够正确代理边缘节点的请求。

## 故障排查

### 问题1: 证书验证失败

**症状**: `x509: certificate is valid for..., not $EXTERNAL_IP`

**原因**: 证书SAN列表不包含公网IP

**解决**:
```bash
# 检查是否添加了--tls-san参数
systemctl cat k3s | grep tls-san

# 如果缺失，重新生成证书
sudo systemctl stop k3s
sudo rm -rf /var/lib/rancher/k3s/server/tls
sudo systemctl start k3s
```

### 问题2: 无法从外部访问

**症状**: 连接超时或拒绝

**排查步骤**:
```bash
# 1. 检查k3s是否监听0.0.0.0
sudo netstat -tlnp | grep :6443

# 2. 检查防火墙
sudo iptables -L -n | grep 6443
sudo firewall-cmd --list-all

# 3. 测试端口连通性
telnet $EXTERNAL_IP 6443
```

### 问题3: kubeconfig连接失败

**症状**: `unable to connect to the server`

**解决**:
```bash
# 检查kubeconfig中的server地址
grep "server:" ~/.kube/config

# 应该是公网IP，不是127.0.0.1
# 如果错误，手动修改:
sed -i "s|server: https://127.0.0.1:6443|server: https://$EXTERNAL_IP:6443|g" ~/.kube/config
```

## 配置验证清单

安装完成后，验证以下项目：

- [ ] k3s服务运行正常: `systemctl status k3s`
- [ ] 监听0.0.0.0: `netstat -tlnp | grep k3s`
- [ ] 证书包含公网IP: `openssl s_client -connect $EXTERNAL_IP:6443 -showcerts`
- [ ] API Server可访问: `kubectl --server=https://$EXTERNAL_IP:6443 get nodes`
- [ ] CloudCore可连接: `kubectl -n kubeedge get pod`

## 参考文档

- [k3s Server Configuration](https://docs.k3s.io/reference/server-config)
- [k3s Networking](https://docs.k3s.io/networking)
- [Kubernetes TLS](https://kubernetes.io/docs/tasks/tls/managing-tls-in-a-cluster/)
- [KubeEdge Cloud Configuration](https://kubeedge.io/docs/setup/install-with-keadm/)

## 版本信息

- k3s: v1.34.2+k3s1
- 配置日期: 2025-12-06
- 适用环境: 公有云、私有云、混合云
