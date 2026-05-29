#!/bin/bash
set -e

MODE="$1"

# ===== НАСТРОЙКИ =====
DISK1="/dev/sdb"
DISK2="/dev/sdc"

MD_DEV="/dev/md0"
RAID_MOUNT="/raid"
NFS_DIR="/raid/nfs"

# Сюда впиши сеть, где находится HQ-CLI
# Пример: 172.16.1.0/28 или 192.168.10.0/24
HQ_CLI_NET="172.16.1.0/28"

# На HQ-CLI сюда впиши IP-адрес HQ-SRV
HQ_SRV_IP="172.16.1.2"
CLIENT_MOUNT="/mnt/nfs"
# =====================

need_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Запусти от root"
        exit 1
    fi
}

part_name() {
    if [[ "$1" =~ [0-9]$ ]]; then
        echo "${1}p1"
    else
        echo "${1}1"
    fi
}

enable_nfs_server() {
    if systemctl list-unit-files | grep -q '^nfs-server.service'; then
        systemctl enable --now nfs-server
        systemctl restart nfs-server
    elif systemctl list-unit-files | grep -q '^nfs.service'; then
        systemctl enable --now nfs
        systemctl restart nfs
    else
        echo "Не нашёл службу nfs или nfs-server"
        exit 1
    fi
}

server_setup() {
    need_root

    echo "ВНИМАНИЕ: диски $DISK1 и $DISK2 будут очищены!"
    read -p "Продолжить? Напиши yes: " OK
    if [ "$OK" != "yes" ]; then
        echo "Отмена"
        exit 1
    fi

    apt-get update
    apt-get install -y mdadm nfs-server rpcbind nfs-clients

    systemctl enable --now rpcbind || true

    umount "$RAID_MOUNT" 2>/dev/null || true
    mdadm --stop "$MD_DEV" 2>/dev/null || true

    wipefs -a "$DISK1"
    wipefs -a "$DISK2"

    parted -s "$DISK1" mklabel gpt
    parted -s "$DISK1" mkpart primary 1MiB 100%
    parted -s "$DISK1" set 1 raid on

    parted -s "$DISK2" mklabel gpt
    parted -s "$DISK2" mkpart primary 1MiB 100%
    parted -s "$DISK2" set 1 raid on

    partprobe "$DISK1"
    partprobe "$DISK2"
    sleep 2

    P1="$(part_name "$DISK1")"
    P2="$(part_name "$DISK2")"

    mdadm --create "$MD_DEV" --level=0 --raid-devices=2 "$P1" "$P2" --force

    mkdir -p /etc
    mdadm --detail --scan > /etc/mdadm.conf

    mkfs.ext4 -F "$MD_DEV"

    mkdir -p "$RAID_MOUNT"
    UUID="$(blkid -s UUID -o value "$MD_DEV")"

    cp /etc/fstab /etc/fstab.bak.$(date +%F_%H-%M-%S)
    grep -v "$RAID_MOUNT" /etc/fstab > /tmp/fstab.new
    echo "UUID=$UUID $RAID_MOUNT ext4 defaults,nofail 0 2" >> /tmp/fstab.new
    cat /tmp/fstab.new > /etc/fstab

    mount -a

    mkdir -p "$NFS_DIR"
    chmod 777 "$NFS_DIR"

    cp /etc/exports /etc/exports.bak.$(date +%F_%H-%M-%S) 2>/dev/null || true
    grep -v "$NFS_DIR" /etc/exports 2>/dev/null > /tmp/exports.new || true
    echo "$NFS_DIR $HQ_CLI_NET(rw,sync,no_subtree_check,no_root_squash)" >> /tmp/exports.new
    cat /tmp/exports.new > /etc/exports

    exportfs -ra
    enable_nfs_server

    echo
    echo "Готово на HQ-SRV"
    echo "RAID:"
    cat /proc/mdstat
    echo
    echo "Монтирование:"
    df -h "$RAID_MOUNT"
    echo
    echo "NFS export:"
    exportfs -v
}

client_setup() {
    need_root

    apt-get update
    apt-get install -y nfs-clients rpcbind

    systemctl enable --now rpcbind || true

    mkdir -p "$CLIENT_MOUNT"

    cp /etc/fstab /etc/fstab.bak.$(date +%F_%H-%M-%S)
    grep -v "$CLIENT_MOUNT" /etc/fstab > /tmp/fstab.new
    echo "$HQ_SRV_IP:$NFS_DIR $CLIENT_MOUNT nfs defaults,_netdev,nofail 0 0" >> /tmp/fstab.new
    cat /tmp/fstab.new > /etc/fstab

    mount -a

    echo
    echo "Готово на HQ-CLI"
    echo "Проверка:"
    df -h "$CLIENT_MOUNT"
    touch "$CLIENT_MOUNT/test_from_hq_cli.txt"
    ls -l "$CLIENT_MOUNT"
}

case "$MODE" in
    server)
        server_setup
        ;;
    client)
        client_setup
        ;;
    *)
        echo "Использование:"
        echo "  На HQ-SRV: ./setup_storage.sh server"
        echo "  На HQ-CLI: ./setup_storage.sh client"
        exit 1
        ;;
esac