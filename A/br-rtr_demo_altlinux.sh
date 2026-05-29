#!/bin/bash
set -euo pipefail

# ============================================================
# BR-RTR — ALT Linux
# Данные DEMO:
#   WAN к ISP: 172.16.2.2/28, gateway 172.16.2.1
#   LAN BR-SRV: 192.168.30.1/27
#   GRE к HQ-RTR: local 172.16.2.2, remote 172.16.1.2, tunnel IP 172.16.100.1/29
#   OSPF area 0, key 1245
# ============================================================
# СНАЧАЛА проверь интерфейсы: ip -br a
# WAN_IF — интерфейс в сторону ISP
# LAN_IF — интерфейс в сторону BR-SRV / BR-SW

WAN_IF="enp0s8"
LAN_IF="enp0s9"

WAN_IP="172.16.2.2/28"
WAN_GW="172.16.2.1"

BR_LAN_IP="192.168.30.1/27"
BR_LAN_NET="192.168.30.0/27"

TIMEZONE="Europe/Moscow"
NET_ADMIN_PASS='P@$$word'

GRE_IF="gre1"
GRE_LOCAL="172.16.2.2"
GRE_REMOTE="172.16.1.2"
GRE_IP="172.16.100.1/29"
GRE_NET="172.16.100.0/29"
OSPF_KEY="1245"

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
  local backup_dir="/root/br-rtr-backup-$(date +%F-%H%M%S)"
  mkdir -p "$backup_dir"
  cp -a /etc/net/ifaces "$backup_dir/ifaces" 2>/dev/null || true
  cp -a /etc/net/sysctl.conf "$backup_dir/sysctl.conf" 2>/dev/null || true
  cp -a /etc/sysconfig/iptables "$backup_dir/iptables" 2>/dev/null || true
  cp -a /etc/frr "$backup_dir/frr" 2>/dev/null || true
  echo "Бэкап старых настроек: $backup_dir"
}

write_eth_static() {
  local iface="$1"
  local ipaddr="$2"
  local gateway="${3:-}"
  local dns="${4:-}"

  mkdir -p "/etc/net/ifaces/${iface}"
  cat > "/etc/net/ifaces/${iface}/options" <<CFG
TYPE=eth
BOOTPROTO=static
DISABLED=no
ONBOOT=yes
CONFIG_IPV4=yes
CFG
  echo "$ipaddr" > "/etc/net/ifaces/${iface}/ipv4address"

  if [ -n "$gateway" ]; then
    echo "default via $gateway" > "/etc/net/ifaces/${iface}/ipv4route"
  else
    rm -f "/etc/net/ifaces/${iface}/ipv4route" 2>/dev/null || true
  fi

  if [ -n "$dns" ]; then
    echo "nameserver $dns" > "/etc/net/ifaces/${iface}/resolv.conf"
  else
    rm -f "/etc/net/ifaces/${iface}/resolv.conf" 2>/dev/null || true
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

configure_nat() {
  mkdir -p /etc/sysconfig
  iptables -t nat -D POSTROUTING -o "$WAN_IF" -s "$BR_LAN_NET" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -s "$BR_LAN_NET" -o "$WAN_IF" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "$WAN_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

  iptables -t nat -A POSTROUTING -o "$WAN_IF" -s "$BR_LAN_NET" -j MASQUERADE
  iptables -A FORWARD -s "$BR_LAN_NET" -o "$WAN_IF" -j ACCEPT
  iptables -A FORWARD -i "$WAN_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT

  iptables-save > /etc/sysconfig/iptables
  systemctl enable --now iptables 2>/dev/null || true
}

configure_user() {
  if ! id net_admin >/dev/null 2>&1; then
    useradd -m net_admin
  fi
  echo "net_admin:${NET_ADMIN_PASS}" | chpasswd
  usermod -aG wheel net_admin 2>/dev/null || true
  mkdir -p /etc/sudoers.d
  cat > /etc/sudoers.d/90-net_admin <<'CFG'
net_admin ALL=(ALL:ALL) NOPASSWD: ALL
CFG
  chmod 440 /etc/sudoers.d/90-net_admin
}

configure_gre() {
  mkdir -p "/etc/net/ifaces/${GRE_IF}"
  cat > "/etc/net/ifaces/${GRE_IF}/options" <<CFG
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=${GRE_LOCAL}
TUNREMOTE=${GRE_REMOTE}
TUNOPTIONS='ttl 64'
HOST=${WAN_IF}
DISABLED=no
ONBOOT=yes
CONFIG_IPV4=yes
CFG
  echo "$GRE_IP" > "/etc/net/ifaces/${GRE_IF}/ipv4address"
}

configure_frr_ospf() {
  mkdir -p /etc/frr
  touch /etc/frr/daemons
  if grep -q '^ospfd=' /etc/frr/daemons; then
    sed -i 's/^ospfd=.*/ospfd=yes/' /etc/frr/daemons
  else
    echo 'ospfd=yes' >> /etc/frr/daemons
  fi
  if grep -q '^zebra=' /etc/frr/daemons; then
    sed -i 's/^zebra=.*/zebra=yes/' /etc/frr/daemons
  else
    echo 'zebra=yes' >> /etc/frr/daemons
  fi

  cat > /etc/frr/frr.conf <<CFG
frr defaults traditional
hostname br-rtr
log syslog informational
service integrated-vtysh-config
!
interface ${GRE_IF}
 ip ospf authentication
 ip ospf authentication-key ${OSPF_KEY}
 ip ospf network point-to-point
!
router ospf
 passive-interface default
 no passive-interface ${GRE_IF}
 network ${GRE_NET} area 0
 network ${BR_LAN_NET} area 0
 area 0 authentication
!
line vty
!
CFG
  chown -R frr:frr /etc/frr 2>/dev/null || true
  chmod 640 /etc/frr/frr.conf 2>/dev/null || true
  systemctl enable frr 2>/dev/null || true
}

need_root

echo "[1/10] Проверка интерфейсов..."
for i in "$WAN_IF" "$LAN_IF"; do
  if ! iface_exists "$i"; then
    echo "ОШИБКА: интерфейс $i не найден. Посмотри ip -br a и поменяй переменные сверху."
    exit 1
  fi
done

echo "[2/10] Hostname, пакеты, время..."
hostnamectl set-hostname br-rtr.au-team.irpo || true
apt-get update || true
apt-get install -y tzdata iptables iproute2 bind-utils wget sudo frr || true
timedatectl set-timezone "$TIMEZONE" || true

backup_configs

echo "[3/10] WAN к ISP..."
write_eth_static "$WAN_IF" "$WAN_IP" "$WAN_GW" "8.8.8.8"

echo "[4/10] LAN к BR-SRV..."
write_eth_static "$LAN_IF" "$BR_LAN_IP" "" "8.8.8.8"

echo "[5/10] GRE-туннель к HQ-RTR..."
configure_gre

echo "[6/10] Перезапуск сети..."
systemctl restart network || true

echo "[7/10] IPv4 forwarding + NAT..."
enable_ip_forward
configure_nat

echo "[8/10] net_admin + sudo без пароля..."
configure_user

echo "[9/10] FRR/OSPF через GRE..."
configure_frr_ospf
systemctl restart frr 2>/dev/null || true

echo "[10/10] BR-RTR готов. Проверка:"
echo "  ip -br a"
echo "  ip route"
echo "  ping 172.16.2.1"
echo "  ping 172.16.1.2"
echo "  vtysh -c 'show ip ospf neighbor'"
echo "  vtysh -c 'show ip route ospf'"
echo "  iptables -t nat -L -n -v"
