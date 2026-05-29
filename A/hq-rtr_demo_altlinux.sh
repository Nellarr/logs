#!/bin/bash
set -euo pipefail

# ============================================================
# HQ-RTR — ALT Linux
# Данные DEMO:
#   WAN к ISP: 172.16.1.2/28, gateway 172.16.1.1
#   VLAN100 HQ-SRV: 192.168.10.1/26
#   VLAN200 HQ-CLI: 192.168.20.1/28 + DHCP для HQ-CLI
#   VLAN999 MGMT:   192.168.99.1/29
#   GRE к BR-RTR:   local 172.16.1.2, remote 172.16.2.2, tunnel IP 172.16.100.2/29
#   OSPF area 0, key 1245
# ============================================================
# СНАЧАЛА проверь интерфейсы: ip -br a
# WAN_IF — интерфейс в сторону ISP
# LAN_IF — интерфейс trunk в сторону HQ-SW

WAN_IF="enp0s3"
LAN_IF="enp0s8

WAN_IP="172.16.1.2/28"
WAN_GW="172.16.1.1"

VLAN100_ID="100"
VLAN100_IP="192.168.10.1/26"
VLAN100_NET="192.168.10.0/26"

VLAN200_ID="200"
VLAN200_IP="192.168.20.1/28"
VLAN200_NET="192.168.20.0/28"
DHCP_RANGE_START="192.168.20.2"
DHCP_RANGE_END="192.168.20.14"

VLAN999_ID="999"
VLAN999_IP="192.168.99.1/29"
VLAN999_NET="192.168.99.0/29"

BR_LAN_NET="192.168.30.0/27"
DOMAIN="au-team.irpo"
HQ_DNS="192.168.10.2"
TIMEZONE="Asia/Novosibirsk"
NET_ADMIN_PASS='P@$$word'

GRE_IF="gre1"
GRE_LOCAL="172.16.1.2"
GRE_REMOTE="172.16.2.2"
GRE_IP="172.16.100.2/29"
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
  local backup_dir="/root/hq-rtr-backup-$(date +%F-%H%M%S)"
  mkdir -p "$backup_dir"
  cp -a /etc/net/ifaces "$backup_dir/ifaces" 2>/dev/null || true
  cp -a /etc/net/sysctl.conf "$backup_dir/sysctl.conf" 2>/dev/null || true
  cp -a /etc/sysconfig/iptables "$backup_dir/iptables" 2>/dev/null || true
  cp -a /etc/dhcp/dhcpd.conf "$backup_dir/dhcpd.conf" 2>/dev/null || true
  cp -a /etc/sysconfig/dhcpd "$backup_dir/dhcpd-sysconfig" 2>/dev/null || true
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

write_eth_trunk_parent() {
  local iface="$1"
  mkdir -p "/etc/net/ifaces/${iface}"
  cat > "/etc/net/ifaces/${iface}/options" <<CFG
TYPE=eth
BOOTPROTO=static
DISABLED=no
ONBOOT=yes
CONFIG_IPV4=no
CFG
  rm -f "/etc/net/ifaces/${iface}/ipv4address" "/etc/net/ifaces/${iface}/ipv4route" 2>/dev/null || true
}

write_vlan_static() {
  local parent="$1"
  local vid="$2"
  local ipaddr="$3"
  local iface="${parent}.${vid}"

  mkdir -p "/etc/net/ifaces/${iface}"
  cat > "/etc/net/ifaces/${iface}/options" <<CFG
TYPE=vlan
HOST=${parent}
VID=${vid}
DISABLED=no
BOOTPROTO=static
ONBOOT=yes
CONFIG_IPV4=yes
CFG
  echo "$ipaddr" > "/etc/net/ifaces/${iface}/ipv4address"
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
  for net in "$VLAN100_NET" "$VLAN200_NET" "$VLAN999_NET"; do
    iptables -t nat -D POSTROUTING -o "$WAN_IF" -s "$net" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -s "$net" -o "$WAN_IF" -j ACCEPT 2>/dev/null || true
    iptables -t nat -A POSTROUTING -o "$WAN_IF" -s "$net" -j MASQUERADE
    iptables -A FORWARD -s "$net" -o "$WAN_IF" -j ACCEPT
  done
  iptables -D FORWARD -i "$WAN_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
  iptables -A FORWARD -i "$WAN_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables-save > /etc/sysconfig/iptables
  systemctl enable --now iptables 2>/dev/null || true
}

