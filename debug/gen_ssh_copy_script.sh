#!/bin/bash
# 生成 SSH 公钥（如不存在），并输出一行可复制到远程环境执行的脚本

KEY_PATH="$HOME/.ssh/id_rsa.pub"
if [ ! -f "$KEY_PATH" ]; then
    ssh-keygen -t rsa -N '' -f "${KEY_PATH%.pub}"
fi
PUB_KEY=$(cat "$KEY_PATH")

# 输出一行脚本，便于复制到远程环境执行，实现免密登录
# 用法：bash gen_ssh_copy_script.sh
# 输出内容复制到远程 shell 执行即可

echo "echo '$PUB_KEY' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
