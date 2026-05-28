#!/bin/bash
set -e

# ===== НАСТРОЙКИ =====
ISO_PATH="/root/Additional.iso"
ISO_MOUNT="/mnt/additional"

APP_DIR="/opt/testapp"

DB_NAME="testdb"
DB_USER="testc"
DB_PASS='P@ssw0rd'

APP_PORT="8080"
APP_CONTAINER="testapp"
DB_CONTAINER="db"
# =====================

if [ "$EUID" -ne 0 ]; then
    echo "Запусти от root: su -"
    exit 1
fi

echo "[1/7] Установка Docker..."

apt-get update

if apt-cache search docker-engine | grep -q '^docker-engine'; then
    apt-get install -y docker-engine
elif apt-cache search docker-ce | grep -q '^docker-ce'; then
    apt-get install -y docker-ce
else
    echo "Не найден пакет docker-engine или docker-ce"
    echo "Проверь репозитории ALT Linux"
    exit 1
fi

if apt-cache search docker-compose-v2 | grep -q '^docker-compose-v2'; then
    apt-get install -y docker-compose-v2
elif apt-cache search docker-compose | grep -q '^docker-compose'; then
    apt-get install -y docker-compose
else
    echo "Пакет docker compose не найден, продолжаю проверку..."
fi

systemctl enable --now docker

echo "[2/7] Проверка Docker..."

docker version >/dev/null

if docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE="docker-compose"
else
    echo "Docker Compose не найден"
    echo "Попробуй вручную: apt-get install docker-compose-v2"
    exit 1
fi

echo "[3/7] Поиск Additional.iso или папки docker..."

DOCKER_DIR=""

if [ -d "$ISO_MOUNT/docker" ]; then
    DOCKER_DIR="$ISO_MOUNT/docker"
fi

if [ -z "$DOCKER_DIR" ]; then
    FOUND_DIR="$(find /mnt /media /run/media -maxdepth 4 -type d -name docker 2>/dev/null | head -n 1 || true)"
    if [ -n "$FOUND_DIR" ]; then
        DOCKER_DIR="$FOUND_DIR"
    fi
fi

if [ -z "$DOCKER_DIR" ]; then
    if [ ! -f "$ISO_PATH" ]; then
        FOUND_ISO="$(find /root /home /mnt /media -maxdepth 4 -iname 'Additional.iso' 2>/dev/null | head -n 1 || true)"
        if [ -n "$FOUND_ISO" ]; then
            ISO_PATH="$FOUND_ISO"
        fi
    fi

    if [ ! -f "$ISO_PATH" ]; then
        echo "Не найден Additional.iso"
        echo "Положи ISO сюда: $ISO_PATH"
        echo "Или поменяй ISO_PATH в начале скрипта"
        exit 1
    fi

    mkdir -p "$ISO_MOUNT"
    mountpoint -q "$ISO_MOUNT" || mount -o loop "$ISO_PATH" "$ISO_MOUNT"
    DOCKER_DIR="$ISO_MOUNT/docker"
fi

if [ ! -d "$DOCKER_DIR" ]; then
    echo "Не найдена папка docker в Additional.iso"
    echo "Сейчас ищу:"
    echo "$DOCKER_DIR"
    exit 1
fi

echo "Папка с образами: $DOCKER_DIR"

echo "[4/7] Импорт Docker-образов..."

LOADED=0

while IFS= read -r IMGFILE; do
    echo "Импорт: $IMGFILE"
    if docker load -i "$IMGFILE"; then
        LOADED=$((LOADED + 1))
    fi
done < <(find "$DOCKER_DIR" -maxdepth 1 -type f)

if [ "$LOADED" -eq 0 ]; then
    echo "Не удалось импортировать образы"
    echo "Проверь содержимое папки:"
    ls -lah "$DOCKER_DIR"
    exit 1
fi

echo "[5/7] Поиск имён импортированных образов..."

SITE_IMAGE="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -Ei 'site|testapp|app' | grep -v '<none>' | head -n 1 || true)"
DB_IMAGE="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -Ei 'mariadb|mysql' | grep -v '<none>' | head -n 1 || true)"

if [ -z "$SITE_IMAGE" ]; then
    echo "Не найден образ приложения. Вот список образов:"
    docker images
    echo "Впиши имя образа приложения вручную в docker-compose.yml"
    exit 1
fi

if [ -z "$DB_IMAGE" ]; then
    echo "Не найден образ MariaDB. Вот список образов:"
    docker images
    echo "Впиши имя образа БД вручную в docker-compose.yml"
    exit 1
fi

echo "Образ приложения: $SITE_IMAGE"
echo "Образ БД: $DB_IMAGE"

echo "[6/7] Создание docker-compose.yml..."

mkdir -p "$APP_DIR"
cd "$APP_DIR"

cat > docker-compose.yml <<EOF
services:
  db:
    image: $DB_IMAGE
    container_name: $DB_CONTAINER
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: "$DB_PASS"
      MYSQL_DATABASE: "$DB_NAME"
      MYSQL_USER: "$DB_USER"
      MYSQL_PASSWORD: "$DB_PASS"
      MARIADB_ROOT_PASSWORD: "$DB_PASS"
      MARIADB_DATABASE: "$DB_NAME"
      MARIADB_USER: "$DB_USER"
      MARIADB_PASSWORD: "$DB_PASS"
    volumes:
      - db_data:/var/lib/mysql

  testapp:
    image: $SITE_IMAGE
    container_name: $APP_CONTAINER
    restart: always
    depends_on:
      - db
    ports:
      - "$APP_PORT:80"
    environment:
      DB_HOST: "$DB_CONTAINER"
      DB_PORT: "3306"
      DB_NAME: "$DB_NAME"
      DB_DATABASE: "$DB_NAME"
      DB_USER: "$DB_USER"
      DB_USERNAME: "$DB_USER"
      DB_PASSWORD: "$DB_PASS"
      MYSQL_HOST: "$DB_CONTAINER"
      MYSQL_DATABASE: "$DB_NAME"
      MYSQL_USER: "$DB_USER"
      MYSQL_PASSWORD: "$DB_PASS"

volumes:
  db_data:
EOF

echo "[7/7] Запуск контейнеров..."

$COMPOSE down || true
$COMPOSE up -d

if command -v firewall-cmd >/dev/null 2>&1; then
    if systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port=${APP_PORT}/tcp || true
        firewall-cmd --reload || true
    fi
fi

sleep 5

echo
echo "Готово."
echo
echo "Контейнеры:"
docker ps
echo
echo "Проверка:"
echo "  curl http://127.0.0.1:$APP_PORT"
echo
echo "Файл compose:"
echo "  $APP_DIR/docker-compose.yml"