configure_dhcp() {
  mkdir -p /etc/dhcp /etc/sysconfig
  cat > /etc/dhcp/dhcpd.conf <<CFG
# DHCP для HQ-CLI во VLAN200
# Шлюз исключён из выдачи: 192.168.20.1

default-lease-time 600;
max-lease-time 7200;
authoritative;
option domain-name "${DOMAIN}";
option domain-name-servers ${HQ_DNS}, 8.8.8.8;

subnet 192.168.20.0 netmask 255.255.255.240 {
  range ${DHCP_RANGE_START} ${DHCP_RANGE_END};
  option routers 192.168.20.1;
  option broadcast-address 192.168.20.15;
}
CFG
  cat > /etc/sysconfig/dhcpd <<CFG
DHCPDARGS=${LAN_IF}.${VLAN200_ID}
CFG
  systemctl enable dhcpd 2>/dev/null || true
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
  # zebra обычно нужен FRR для маршрутов.
  if grep -q '^zebra=' /etc/frr/daemons; then
    sed -i 's/^zebra=.*/zebra=yes/' /etc/frr/daemons
  else
    echo 'zebra=yes' >> /etc/frr/daemons
  fi

  cat > /etc/frr/frr.conf <<CFG
frr defaults traditional
hostname hq-rtr
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
 network ${VLAN100_NET} area 0
 network ${VLAN200_NET} area 0
 network ${VLAN999_NET} area 0
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

echo "[1/12] Проверка интерфейсов..."
for i in "$WAN_IF" "$LAN_IF"; do
  if ! iface_exists "$i"; then
    echo "ОШИБКА: интерфейс $i не найден. Посмотри ip -br a и поменяй переменные сверху."
    exit 1
  fi
done

echo "[2/12] Hostname, пакеты, время..."
hostnamectl set-hostname hq-rtr.au-team.irpo || true
apt-get update || true
apt-get install -y tzdata iptables iproute2 dhcp-server bind-utils wget sudo frr || true
timedatectl set-timezone "$TIMEZONE" || true

backup_configs

echo "[3/12] WAN к ISP..."
write_eth_static "$WAN_IF" "$WAN_IP" "$WAN_GW" "8.8.8.8"

echo "[4/12] Trunk и VLAN 100/200/999..."
write_eth_trunk_parent "$LAN_IF"
write_vlan_static "$LAN_IF" "$VLAN100_ID" "$VLAN100_IP"
write_vlan_static "$LAN_IF" "$VLAN200_ID" "$VLAN200_IP"
write_vlan_static "$LAN_IF" "$VLAN999_ID" "$VLAN999_IP"

echo "[5/12] GRE-туннель к BR-RTR..."
configure_gre

echo "[6/12] Перезапуск сети..."
systemctl restart network || true

echo "[7/12] IPv4 forwarding..."
enable_ip_forward

echo "[8/12] NAT для HQ VLAN-сетей..."
configure_nat

echo "[9/12] DHCP для HQ-CLI во VLAN200..."
configure_dhcp

echo "[10/12] net_admin + sudo без пароля..."
configure_user

echo "[11/12] FRR/OSPF через GRE..."
configure_frr_ospf
systemctl restart frr 2>/dev/null || true
systemctl restart dhcpd 2>/dev/null || true

echo "[12/12] HQ-RTR готов. Проверка:"
echo "  ip -br a"
echo "  ip route"
echo "  ping 172.16.1.1"
echo "  ping 172.16.2.2"
echo "  vtysh -c 'show ip ospf neighbor'"
echo "  vtysh -c 'show ip route ospf'"
echo "  iptables -t nat -L -n -v"
