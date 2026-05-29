#!/bin/bash
set -euo pipefail

# ==============================
# HQ-RTR для ALT Linux
# ==============================
# Перед запуском проверь имена интерфейсов командой: ip -br a
# ISP_IF - интерфейс в сторону ISP
# LAN_IF - интерфейс в сторону HQ-SW, trunk VLAN 100/200/999

ISP_IF="ens192"
LAN_IF="ens224"

RTR_WAN_IP="172.16.4.2/28"
RTR_WAN_GW="172.16.4.1"

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

DOMAIN="au-team.irpo"
HQ_DNS="192.168.10.2"
TIMEZONE="Asia/Novosibirsk"
NET_ADMIN_PASS='P@$$word'

# Поставь 1, когда будешь делать GRE/OSPF до BR-RTR.
# Пока можно оставить 0, чтобы HQ-RTR работал без BR-RTR.
ENABLE_GRE_OSPF="0"
GRE_IF="gre1"
GRE_LOCAL="172.16.4.2"
GRE_REMOTE="172.16.5.2"
GRE_IP="172.16.100.2/29"
GRE_NET="172.16.100.0/29"
OSPF_KEY="1245"

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
    rm -f "/etc/net/ifaces/${iface}/ipv4route"
  fi

  if [ -n "$dns" ]; then
    echo "nameserver $dns" > "/etc/net/ifaces/${iface}/resolv.conf"
  else
    rm -f "/etc/net/ifaces/${iface}/resolv.conf"
  fi
}

write_vlan_iface() {
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

need_root

echo "[1/10] Проверяю интерфейсы..."
for i in "$ISP_IF" "$LAN_IF"; do
  if ! iface_exists "$i"; then
    echo "ОШИБКА: интерфейс $i не найден. Проверь ip -br a и поменяй переменные в начале скрипта."
    exit 1
  fi
done

echo "[2/10] Ставлю hostname, пакеты и часовой пояс..."
hostnamectl set-hostname hq-rtr.au-team.irpo || true
apt-get update || true
apt-get install -y tzdata iptables iproute2 dhcp-server bind-utils wget sudo frr || true
timedatectl set-timezone "$TIMEZONE" || true

echo "[3/10] Бэкаплю старые настройки..."
BACKUP_DIR="/root/hq-rtr-backup-$(date +%F-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -a /etc/net/ifaces "$BACKUP_DIR/ifaces" 2>/dev/null || true
cp -a /etc/net/sysctl.conf "$BACKUP_DIR/sysctl.conf" 2>/dev/null || true
cp -a /etc/sysconfig/iptables "$BACKUP_DIR/iptables" 2>/dev/null || true
cp -a /etc/dhcp/dhcpd.conf "$BACKUP_DIR/dhcpd.conf" 2>/dev/null || true
cp -a /etc/sysconfig/dhcpd "$BACKUP_DIR/dhcpd-sysconfig" 2>/dev/null || true

echo "[4/10] Настраиваю WAN в сторону ISP..."
write_eth_iface "$ISP_IF" "$RTR_WAN_IP" "$RTR_WAN_GW" "8.8.8.8"

echo "[5/10] Настраиваю физический trunk-интерфейс и VLAN 100/200/999..."
mkdir -p "/etc/net/ifaces/${LAN_IF}"
cat > "/etc/net/ifaces/${LAN_IF}/options" <<CFG
TYPE=eth
BOOTPROTO=static
DISABLED=no
ONBOOT=yes
CONFIG_IPV4=no
CFG
rm -f "/etc/net/ifaces/${LAN_IF}/ipv4address" "/etc/net/ifaces/${LAN_IF}/ipv4route" 2>/dev/null || true

write_vlan_iface "$LAN_IF" "$VLAN100_ID" "$VLAN100_IP"
write_vlan_iface "$LAN_IF" "$VLAN200_ID" "$VLAN200_IP"
write_vlan_iface "$LAN_IF" "$VLAN999_ID" "$VLAN999_IP"

echo "[5.5/10] Перезапускаю сеть перед установкой пакетов..."
systemctl restart network || true
apt-get update || true
apt-get install -y tzdata iptables iproute2 dhcp-server bind-utils wget sudo frr || true
timedatectl set-timezone "$TIMEZONE" || true

echo "[6/10] Включаю маршрутизацию IPv4..."
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

echo "[7/10] Настраиваю NAT для HQ-сетей..."
for net in "$VLAN100_NET" "$VLAN200_NET" "$VLAN999_NET"; do
  iptables -t nat -D POSTROUTING -o "$ISP_IF" -s "$net" -j MASQUERADE 2>/dev/null || true
  iptables -t nat -A POSTROUTING -o "$ISP_IF" -s "$net" -j MASQUERADE
  iptables -D FORWARD -s "$net" -o "$ISP_IF" -j ACCEPT 2>/dev/null || true
  iptables -A FORWARD -s "$net" -o "$ISP_IF" -j ACCEPT
done
iptables -D FORWARD -i "$ISP_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -i "$ISP_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT
mkdir -p /etc/sysconfig
iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables 2>/dev/null || true

echo "[8/10] Настраиваю DHCP для HQ-CLI во VLAN200..."
mkdir -p /etc/dhcp /etc/sysconfig
cat > /etc/dhcp/dhcpd.conf <<CFG
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

echo "[9/10] Создаю net_admin с sudo без пароля..."
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
if command -v visudo >/dev/null 2>&1; then
  visudo -cf /etc/sudoers >/dev/null || echo "ВНИМАНИЕ: проверь /etc/sudoers вручную"
fi

echo "[10/10] Опционально GRE/OSPF..."
if [ "$ENABLE_GRE_OSPF" = "1" ]; then
  mkdir -p "/etc/net/ifaces/${GRE_IF}"
  cat > "/etc/net/ifaces/${GRE_IF}/options" <<CFG
TUNLOCAL=${GRE_LOCAL}
TUNREMOTE=${GRE_REMOTE}
TUNTYPE=gre
TYPE=iptun
TUNOPTIONS='ttl 64'
HOST=${ISP_IF}
DISABLED=no
ONBOOT=yes
CONFIG_IPV4=yes
CFG
  echo "$GRE_IP" > "/etc/net/ifaces/${GRE_IF}/ipv4address"

  sed -i 's/^ospfd=.*/ospfd=yes/' /etc/frr/daemons 2>/dev/null || true
  systemctl enable --now frr 2>/dev/null || true
  systemctl restart frr 2>/dev/null || true

  vtysh <<VTY || true
conf t
router ospf
 passive-interface default
 network ${GRE_NET} area 0
 network ${VLAN100_NET} area 0
 network ${VLAN200_NET} area 0
 network ${VLAN999_NET} area 0
 area 0 authentication
exit
interface ${GRE_IF}
 no ip ospf passive
 ip ospf authentication-key ${OSPF_KEY}
exit
end
write
VTY
fi

echo "Перезапускаю сеть и службы..."
systemctl restart network
systemctl restart dhcpd 2>/dev/null || true
[ "$ENABLE_GRE_OSPF" = "1" ] && systemctl restart frr 2>/dev/null || true

echo "Готово: HQ-RTR настроен. Проверка:"
echo "  ip -br a"
echo "  ip route"
echo "  iptables -t nat -L -n -v"
echo "  systemctl status dhcpd --no-pager"
echo "  journalctl -u dhcpd -n 30 --no-pager"
