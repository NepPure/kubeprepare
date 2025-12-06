# KubeEdge v1.22 离线打包与离线安装说明

## 1) 在联网机器上运行

```bash
./online_prepare.sh /path/to/output_dir
```

生成文件：`kubeedge-edge-offline-v1.22.0.tar.gz` (放在 output_dir)

将该文件复制到边缘机（scp / U盘）

## 2) 在边缘机上运行离线安装

```bash
sudo ./offline_install.sh /path/to/kubeedge-edge-offline-v1.22.0.tar.gz "wss://CLOUDIP:10000/edge/<nodeid>" "<TOKEN>" <nodename>
```

- cloud_url: 例如 `wss://10.0.0.1:10000/edge/node01` （CloudCore 的 wss 地址，含 node id 路径）
- token: 使用 `keadm gettoken --kube-config /path/to/kubeconfig` 在 Cloud 端生成

