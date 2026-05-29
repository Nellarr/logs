bash
#!/bin/bash
set -e

echo "=== Установка и настройка chrony (NTP-сервер) на ISP ==="

# Установка chrony
apt-get update && apt-get install -y chrony

# Резервное копирование оригинального конфига (если ещё не сделано)
[ -f /etc/chrony.conf ] && cp -n /etc/chrony.conf /etc/chrony.conf.bak

# Конфигурация chrony
cat > /etc/chrony.conf <<'EOF'
# Внешние источники времени
pool 2.alt.pool.ntp.org iburst
pool 3.alt.pool.ntp.org iburst

# Разрешить доступ клиентам из локальных сетей ISP
allow 172.16.1.0/28
allow 172.16.2.0/28

# Локальные настройки
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
keyfile /etc/chrony/chrony.keys
leapsectz right/UTC
logdir /var/log/chrony
EOF

# Включение и запуск службы
systemctl enable --now chronyd
systemctl restart chronyd
systemctl status chronyd --no-pager

echo "Chrony на ISP настроен. Проверка: chronyc sources -v"
