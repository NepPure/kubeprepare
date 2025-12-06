# SSH 密钥配置和远程部署指南

## 第一步：在本地生成 SSH 密钥（已完成）

SSH 密钥对已生成：
- 私钥：`~/.ssh/id_deploy`
- 公钥：`~/.ssh/id_deploy.pub`

## 第二步：将公钥添加到远程服务器

### 方法 A：手动添加（推荐）

1. **在远程服务器上执行以下命令：**

```bash
# 创建 .ssh 目录
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# 添加公钥（复制下面的内容）
cat >> ~/.ssh/authorized_keys << 'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIJzAS2ab16Zw8S6WIe96eRMcLD+lTQ0y1pit3bzi9+Q kubeprepare-deploy
EOF

# 设置权限
chmod 600 ~/.ssh/authorized_keys
chmod 700 ~/.ssh
```

或者一条命令：
```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIJzAS2ab16Zw8S6WIe96eRMcLD+lTQ0y1pit3bzi9+Q kubeprepare-deploy" >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
```

### 方法 B：自动脚本

如果你可以通过密码登录，运行本仓库提供的脚本：

```bash
# 下载脚本到远程
scp setup_ssh_key.sh ubuntu@152.136.201.36:~/

# 或者直接执行（需要输入密码）
ssh ubuntu@152.136.201.36 'bash -s' < setup_ssh_key.sh
```

## 第三步：验证密钥配置

添加公钥后，测试密钥认证是否成功：

```bash
# 测试连接
ssh -i ~/.ssh/id_deploy ubuntu@152.136.201.36 "echo '连接成功！' && uname -a"
```

如果连接成功，你会看到系统信息输出。

## 第四步：配置 SSH 别名（可选但推荐）

编辑 `~/.ssh/config`，添加以下内容：

```
Host cloud-test
    HostName 152.136.201.36
    User ubuntu
    IdentityFile ~/.ssh/id_deploy
    StrictHostKeyChecking accept-new
    UserKnownHostsFile ~/.ssh/known_hosts
```

然后你可以直接运行：
```bash
ssh cloud-test
scp install-package.tar.gz cloud-test:/tmp/
```

## 第五步：部署云端安装包

密钥配置完成后，可以自动部署：

```bash
# 上传安装包
scp -i ~/.ssh/id_deploy \
  cloud/release/kubeedge-cloud-1.22.0-k3s-v1.34.2+k3s1-amd64.tar.gz \
  ubuntu@152.136.201.36:/tmp/

# 提取并安装
ssh -i ~/.ssh/id_deploy ubuntu@152.136.201.36 << 'DEPLOY'
cd /tmp
tar -xzf kubeedge-cloud-1.22.0-k3s-v1.34.2+k3s1-amd64.tar.gz
ls -la
DEPLOY
```

## 常见问题

### Q: "Permission denied (publickey)"
A: 检查：
1. 公钥是否正确添加到 `~/.ssh/authorized_keys`
2. 权限是否正确：`~/.ssh` 应为 700，`authorized_keys` 应为 600
3. OpenSSH 服务器配置是否允许公钥认证

### Q: 如何删除旧密钥？
A: 编辑 `~/.ssh/authorized_keys`，删除对应行后保存

### Q: 如何使用不同的密钥文件名？
A: 在 SSH 命令中使用 `-i` 参数：
```bash
ssh -i /path/to/key ubuntu@152.136.201.36
```

## 安全建议

1. **保管好私钥**：`~/.ssh/id_deploy` 是私密的，不要分享或提交到版本控制
2. **限制密钥权限**：
   - 私钥应为 600（仅所有者可读写）
   - `.ssh` 目录应为 700（仅所有者可访问）
3. **定期轮换**：建议定期生成新的密钥对

## 下一步

密钥配置完成后，你可以：
1. 上传安装包到远程服务器
2. 在远程服务器上执行安装脚本
3. 验证安装是否成功

参考 `CLOUD_INSTALL_GUIDE.md` 获取详细的安装说明。
