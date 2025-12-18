# k3s+KubeEdge+KubeMesh 可观测性平台实施计划

## 概述
为现有kubeprepare项目添加完整的可观测性功能，包括指标监控(Prometheus+Grafana)、日志管理(Loki+Promtail)、链路追踪(Jaeger+KubeMesh)、通信链路监控(Blackbox Exporter)和告警体系(Alertmanager)。遵循项目现有模式：离线优先、多架构支持、自动化部署。

## 核心原则
- 保持向后兼容：现有安装脚本功能不变，通过`--with-observability`参数启用新功能
- 离线优先：所有依赖预下载打包，无需互联网连接
- 边缘优化：边缘组件轻量化，支持离线缓存
- 自动化：一键部署，零手动配置

## 一、GitHub Action扩展方案

### 1.1 扩展现有build-release-cloud.yml
**文件**: `/workspaces/kubeprepare/.github/workflows/build-release-cloud.yml`

**新增内容**:
1. **版本变量**：添加可观测性组件版本变量
   ```yaml
   PROMETHEUS_STACK_VERSION="58.0.0"  # kube-prometheus-stack最新稳定版
   LOKI_VERSION="5.37.0"              # Loki最新稳定版
   PROMTAIL_VERSION="6.37.0"          # Promtail最新稳定版
   JAEGER_VERSION="0.105.0"           # Jaeger最新稳定版
   BLACKBOX_VERSION="7.1.0"           # Blackbox Exporter最新稳定版
   ```

2. **镜像下载**：在现有镜像下载部分添加可观测性镜像
   ```bash
   # 可观测性镜像列表
   OBSERVABILITY_IMAGES=(
     "docker.io/bitnami/kube-prometheus-stack:$PROMETHEUS_STACK_VERSION"
     "grafana/loki:$LOKI_VERSION"
     "grafana/promtail:$PROMTAIL_VERSION"
     "jaegertracing/jaeger-operator:$JAEGER_VERSION"
     "prom/blackbox-exporter:$BLACKBOX_VERSION"
   )
   ```

3. **Helm Chart下载**：添加可观测性Helm charts下载
   ```bash
   # 下载kube-prometheus-stack Helm chart
   wget -q -O helm-charts/kube-prometheus-stack.tgz \
     "https://github.com/prometheus-community/helm-charts/releases/download/kube-prometheus-stack-${PROMETHEUS_STACK_VERSION}/kube-prometheus-stack-${PROMETHEUS_STACK_VERSION}.tgz"
   ```

4. **目录结构调整**：在离线包中添加`observability/`目录
   ```
   observability/
   ├── images/                    # 可观测性镜像
   ├── helm-charts/              # Helm charts
   │   ├── kube-prometheus-stack.tgz
   │   ├── loki.tgz
   │   └── promtail.tgz
   ├── configs/                  # 配置文件
   │   ├── prometheus/
   │   │   └── additional-scrape-configs.yaml  # KubeEdge指标抓取配置
   │   ├── loki/
   │   │   └── loki-config.yaml
   │   └── alertmanager/
   │       └── alertmanager-config.yaml
   └── manifests/                # 部署清单
       ├── namespace.yaml
       ├── storage-class.yaml
       └── custom-resources.yaml
   ```

## 二、云端安装脚本扩展

### 2.1 扩展现有cloud/install/install.sh
**文件**: `/workspaces/kubeprepare/cloud/install/install.sh`

**新增功能**:
1. **命令行参数**：添加`--with-observability`选项
   ```bash
   if [[ " ${ARGS[@]} " =~ " --with-observability " ]]; then
     OBSERVABILITY_ENABLED=true
   fi
   ```

2. **可观测性部署函数**：添加部署函数
   ```bash
   deploy_observability_stack() {
     echo "部署可观测性平台..."
     # 1. 创建monitoring命名空间
     # 2. 加载可观测性镜像
     # 3. 部署Prometheus+Grafana+Alertmanager
     # 4. 部署Loki+Promtail
     # 5. 部署Jaeger
     # 6. 部署Blackbox Exporter
     # 7. 配置KubeMesh链路追踪
   }
   ```

3. **集成点**：在现有安装流程末尾添加条件调用
   ```bash
   # 现有安装流程...

   # 部署可观测性平台（如果启用）
   if [ "$OBSERVABILITY_ENABLED" = true ]; then
     deploy_observability_stack
   fi
   ```

### 2.2 配置文件结构
**目录**: `/workspaces/kubeprepare/cloud/install/observability/`

**关键文件**:
1. `helm-values/kube-prometheus-stack-values.yaml` - Prometheus+Grafana配置
   - KubeEdge指标抓取配置
   - 资源限制
   - 存储配置

2. `configs/prometheus/additional-scrape-configs.yaml` - Prometheus抓取配置
   ```yaml
   - job_name: 'kubeedge-cloudcore'
     static_configs:
       - targets: ['cloudcore:10250']
   - job_name: 'kubeedge-edgecore'
     kubernetes_sd_configs:
       - role: node
     relabel_configs:
       - source_labels: [__meta_kubernetes_node_label_node_role_kubernetes_io_edge]
         regex: "true"
         action: keep
   ```

3. `manifests/` - 部署清单
   - 命名空间创建
   - 存储类配置
   - 自定义资源定义

