ПОРЯДОК ЗАПУСКА СКРИПТОВ
=========================

1) На каждой машине сначала проверь интерфейсы:
   ip -br a

2) Если интерфейсы отличаются от ens192/ens224/ens256, открой скрипт и поменяй переменные сверху:
   mcedit isp_demo_altlinux.sh
   mcedit hq-rtr_demo_altlinux.sh
   mcedit br-rtr_demo_altlinux.sh
   mcedit hq-sw_demo_altlinux.sh

3) Рекомендуемый порядок запуска:
   ISP      -> bash isp_demo_altlinux.sh
   HQ-SW    -> bash hq-sw_demo_altlinux.sh
   HQ-RTR   -> bash hq-rtr_demo_altlinux.sh
   BR-RTR   -> bash br-rtr_demo_altlinux.sh

4) Проверка после настройки:
   ISP:
     ip -br a
     iptables -t nat -L -n -v
     ping 172.16.1.2
     ping 172.16.2.2

   HQ-RTR:
     ip -br a
     ping 172.16.1.1
     ping 172.16.2.2
     vtysh -c 'show ip ospf neighbor'
     vtysh -c 'show ip route ospf'

   BR-RTR:
     ip -br a
     ping 172.16.2.1
     ping 172.16.1.2
     vtysh -c 'show ip ospf neighbor'
     vtysh -c 'show ip route ospf'

   HQ-SW:
     bridge vlan show
     ip -br a
     ping 192.168.99.1

ДАННЫЕ, ЗАЛОЖЕННЫЕ В СКРИПТЫ
============================
ISP-HQ: 172.16.1.0/28
  ISP:    172.16.1.1/28
  HQ-RTR: 172.16.1.2/28

ISP-BR: 172.16.2.0/28
  ISP:    172.16.2.1/28
  BR-RTR: 172.16.2.2/28

HQ:
  VLAN100 HQ-SRV: 192.168.10.0/26, HQ-RTR = 192.168.10.1
  VLAN200 HQ-CLI: 192.168.20.0/28, HQ-RTR = 192.168.20.1, DHCP 192.168.20.2-14
  VLAN999 MGMT:   192.168.99.0/29, HQ-RTR = 192.168.99.1, HQ-SW = 192.168.99.3

BR:
  BR-SRV network: 192.168.30.0/27, BR-RTR = 192.168.30.1

GRE/OSPF:
  tunnel network: 172.16.100.0/29
  BR-RTR gre1:    172.16.100.1/29
  HQ-RTR gre1:    172.16.100.2/29
  OSPF area:      0
  OSPF key:       1245
