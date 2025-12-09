# KubeEdge Cloud 端 logs/exec 问题排查与自动化修复流程

## 背景与问题描述
KubeEdge 在云端通过 `kubectl logs/exec` 调试边缘节点 Pod 时，所有流量需通过 cloudcore 隧道代理，且 TLS 校验必须通过。常见问题包括：
- logs/exec 502 Bad Gateway，无法远程获取 edge 节点日志
- stream 证书 SAN 不包含所有节点 IP，导致 TLS 校验失败
- Secret key 与 cloudcore 部署不一致，证书未及时生效

## 关键配置与自动化流程

### 1. K3S 配置
- 必须在 k3s 启动参数中添加 `--egress-selector-mode=disabled`，确保所有 logs/exec 流量走 cloudcore 隧道代理。
- 参考官方 issue：https://github.com/kubeedge/kubeedge/issues/3842
- 相关配置片段：
  ```bash
  ExecStart=/usr/local/bin/k3s server \
    --egress-selector-mode=disabled \
    --advertise-address=<EXTERNAL_IP> \
    ...
  ```

### 2. stream 证书自动化
- 每次新增 edge 节点，需将该节点 IP 加入 stream 证书 SAN，并重新生成证书。
- 证书生成后，自动更新 cloudcore 所用的 Kubernetes Secret，并热重启 cloudcore Pod。
- 参考官方文档：https://kubeedge.io/zh/docs/advanced/stream/
- 相关 issue：https://github.com/kubeedge/kubeedge/issues/3842

#### 自动化脚本流程
1. 生成包含所有节点 IP 的 stream 证书（certgen.sh）
2. 更新 cloudcore 所用的 Secret，确保 key 与 Pod 挂载一致（stream.crt、stream.key、streamCA.crt）
3. 自动重启 cloudcore Deployment，Pod 自动加载最新证书
4. 一键脚本（refresh_stream_cert.sh）实现上述流程

### 3. 证书与 Secret 挂载一致性
- Secret key 必须与 cloudcore Deployment 挂载路径一致，否则证书不会生效。
- 自动化脚本已修正 Secret key，确保一致性。

### 4. 参考文档与 issue
- KubeEdge 官方文档：
  - [CloudStream/EdgeStream 机制](https://kubeedge.io/zh/docs/advanced/stream/)
  - [证书自动化与 SAN 配置](https://kubeedge.io/zh/docs/advanced/stream/)
- 官方 issue：
  - [cloudcore logs/exec 502 问题排查](https://github.com/kubeedge/kubeedge/issues/3842)
  - [stream 证书 SAN 问题](https://github.com/kubeedge/kubeedge/issues/3842#issuecomment-1862342122)

## 总结流程
1. 云端 k3s 启动参数加 `--egress-selector-mode=disabled`
2. 每次新增 edge 节点，自动生成 stream 证书，SAN 包含所有节点 IP
3. 自动更新 cloudcore Secret，确保 key 与挂载一致
4. 自动重启 cloudcore Pod，证书即时生效
5. logs/exec 流量全部走 cloudcore 隧道，TLS 校验通过

## 推荐自动化脚本
- cloud/script/certgen.sh：stream 证书自动生成
- cloud/script/refresh_stream_cert.sh：一键证书生成、Secret 更新、cloudcore 热重启

## 验证方法
- `kubectl logs -n <ns> <edge-pod>`
- `kubectl exec -n <ns> <edge-pod> -- echo ok`
- 检查 cloudcore Pod 日志，确认证书加载与 SAN 配置

---
如需详细脚本或自动化流程，可参考 cloud/script 目录下相关文件。
