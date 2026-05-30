#!/usr/bin/env bash
# setup_dns_hq_srv_altlinux.sh
# DNS/BIND для DEMO 2026 на ALT Linux.
# Запускать НА HQ-SRV от root.

set -euo pipefail

# ====== НАСТРОЙКИ ДЕМО ======
DOMAIN="au-team.irpo"
DNS_SERVER_HOST="hq-srv"
DNS_SERVER_IP="192.168.10.2"

HQ_RTR_IP="192.168.10.1"
HQ_SRV_IP="192.168.10.2"
HQ_CLI_IP="192.168.20.2"
BR_RTR_IP="192.168.30.1"
BR_SRV_IP="192.168.30.2"

# В таблице демо docker/web указаны как A-записи. Если у тебя они должны быть на HQ-SRV,
# поменяй ниже на 192.168.10.2. Сейчас стоят на HQ-RTR.
DOCKER_IP="192.168.10.1"
WEB_IP="192.168.10.1"

FORWARDER_1="8.8.8.8"
FORWARDER_2="1.1.1.1"

BIND_DIR="/etc/bind"
BACKUP_DIR="/root/bind_backup_$(date +%F_%H-%M-%S)"

# ====== ПРОВЕРКИ ======
if [[ "${EUID}" -ne 0 ]]; then
  echo "[ОШИБКА] Запусти скрипт от root"
  exit 1
fi

echo "[1/8] Установка bind и bind-utils..."
apt-get update || true
apt-get install -y bind bind-utils

mkdir -p "${BIND_DIR}"
mkdir -p "${BACKUP_DIR}"

# Бэкап старых файлов, если они есть
for f in options.conf local.conf db."${DOMAIN}" db.192.168.10 db.192.168.20 named.conf; do
  if [[ -f "${BIND_DIR}/${f}" ]]; then
    cp -a "${BIND_DIR}/${f}" "${BACKUP_DIR}/${f}.bak"
  fi
done

echo "[2/8] Создание /etc/bind/options.conf..."
cat > "${BIND_DIR}/options.conf" <<EOF_OPTIONS
acl "trusted" {
    127.0.0.1;
    192.168.10.0/26;
    192.168.20.0/28;
    192.168.30.0/27;
    192.168.99.0/29;
    172.16.100.0/29;
};

options {
    directory "/var/cache/bind";

    listen-on port 53 { any; };
    listen-on-v6 { none; };

    recursion yes;
    allow-query { trusted; };
    allow-recursion { trusted; };

    forwarders {
        ${FORWARDER_1};
        ${FORWARDER_2};
    };

    dnssec-validation no;
    auth-nxdomain no;
};
EOF_OPTIONS

echo "[3/8] Создание /etc/bind/local.conf со списком зон..."
cat > "${BIND_DIR}/local.conf" <<EOF_LOCAL
zone "${DOMAIN}" {
    type master;
    file "${BIND_DIR}/db.${DOMAIN}";
};

zone "10.168.192.in-addr.arpa" {
    type master;
    file "${BIND_DIR}/db.192.168.10";
};

zone "20.168.192.in-addr.arpa" {
    type master;
    file "${BIND_DIR}/db.192.168.20";
};
EOF_LOCAL

SERIAL="$(date +%Y%m%d)01"

echo "[4/8] Создание прямой зоны /etc/bind/db.${DOMAIN}..."
cat > "${BIND_DIR}/db.${DOMAIN}" <<EOF_ZONE
\$TTL 86400
@       IN SOA  ${DNS_SERVER_HOST}.${DOMAIN}. admin.${DOMAIN}. (
                ${SERIAL} ; Serial
                3600       ; Refresh
                1800       ; Retry
                604800     ; Expire
                86400 )    ; Minimum TTL

@       IN NS   ${DNS_SERVER_HOST}.${DOMAIN}.

hq-rtr  IN A    ${HQ_RTR_IP}
hq-srv  IN A    ${HQ_SRV_IP}
hq-cli  IN A    ${HQ_CLI_IP}
br-rtr  IN A    ${BR_RTR_IP}
br-srv  IN A    ${BR_SRV_IP}
docker  IN A    ${DOCKER_IP}
web     IN A    ${WEB_IP}
EOF_ZONE

