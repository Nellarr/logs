#!/bin/bash

set -e

apt-get update
apt-get install -y docker-engine docker-compose

systemctl enable --now docker

mkdir -p /root/mediawiki

cat > /root/wiki.yml <<'EOF'
services:
  mariadb:
    image: mariadb:latest
    container_name: mariadb
    restart: always
    environment:
      MARIADB_ROOT_PASSWORD: RootP@ssw0rd
      MARIADB_DATABASE: mediawiki
      MARIADB_USER: wiki
      MARIADB_PASSWORD: WikiP@ssw0rd
    volumes:
      - mariadb_data:/var/lib/mysql

  wiki:
    image: mediawiki:latest
    container_name: wiki
    restart: always
    ports:
      - "8080:80"
    environment:
      MEDIAWIKI_DB_TYPE: mysql
      MEDIAWIKI_DB_HOST: mariadb
      MEDIAWIKI_DB_USER: wiki
      MEDIAWIKI_DB_PASSWORD: WikiP@ssw0rd
      MEDIAWIKI_DB_NAME: mediawiki
    depends_on:
      - mariadb
    volumes:
      - mediawiki_data:/var/www/html/images
      # После первичной настройки раскомментировать:
      # - /root/mediawiki/LocalSettings.php:/var/www/html/LocalSettings.php

volumes:
  mediawiki_data:
  mariadb_data:
EOF

docker compose -f /root/wiki.yml up -d

docker ps
