#!/bin/bash
set -euo pipefail

# ============================================================
# HQ-SW — ALT Linux как L2-коммутатор VLAN-aware bridge
# Данные DEMO:
#   VLAN100 — HQ-SRV
#   VLAN200 — HQ-CLI
#   VLAN999 — управление
#
# ВАЖНО:
# В демо/решении HQ-SRV и HQ-CLI часто настраиваются через VLAN subinterface
# типа ens192.100 / ens192.200 / ens192.999, поэтому по умолчанию порты
# к серверу и клиенту сделаны TAGGED, а не access.
# ============================================================
# СНАЧАЛА проверь интерфейсы: ip -br a
# RTR_IF — trunk в сторону HQ-RTR
# SRV_IF — порт в сторону HQ-SRV, tagged VLAN 100 и 999
# CLI_IF — порт в сторону HQ-CLI, tagged VLAN 200 и 999

RTR_IF="enp0s3"
SRV_IF="enp0s8"
CLI_IF="enp0s9"
BRIDGE="br0"

MGMT_VLAN="999"
MGMT_IP="192.168.99.3/29"
MGMT_GW="192.168.99.1"
DNS_SERVER="192.168.10.2"
TIMEZONE="Asia/Novosibirsk"

# Если тебе нужно сделать порт к серверу/клиенту НЕ tagged, а обычным access,
# поменяй значения на "access".
SRV_PORT_MODE="tagged"   # tagged: VLAN100+999 tagged; access: VLAN100 untagged
CLI_PORT_MODE="tagged"   # tagged: VLAN200+999 tagged; access: VLAN200 untagged

need_root() {
  if [ "${EUID}" -ne 0 ]; then
    echo "ОШИБКА: запусти от root: su -  затем  bash $0"
    exit 1
  fi
}

iface_exists() {
  ip link show "$1" >/dev/null 2>&1
}

need_root

echo "[1/8] Проверка интерфейсов..."
for i in "$RTR_IF" "$SRV_IF" "$CLI_IF"; do
  if ! iface_exists "$i"; then
    echo "ОШИБКА: интерфейс $i не найден. Посмотри ip -br a и поменяй переменные сверху."
    exit 1
  fi
done

echo "[2/8] Hostname, пакеты, время..."
hostnamectl set-hostname hq-sw.au-team.irpo || true
apt-get update || true
apt-get install -y tzdata iproute2 bridge-utils || true
timedatectl set-timezone "$TIMEZONE" || true

echo "[3/8] Отключаю NetworkManager, если он есть..."
systemctl disable --now NetworkManager 2>/dev/null || true
systemctl disable --now Network-manager 2>/dev/null || true

echo "[4/8] Бэкап и минимальная настройка /etc/net/ifaces..."
BACKUP_DIR="/root/hq-sw-backup-$(date +%F-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -a /etc/net/ifaces "$BACKUP_DIR/ifaces" 2>/dev/null || true

for i in "$RTR_IF" "$SRV_IF" "$CLI_IF"; do
  mkdir -p "/etc/net/ifaces/$i"
  cat > "/etc/net/ifaces/$i/options" <<CFG
TYPE=eth
BOOTPROTO=static
DISABLED=no
ONBOOT=yes
CONFIG_IPV4=no
CFG
  rm -f "/etc/net/ifaces/$i/ipv4address" "/etc/net/ifaces/$i/ipv4route" 2>/dev/null || true
done

echo "[5/8] Создаю /usr/local/sbin/hq-sw-vlan.sh..."
cat > /usr/local/sbin/hq-sw-vlan.sh <<SWCFG
#!/bin/bash
set -euo pipefail

RTR_IF="${RTR_IF}"
SRV_IF="${SRV_IF}"
CLI_IF="${CLI_IF}"
BRIDGE="${BRIDGE}"
MGMT_VLAN="${MGMT_VLAN}"
MGMT_IP="${MGMT_IP}"
MGMT_GW="${MGMT_GW}"
DNS_SERVER="${DNS_SERVER}"
SRV_PORT_MODE="${SRV_PORT_MODE}"
CLI_PORT_MODE="${CLI_PORT_MODE}"

ip link set "\$BRIDGE.\$MGMT_VLAN" down 2>/dev/null || true
ip link del "\$BRIDGE.\$MGMT_VLAN" 2>/dev/null || true
ip link set "\$BRIDGE" down 2>/dev/null || true
ip link del "\$BRIDGE" 2>/dev/null || true

for i in "\$RTR_IF" "\$SRV_IF" "\$CLI_IF"; do
  ip addr flush dev "\$i" 2>/dev/null || true
  ip link set "\$i" up
done

ip link add name "\$BRIDGE" type bridge vlan_filtering 1
ip link set "\$BRIDGE" up
ip link set "\$RTR_IF" master "\$BRIDGE"
ip link set "\$SRV_IF" master "\$BRIDGE"
ip link set "\$CLI_IF" master "\$BRIDGE"

for i in "\$RTR_IF" "\$SRV_IF" "\$CLI_IF"; do
  bridge vlan del dev "\$i" vid 1 2>/dev/null || true
done
bridge vlan del dev "\$BRIDGE" vid 1 self 2>/dev/null || true

# Trunk к HQ-RTR: все VLAN tagged.
bridge vlan add dev "\$RTR_IF" vid 100
bridge vlan add dev "\$RTR_IF" vid 200
bridge vlan add dev "\$RTR_IF" vid 999

# Порт к HQ-SRV.
if [ "\$SRV_PORT_MODE" = "access" ]; then
  bridge vlan add dev "\$SRV_IF" vid 100 pvid untagged
else
  bridge vlan add dev "\$SRV_IF" vid 100
  bridge vlan add dev "\$SRV_IF" vid 999
fi

# Порт к HQ-CLI.
if [ "\$CLI_PORT_MODE" = "access" ]; then
  bridge vlan add dev "\$CLI_IF" vid 200 pvid untagged
else
  bridge vlan add dev "\$CLI_IF" vid 200
  bridge vlan add dev "\$CLI_IF" vid 999
fi

# Управление самим HQ-SW через VLAN999.
bridge vlan add dev "\$BRIDGE" vid 999 self
ip link add link "\$BRIDGE" name "\$BRIDGE.\$MGMT_VLAN" type vlan id "\$MGMT_VLAN"
ip addr add "\$MGMT_IP" dev "\$BRIDGE.\$MGMT_VLAN"
ip link set "\$BRIDGE.\$MGMT_VLAN" up
ip route replace default via "\$MGMT_GW" dev "\$BRIDGE.\$MGMT_VLAN" || true

if [ -n "\$DNS_SERVER" ]; then
  echo "nameserver \$DNS_SERVER" > /etc/resolv.conf
fi

bridge vlan show
ip -br a
SWCFG
chmod +x /usr/local/sbin/hq-sw-vlan.sh

echo "[6/8] Создаю systemd service..."
cat > /etc/systemd/system/hq-sw-vlan.service <<SERVICE
[Unit]
Description=HQ-SW Linux VLAN bridge
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hq-sw-vlan.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

echo "[7/8] Запуск bridge/vlan..."
systemctl daemon-reload
systemctl enable hq-sw-vlan.service
systemctl restart network 2>/dev/null || true
systemctl restart hq-sw-vlan.service

echo "[8/8] HQ-SW готов. Проверка:"
echo "  bridge vlan show"
echo "  ip -br a"
echo "  systemctl status hq-sw-vlan --no-pager"
echo "  ping 192.168.99.1"