echo "[5/8] Создание обратной зоны для 192.168.10.0/26..."
cat > "${BIND_DIR}/db.192.168.10" <<EOF_REV10
\$TTL 86400
@       IN SOA  ${DNS_SERVER_HOST}.${DOMAIN}. admin.${DOMAIN}. (
                ${SERIAL} ; Serial
                3600       ; Refresh
                1800       ; Retry
                604800     ; Expire
                86400 )    ; Minimum TTL

@       IN NS   ${DNS_SERVER_HOST}.${DOMAIN}.

1       IN PTR  hq-rtr.${DOMAIN}.
2       IN PTR  hq-srv.${DOMAIN}.
EOF_REV10

echo "[6/8] Создание обратной зоны для 192.168.20.0/28..."
cat > "${BIND_DIR}/db.192.168.20" <<EOF_REV20
\$TTL 86400
@       IN SOA  ${DNS_SERVER_HOST}.${DOMAIN}. admin.${DOMAIN}. (
                ${SERIAL} ; Serial
                3600       ; Refresh
                1800       ; Retry
                604800     ; Expire
                86400 )    ; Minimum TTL

@       IN NS   ${DNS_SERVER_HOST}.${DOMAIN}.

2       IN PTR  hq-cli.${DOMAIN}.
EOF_REV20

# Если есть named.conf, убеждаемся, что он подключает options.conf и local.conf.
# На ALT Linux обычно это уже сделано, но на пустой системе лучше подстраховаться.
if [[ -f "${BIND_DIR}/named.conf" ]]; then
  if ! grep -q "options.conf" "${BIND_DIR}/named.conf"; then
    echo "include \"${BIND_DIR}/options.conf\";" >> "${BIND_DIR}/named.conf"
  fi
  if ! grep -q "local.conf" "${BIND_DIR}/named.conf"; then
    echo "include \"${BIND_DIR}/local.conf\";" >> "${BIND_DIR}/named.conf"
  fi
else
  cat > "${BIND_DIR}/named.conf" <<EOF_NAMED
include "${BIND_DIR}/options.conf";
include "${BIND_DIR}/local.conf";
EOF_NAMED
fi

# Права
if getent group named >/dev/null; then
  chown root:named "${BIND_DIR}"/options.conf "${BIND_DIR}"/local.conf "${BIND_DIR}"/db.${DOMAIN} "${BIND_DIR}"/db.192.168.10 "${BIND_DIR}"/db.192.168.20 "${BIND_DIR}"/named.conf || true
fi
chmod 0644 "${BIND_DIR}"/options.conf "${BIND_DIR}"/local.conf "${BIND_DIR}"/db.${DOMAIN} "${BIND_DIR}"/db.192.168.10 "${BIND_DIR}"/db.192.168.20 "${BIND_DIR}"/named.conf

echo "[7/8] Проверка конфигурации BIND..."
named-checkconf "${BIND_DIR}/named.conf"
named-checkzone "${DOMAIN}" "${BIND_DIR}/db.${DOMAIN}"
named-checkzone "10.168.192.in-addr.arpa" "${BIND_DIR}/db.192.168.10"
named-checkzone "20.168.192.in-addr.arpa" "${BIND_DIR}/db.192.168.20"

# Определяем имя службы
BIND_SERVICE="bind"
if systemctl list-unit-files 2>/dev/null | grep -q '^named\.service'; then
  BIND_SERVICE="named"
elif systemctl list-unit-files 2>/dev/null | grep -q '^bind\.service'; then
  BIND_SERVICE="bind"
fi

echo "[8/8] Запуск службы ${BIND_SERVICE}..."
systemctl enable --now "${BIND_SERVICE}"
systemctl restart "${BIND_SERVICE}"

cat <<EOF_DONE

ГОТОВО. DNS настроен на HQ-SRV.

Проверка на HQ-SRV:
  nslookup hq-rtr.${DOMAIN} 127.0.0.1
  nslookup hq-srv.${DOMAIN} 127.0.0.1
  nslookup hq-cli.${DOMAIN} 127.0.0.1
  nslookup br-rtr.${DOMAIN} 127.0.0.1
  nslookup br-srv.${DOMAIN} 127.0.0.1
  nslookup 192.168.10.1 127.0.0.1
  nslookup 192.168.10.2 127.0.0.1
  nslookup 192.168.20.2 127.0.0.1

Старые конфиги сохранены в:
  ${BACKUP_DIR}

Важно: на HQ-CLI и других машинах DNS должен быть ${DNS_SERVER_IP}.
EOF_DONE
