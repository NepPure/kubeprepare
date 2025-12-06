#!/bin/sh
set -x
[ $(id -u) -eq 0 ] || exec sudo --preserve-env=K3S_DATA_DIR $0 $@

# K3s 官方卸载脚本
# 来源: https://get.k3s.io

K3S_DATA_DIR=${K3S_DATA_DIR:-/var/lib/rancher/k3s}
BIN_DIR=${BIN_DIR:-/usr/local/bin}
SYSTEMD_DIR=/etc/systemd/system
SYSTEM_NAME=k3s
FILE_K3S_SERVICE=${SYSTEMD_DIR}/${SYSTEM_NAME}.service
FILE_K3S_ENV=${SYSTEMD_DIR}/${SYSTEM_NAME}.service.env
UNINSTALL_K3S_SH=${BIN_DIR}/k3s-uninstall.sh
KILLALL_K3S_SH=${BIN_DIR}/k3s-killall.sh

# Kill all k3s processes
if [ -x ${KILLALL_K3S_SH} ]; then
    ${KILLALL_K3S_SH}
else
    # Fallback: manually kill k3s processes
    do_unmount_and_remove() {
        set +x
        MOUNTS=$(cat /proc/self/mounts | awk '{print $2}' | grep "^$1" || true)
        if [ -n "${MOUNTS}" ]; then
            echo "${MOUNTS}" | xargs -r -t -n 1 sh -c 'umount "$0" && rm -rf "$0"'
        else
            rm -rf "$1"
        fi
        set -x
    }

    CONTAINERD_PIDS=$(ps -e -o pid= -o comm= | grep -E "k3s|containerd" | awk '{print $1}')

    if [ -n "${CONTAINERD_PIDS}" ]; then
        kill -9 ${CONTAINERD_PIDS} 2>/dev/null || true
    fi

    do_unmount_and_remove '/run/k3s'
    do_unmount_and_remove '/var/lib/rancher/k3s'
    do_unmount_and_remove '/var/lib/kubelet/pods'
    do_unmount_and_remove '/var/lib/kubelet/plugins'
    do_unmount_and_remove '/run/netns/cni-'

    # Delete network interfaces
    ip link show 2>/dev/null | grep 'master cni0' | while read ignore iface ignore; do
        iface=${iface%%@*}
        [ -z "$iface" ] || ip link delete $iface
    done
    ip link delete cni0 2>/dev/null || true
    ip link delete flannel.1 2>/dev/null || true
    ip link delete flannel-v6.1 2>/dev/null || true
    ip link delete kube-ipvs0 2>/dev/null || true
    ip link delete flannel-wg 2>/dev/null || true
    ip link delete flannel-wg-v6 2>/dev/null || true

    # Flush iptables
    if command -v iptables-save >/dev/null; then
        iptables-save | grep -v KUBE- | grep -v CNI- | iptables-restore
    fi
    if command -v ip6tables-save >/dev/null; then
        ip6tables-save | grep -v KUBE- | grep -v CNI- | ip6tables-restore
    fi
fi

# Disable and remove systemd service
if command -v systemctl; then
    systemctl disable ${SYSTEM_NAME} 2>/dev/null || true
    systemctl reset-failed ${SYSTEM_NAME} 2>/dev/null || true
    systemctl daemon-reload
fi
if command -v rc-update; then
    rc-update delete ${SYSTEM_NAME} default 2>/dev/null || true
fi

rm -f ${FILE_K3S_SERVICE}
rm -f ${FILE_K3S_ENV}

remove_uninstall() {
    rm -f ${UNINSTALL_K3S_SH}
}
trap remove_uninstall EXIT

if (ls ${SYSTEMD_DIR}/k3s*.service || ls /etc/init.d/k3s*) >/dev/null 2>&1; then
    set +x; echo 'Additional k3s services installed, skipping uninstall of k3s'; set -x
    exit
fi

# Remove symlinks
for cmd in kubectl crictl ctr; do
    if [ -L ${BIN_DIR}/$cmd ]; then
        rm -f ${BIN_DIR}/$cmd
    fi
done

# Clean mounted directories
clean_mounted_directory() {
    if ! grep -q " $1" /proc/mounts; then
        rm -rf "$1"
        return 0
    fi

    for path in "$1"/*; do
        if [ -d "$path" ]; then
            if grep -q " $path" /proc/mounts; then
                clean_mounted_directory "$path"
            else
                rm -rf "$path"
            fi
        else
            rm "$path"
        fi
     done
}

rm -rf /etc/rancher/k3s
rm -rf /run/k3s
rm -rf /run/flannel
clean_mounted_directory ${K3S_DATA_DIR}
rm -rf /var/lib/kubelet
rm -f ${BIN_DIR}/k3s
rm -f ${KILLALL_K3S_SH}

# Remove SELinux policy (if applicable)
if type yum >/dev/null 2>&1; then
    yum remove -y k3s-selinux 2>/dev/null || true
    rm -f /etc/yum.repos.d/rancher-k3s-common*.repo
elif type rpm-ostree >/dev/null 2>&1; then
    rpm-ostree uninstall k3s-selinux 2>/dev/null || true
    rm -f /etc/yum.repos.d/rancher-k3s-common*.repo
elif type zypper >/dev/null 2>&1; then
    uninstall_cmd="zypper remove -y k3s-selinux"
    if [ "${TRANSACTIONAL_UPDATE=false}" != "true" ] && [ -x /usr/sbin/transactional-update ]; then
        uninstall_cmd="transactional-update --no-selfupdate -d run $uninstall_cmd"
    fi
    $uninstall_cmd 2>/dev/null || true
    rm -f /etc/zypp/repos.d/rancher-k3s-common*.repo
fi

echo "K3s uninstall completed successfully"