## 三、边缘端安装脚本扩展

### 3.1 扩展现有edge/install/install.sh
**文件**: `/workspaces/kubeprepare/edge/install/install.sh`

**新增配置**:
1. **EdgeCore metrics接口配置**：修改`/etc/kubeedge/config/edgecore.yaml`
   ```yaml
   metaServer:
     enable: true
     server: 0.0.0.0:10550

   metrics:
     enable: true
     port: 10000
     path: /metrics
   ```

2. **Promtail部署**：边缘节点日志采集
   ```bash
   # 加载Promtail镜像
   k3s ctr images import promtail.tar

   # 部署Promtail DaemonSet（如果云端启用了可观测性）
   if [ "$OBSERVABILITY_ENABLED" = true ]; then
     kubectl apply -f promtail-daemonset.yaml
   fi
   ```

3. **边缘节点标签**：为Prometheus自动发现添加标签
   ```bash
   kubectl label node $(hostname) node-role.kubernetes.io/edge=true
   ```

## 四、关键配置检查与增强

### 4.1 EdgeCore配置开放接口
需要修改edgecore.yaml以暴露：
1. **Metrics接口**：端口10000，供Prometheus抓取
2. **日志接口**：确保日志目录可被Promtail访问
3. **健康检查**：添加健康检查端点

### 4.2 K3s配置检查
确保K3s配置支持：
1. **Node Exporter**：已包含在k3s镜像中
2. **cAdvisor**：已默认启用
3. **kube-state-metrics**：通过kube-prometheus-stack部署

### 4.3 网络配置
1. **端口开放**：确保边缘节点10000端口可被云端访问
2. **防火墙规则**：更新iptables规则
3. **云边通信**：验证CloudStream/EdgeStream隧道

## 五、版本查询策略

### 5.1 版本确定方法
1. **查询GitHub Releases**：获取各组件最新稳定版
2. **兼容性检查**：确保与k3s v1.34.2+k3s1、kubeedge v1.22.0兼容
3. **版本锁定**：在GitHub Action中锁定版本，避免自动升级

### 5.2 版本变量命名
```bash
# GitHub Action环境变量
PROMETHEUS_STACK_CHART_VERSION="58.0.0"
LOKI_CHART_VERSION="5.37.0"
JAEGER_CHART_VERSION="0.105.0"
```

## 六、实施步骤

### 阶段1：基础架构准备
1. 创建目录结构：`cloud/install/observability/`
2. 编写配置文件：values.yaml、scrape-configs等
3. 设计Helm values文件

### 阶段2：GitHub Action扩展
1. 扩展现有build-release-cloud.yml
2. 添加镜像下载逻辑
3. 添加Helm charts下载
4. 测试Action构建

### 阶段3：云端脚本扩展
1. 修改cloud/install/install.sh添加`--with-observability`参数
2. 实现可观测性部署函数
3. 集成现有metrics-server部署
4. 测试云端安装

### 阶段4：边缘端脚本扩展
1. 修改edge/install/install.sh添加edgecore配置
2. 实现Promtail部署逻辑
3. 测试边缘端安装

### 阶段5：集成测试
1. 端到端部署测试
2. 功能验证：指标、日志、链路追踪
3. 性能测试：资源占用、网络带宽
4. 离线场景测试

## 七、关键文件列表

### 7.1 新增文件
1. `cloud/install/observability/` - 可观测性配置目录
2. `cloud/install/observability/helm-values/` - Helm values文件
3. `cloud/install/observability/configs/` - 配置文件
4. `cloud/install/observability/manifests/` - 部署清单

### 7.2 修改文件
1. `.github/workflows/build-release-cloud.yml` - 扩展镜像和charts下载
2. `cloud/install/install.sh` - 添加可观测性部署功能
3. `edge/install/install.sh` - 添加edgecore配置和Promtail部署
4. `docs/PROJECT_STRUCTURE.md` - 更新项目结构文档
5. `README.md` - 更新功能说明

## 八、风险与缓解

### 8.1 资源占用风险
- **风险**：可观测性组件占用较多内存/CPU
- **缓解**：配置资源限制，使用轻量级配置

### 8.2 存储需求风险
- **风险**：Prometheus和Loki需要持久化存储
- **缓解**：使用K3s local-path provisioner，配置数据保留策略

### 8.3 网络带宽风险
- **风险**：边缘节点指标上传占用带宽
- **缓解**：调整抓取间隔(30s)，启用数据压缩

### 8.4 版本兼容性风险
- **风险**：组件版本不兼容
- **缓解**：使用经过测试的版本组合，提供兼容性矩阵

## 九、成功标准
1. ✅ 可观测性平台一键部署成功
2. ✅ 指标监控：云端和边缘节点指标可查看
3. ✅ 日志管理：边缘节点日志可查询
4. ✅ 链路追踪：云边服务调用链可追踪
5. ✅ 告警体系：关键异常及时告警
6. ✅ 离线场景：所有功能在离线环境下正常工作
7. ✅ 资源占用：边缘组件内存<64Mi，CPU<100m

---
**实施准备**：以上计划基于现有代码库模式设计，保持了项目的核心原则。实施前需要查询各组件的最新稳定版本，并验证与现有k3s/kubeedge版本的兼容性。