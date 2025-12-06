#!/bin/bash
# 将此命令复制到远程服务器执行

mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIJzAS2ab16Zw8S6WIe96eRMcLD+lTQ0y1pit3bzi9+Q kubeprepare-deploy" >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo "✓ SSH 密钥配置成功！"
