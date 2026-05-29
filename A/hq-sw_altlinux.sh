#!/bin/bash
set -euo pipefail

# ==============================
# HQ-SW для ALT Linux как L2-коммутатор
# ==============================
# Перед запуском проверь имена интерфейсов командой: ip -br a
# TRUNK_IF - порт в сторону HQ-RTR, trunk VLAN 100/200/999
# SRV_IF   - access-порт в сторону HQ-SRV, VLAN100
# CLI_IF   - access-порт в сторону HQ-CLI, VLAN200
# MGMT_IP  - IP самого HQ-SW в VLAN999. Я поставил .3, чтобы не конфликтовать с HQ-RTR .1 и HQ-CLI .2.

TRUNK_IF="ens192"
SRV_IF="ens224"
CLI_IF="ens256"
BRIDGE="br0"

MGMT_VLAN="999"
MGMT_IP="192.168.99.3/29"
MGMT_GW="192.168.99.1"
DNS_SERVER="192.168.10.2"
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

need_root

echo "[1/7] Проверяю интерфейсы..."
for i in "$TRUNK_IF" "$SRV_IF" "$CLI_IF"; do
  if ! iface_exists "$i"; then
    echo "ОШИБКА: интерфейс $i не найден. Проверь ip -br a и поменяй переменные в начале скрипта."
    exit 1
  fi
done

echo "[2/7] Ставлю hostname, пакеты и часовой пояс..."
hostnamectl set-hostname hq-sw.au-team.irpo || true
apt-get update || true
apt-get install -y tzdata iproute2 bridge-utils || true
timedatectl set-timezone "$TIMEZONE" || true

echo "[3/7] Отключаю NetworkManager, если он есть, чтобы не мешал bridge/vlan..."
systemctl disable --now NetworkManager 2>/dev/null || true
systemctl disable --now Network-manager 2>/dev/null || true

echo "[4/7] Создаю исполняемый скрипт коммутатора /usr/local/sbin/hq-sw-vlan.sh ..."
cat > /usr/local/sbin/hq-sw-vlan.sh <<SWCFG
#!/bin/bash
set -euo pipefail

TRUNK_IF="${TRUNK_IF}"
SRV_IF="${SRV_IF}"
CLI_IF="${CLI_IF}"
BRIDGE="${BRIDGE}"
MGMT_VLAN="${MGMT_VLAN}"
MGMT_IP="${MGMT_IP}"
MGMT_GW="${MGMT_GW}"
DNS_SERVER="${DNS_SERVER}"

# Чистим старую временную конфигурацию
ip link set "\$BRIDGE.\$MGMT_VLAN" down 2>/dev/null || true
ip link del "\$BRIDGE.\$MGMT_VLAN" 2>/dev/null || true
ip link set "\$BRIDGE" down 2>/dev/null || true
ip link del "\$BRIDGE" 2>/dev/null || true

# Поднимаем физические интерфейсы без IP
for i in "\$TRUNK_IF" "\$SRV_IF" "\$CLI_IF"; do
  ip addr flush dev "\$i" 2>/dev/null || true
  ip link set "\$i" up
 done

# Создаём VLAN-aware bridge
ip link add name "\$BRIDGE" type bridge vlan_filtering 1
ip link set "\$BRIDGE" up

# Добавляем порты в bridge
ip link set "\$TRUNK_IF" master "\$BRIDGE"
ip link set "\$SRV_IF" master "\$BRIDGE"
ip link set "\$CLI_IF" master "\$BRIDGE"

# Убираем VLAN 1 по умолчанию с портов, где получится
for i in "\$TRUNK_IF" "\$SRV_IF" "\$CLI_IF"; do
  bridge vlan del dev "\$i" vid 1 2>/dev/null || true
 done
bridge vlan del dev "\$BRIDGE" vid 1 self 2>/dev/null || true

# TRUNK к HQ-RTR: VLAN 100/200/999 идут tagged
bridge vlan add dev "\$TRUNK_IF" vid 100
bridge vlan add dev "\$TRUNK_IF" vid 200
bridge vlan add dev "\$TRUNK_IF" vid 999

# Access-порт HQ-SRV: untagged VLAN100
bridge vlan add dev "\$SRV_IF" vid 100 pvid untagged

# Access-порт HQ-CLI: untagged VLAN200
bridge vlan add dev "\$CLI_IF" vid 200 pvid untagged

# Управление самим HQ-SW через VLAN999
bridge vlan add dev "\$BRIDGE" vid 999 self
ip link add link "\$BRIDGE" name "\$BRIDGE.\$MGMT_VLAN" type vlan id "\$MGMT_VLAN"
ip addr add "\$MGMT_IP" dev "\$BRIDGE.\$MGMT_VLAN"
ip link set "\$BRIDGE.\$MGMT_VLAN" up
ip route replace default via "\$MGMT_GW" dev "\$BRIDGE.\$MGMT_VLAN" || true

# DNS для самого свитча
if [ -n "\$DNS_SERVER" ]; then
  echo "nameserver \$DNS_SERVER" > /etc/resolv.conf
fi

bridge vlan show
ip -br a
SWCFG
chmod +x /usr/local/sbin/hq-sw-vlan.sh

echo "[5/7] Создаю systemd-сервис автозапуска..."
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

echo "[6/7] Делаю минимальные /etc/net/ifaces, чтобы интерфейсы поднимались..."
for i in "$TRUNK_IF" "$SRV_IF" "$CLI_IF"; do
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

echo "[7/7] Запускаю switch-конфигурацию..."
systemctl daemon-reload
systemctl enable hq-sw-vlan.service
systemctl restart network 2>/dev/null || true
systemctl restart hq-sw-vlan.service

echo "Готово: HQ-SW настроен. Проверка:"
echo "  bridge vlan show"
echo "  ip -br a"
echo "  systemctl status hq-sw-vlan --no-pager"
