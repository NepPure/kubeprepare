#!/bin/bash
# 在远程服务器上运行此脚本来配置 SSH 密钥访问

set -e

# 定义公钥内容
PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIJzAS2ab16Zw8S6WIe96eRMcLD+lTQ0y1pit3bzi9+Q kubeprepare-deploy"

echo "=== SSH 密钥配置 ==="
echo ""

# 创建 .ssh 目录
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# 添加公钥到 authorized_keys
if [ -f ~/.ssh/authorized_keys ]; then
  # 检查是否已存在
  if grep -q "kubeprepare-deploy" ~/.ssh/authorized_keys; then
    echo "✓ 公钥已存在"
  else
    echo "$PUBLIC_KEY" >> ~/.ssh/authorized_keys
    echo "✓ 公钥已添加"
  fi
else
  echo "$PUBLIC_KEY" > ~/.ssh/authorized_keys
  echo "✓ 已创建 authorized_keys 并添加公钥"
fi

# 设置正确的权限
chmod 600 ~/.ssh/authorized_keys
chmod 700 ~/.ssh

echo ""
echo "配置完成！现在可以使用密钥登录"
echo ""
echo "在本地运行以下命令进行测试："
echo "  ssh -i ~/.ssh/id_deploy ubuntu@152.136.201.36 'uname -a'"
