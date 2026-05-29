#!/bin/bash
set -euo pipefail

# ============================================================
# ISP — ALT Linux / ALT JeOS
# Данные DEMO:
#   WAN/Internet: DHCP от провайдера
#   ISP <-> HQ-RTR: 172.16.1.0/28, ISP = 172.16.1.1, HQ-RTR = 172.16.1.2
#   ISP <-> BR-RTR: 172.16.2.0/28, ISP = 172.16.2.1, BR-RTR = 172.16.2.2
# ============================================================
# СНАЧАЛА проверь интерфейсы: ip -br a
# WAN_IF — в интернет/провайдера
# HQ_IF  — в сторону HQ-RTR
# BR_IF  — в сторону BR-RTR

WAN_IF="enp0s3"
HQ_IF="enp0s8"
BR_IF="enp0s9"

HQ_NET="172.16.1.0/28"
HQ_ISP_IP="172.16.1.1/28"
BR_NET="172.16.2.0/28"
BR_ISP_IP="172.16.2.1/28"
TIMEZONE="Asia/Novosibirsk"

need_root() {
  if [ "${EUID}" -ne 0 ]; then
    echo "ОШИБКА: запусти от root: su -  затем  bash $0"
    exit 1
  fi
}

iface_exists() {
  ip link show "$1" >/dev/null 2>&1
}

backup_configs() {
  local backup_dir="/root/isp-backup-$(date +%F-%H%M%S)"
  mkdir -p "$backup_dir"
  cp -a /etc/net/ifaces "$backup_dir/ifaces" 2>/dev/null || true
  cp -a /etc/net/sysctl.conf "$backup_dir/sysctl.conf" 2>/dev/null || true
  cp -a /etc/sysconfig/iptables "$backup_dir/iptables" 2>/dev/null || true
  echo "Бэкап старых настроек: $backup_dir"
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

  if [ -n "$ipaddr" ]; then
    echo "$ipaddr" > "/etc/net/ifaces/${iface}/ipv4address"
  else
    rm -f "/etc/net/ifaces/${iface}/ipv4address" "/etc/net/ifaces/${iface}/ipv4route" 2>/dev/null || true
  fi
}

enable_ip_forward() {
  mkdir -p /etc/net
  touch /etc/net/sysctl.conf /etc/sysctl.conf
  if grep -q '^#\?net.ipv4.ip_forward' /etc/net/sysctl.conf; then
    sed -i 's/^#\?net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
  else
    echo 'net.ipv4.ip_forward = 1' >> /etc/net/sysctl.conf
  fi
  if grep -q '^#\?net.ipv4.ip_forward' /etc/sysctl.conf; then
    sed -i 's/^#\?net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
  else
    echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
  fi
  sysctl -w net.ipv4.ip_forward=1 >/dev/null || true
}

need_root

echo "[1/7] Проверка интерфейсов..."
for i in "$WAN_IF" "$HQ_IF" "$BR_IF"; do
  if ! iface_exists "$i"; then
    echo "ОШИБКА: интерфейс $i не найден. Посмотри ip -br a и поменяй переменные сверху."
    exit 1
  fi
done

echo "[2/7] Hostname, пакеты, время..."
hostnamectl set-hostname isp || true
apt-get update || true
apt-get install -y tzdata iptables iproute2 || true
timedatectl set-timezone "$TIMEZONE" || true

backup_configs

echo "[3/7] Настройка сети ISP..."
write_eth_iface "$WAN_IF" "dhcp" ""
write_eth_iface "$HQ_IF" "static" "$HQ_ISP_IP"
write_eth_iface "$BR_IF" "static" "$BR_ISP_IP"

# Важно: сначала сеть, чтобы WAN получил DHCP.
systemctl restart network || true

echo "[4/7] Включаю маршрутизацию IPv4..."
enable_ip_forward

echo "[5/7] Настраиваю NAT на ISP для сетей к HQ и BR..."
mkdir -p /etc/sysconfig

# Чистим старые такие же правила, чтобы повторный запуск не плодил дубли.
iptables -t nat -D POSTROUTING -o "$WAN_IF" -s "$HQ_NET" -j MASQUERADE 2>/dev/null || true
iptables -t nat -D POSTROUTING -o "$WAN_IF" -s "$BR_NET" -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i "$HQ_IF" -o "$WAN_IF" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$BR_IF" -o "$WAN_IF" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$WAN_IF" -o "$HQ_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$WAN_IF" -o "$BR_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$HQ_IF" -o "$BR_IF" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$BR_IF" -o "$HQ_IF" -j ACCEPT 2>/dev/null || true

iptables -t nat -A POSTROUTING -o "$WAN_IF" -s "$HQ_NET" -j MASQUERADE
iptables -t nat -A POSTROUTING -o "$WAN_IF" -s "$BR_NET" -j MASQUERADE
iptables -A FORWARD -i "$HQ_IF" -o "$WAN_IF" -j ACCEPT
iptables -A FORWARD -i "$BR_IF" -o "$WAN_IF" -j ACCEPT
iptables -A FORWARD -i "$WAN_IF" -o "$HQ_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -i "$WAN_IF" -o "$BR_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT

# Нужно для GRE между HQ-RTR и BR-RTR через ISP.
iptables -A FORWARD -i "$HQ_IF" -o "$BR_IF" -j ACCEPT
iptables -A FORWARD -i "$BR_IF" -o "$HQ_IF" -j ACCEPT

iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables 2>/dev/null || true

echo "[6/7] Финальный перезапуск сети..."
systemctl restart network || true

echo "[7/7] ISP готов. Проверка:"
echo "  ip -br a"
echo "  ip route"
echo "  sysctl net.ipv4.ip_forward"
echo "  iptables -t nat -L -n -v"
echo "  ping 172.16.1.2   # HQ-RTR, когда он будет настроен"
echo "  ping 172.16.2.2   # BR-RTR, когда он будет настроен"
