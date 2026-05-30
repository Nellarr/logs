Готовые DNS-конфиги для ALT Linux / BIND.
Копировать на HQ-SRV:

cp options.conf /etc/bind/options.conf
cp local.conf /etc/bind/local.conf
cp db.au-team.irpo /etc/bind/db.au-team.irpo
cp db.192.168.10 /etc/bind/db.192.168.10
cp db.192.168.20 /etc/bind/db.192.168.20

Проверка:
named-checkconf
named-checkzone au-team.irpo /etc/bind/db.au-team.irpo
named-checkzone 10.168.192.in-addr.arpa /etc/bind/db.192.168.10
named-checkzone 20.168.192.in-addr.arpa /etc/bind/db.192.168.20
systemctl restart bind
systemctl enable bind

Тест:
nslookup hq-rtr.au-team.irpo 127.0.0.1
nslookup hq-srv.au-team.irpo 127.0.0.1
nslookup hq-cli.au-team.irpo 127.0.0.1
nslookup 192.168.10.1 127.0.0.1
nslookup 192.168.10.2 127.0.0.1
nslookup 192.168.20.2 127.0.0.1
