#!/bin/bash
set -euo pipefail

# ==============================
# ISP для ALT Linux / ALT JeOS
# ==============================
# Перед запуском проверь имена интерфейсов командой: ip -br a
# WAN_IF  - интерфейс в интернет/провайдера, получает DHCP
# HQ_IF   - интерфейс в сторону HQ-RTR
# BR_IF   - интерфейс в сторону BR-RTR

WAN_IF="ens192"
HQ_IF="ens224"
BR_IF="ens256"

HQ_NET="172.16.4.0/28"
HQ_ISP_IP="172.16.4.1/28"
BR_NET="172.16.5.0/28"
BR_ISP_IP="172.16.5.1/28"
TIMEZONE="Asia/Novosibirsk"

need_root() {
  if [ "${EUID}" -ne 0 ]; then
    echo "Запусти скрипт от root: su - или sudo bash $0"
    exit 1
  fi
}

iface_exists() {
  ip link show "$1" >/dev/null 2>&1
}

write_eth_iface() {
  local iface="$1"
  local bootproto="$2"
  local ipaddr="${3:-}"

  mkdir -p "/etc/net/ifaces/${iface}"
  cat > "/etc/net/ifaces/${iface}/options" <<CFG
TYPE=eth
BOOTPROTO=${bootproto}
DISABLED=no
ONBOOT=yes
CONFIG_IPV4=yes
CFG

  if [ -n "${ipaddr}" ]; then
    echo "${ipaddr}" > "/etc/net/ifaces/${iface}/ipv4address"
  else
    rm -f "/etc/net/ifaces/${iface}/ipv4address"
  fi
}

need_root

echo "[1/7] Проверяю интерфейсы..."
for i in "$WAN_IF" "$HQ_IF" "$BR_IF"; do
  if ! iface_exists "$i"; then
    echo "ОШИБКА: интерфейс $i не найден. Проверь ip -br a и поменяй переменные в начале скрипта."
    exit 1
  fi
done

echo "[2/7] Ставлю hostname и часовой пояс..."
hostnamectl set-hostname isp || true
apt-get update || true
apt-get install -y tzdata iptables iproute2 || true
timedatectl set-timezone "$TIMEZONE" || true

echo "[3/7] Бэкаплю старые настройки сети..."
BACKUP_DIR="/root/net-backup-$(date +%F-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -a /etc/net/ifaces "$BACKUP_DIR/ifaces" 2>/dev/null || true
cp -a /etc/net/sysctl.conf "$BACKUP_DIR/sysctl.conf" 2>/dev/null || true
cp -a /etc/sysconfig/iptables "$BACKUP_DIR/iptables" 2>/dev/null || true

echo "[4/7] Настраиваю интерфейсы ISP..."
write_eth_iface "$WAN_IF" "dhcp" ""
write_eth_iface "$HQ_IF" "static" "$HQ_ISP_IP"
write_eth_iface "$BR_IF" "static" "$BR_ISP_IP"

echo "[4.5/7] Перезапускаю сеть перед установкой пакетов..."
systemctl restart network || true
apt-get update || true
apt-get install -y tzdata iptables iproute2 || true
timedatectl set-timezone "$TIMEZONE" || true

echo "[5/7] Включаю маршрутизацию IPv4..."
mkdir -p /etc/net
if grep -q '^#\?net.ipv4.ip_forward' /etc/net/sysctl.conf 2>/dev/null; then
  sed -i 's/^#\?net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
else
  echo 'net.ipv4.ip_forward = 1' >> /etc/net/sysctl.conf
fi
if grep -q '^#\?net.ipv4.ip_forward' /etc/sysctl.conf 2>/dev/null; then
  sed -i 's/^#\?net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
else
  echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null || true

echo "[6/7] Настраиваю NAT на ISP..."
iptables -t nat -D POSTROUTING -o "$WAN_IF" -s "$HQ_NET" -j MASQUERADE 2>/dev/null || true
iptables -t nat -D POSTROUTING -o "$WAN_IF" -s "$BR_NET" -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -o "$WAN_IF" -s "$HQ_NET" -j MASQUERADE
iptables -t nat -A POSTROUTING -o "$WAN_IF" -s "$BR_NET" -j MASQUERADE

iptables -D FORWARD -i "$HQ_IF" -o "$WAN_IF" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$BR_IF" -o "$WAN_IF" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$WAN_IF" -o "$HQ_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$WAN_IF" -o "$BR_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -i "$HQ_IF" -o "$WAN_IF" -j ACCEPT
iptables -A FORWARD -i "$BR_IF" -o "$WAN_IF" -j ACCEPT
iptables -A FORWARD -i "$WAN_IF" -o "$HQ_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -i "$WAN_IF" -o "$BR_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT

mkdir -p /etc/sysconfig
iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables 2>/dev/null || true

echo "[7/7] Перезапускаю сеть..."
systemctl restart network

echo "Готово: ISP настроен. Проверка:"
echo "  ip -br a"
echo "  ip route"
echo "  iptables -t nat -L -n -v"
