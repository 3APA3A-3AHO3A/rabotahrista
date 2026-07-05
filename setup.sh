#!/bin/bash

# Остановка при ошибках и подробное логирование
set -e
trap 'echo -e "\n[ОШИБКА] Скрипт прерван из-за непредвиденной ошибки на строке $LINENO. Код: $?" >&2; exit 1' ERR

# === ПЕРЕМЕННЫЕ НАСТРОЙКИ ===
INDEX_URL="https://raw.githubusercontent.com/3APA3A-3AHO3A/rabotahrista/main/index.html"
# ============================

# Проверка на выполнение от root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт с правами root (sudo ./setup.sh)"
  exit 1
fi

# ==========================================
# 1. Сбор данных
# ==========================================
echo -e "\n=========================================="
while [[ -z "$DOMAIN" ]]; do
    read -p "Введите основной домен (например, domain.com): " DOMAIN
done

while [[ -z "$PANEL_IP" ]]; do
    read -p "Введите IP-адрес мастер-панели (для UFW): " PANEL_IP
done

while [[ -z "$SUBDOMAIN" ]]; do
    read -p "Введите имя ноды/субдомена (например, node-nl-1): " SUBDOMAIN
done

while [[ -z "$REMNA_SECRET" ]]; do
    read -p "Введите SECRET_KEY для Remnanode: " REMNA_SECRET
done

echo -e "\n--- Настройка SSH ---"
read -p "Настроить беспарольный вход по SSH-ключу для root? [y/N]: " SETUP_SSH
if [[ "$SETUP_SSH" =~ ^[Yy]$ ]]; then
    while [[ -z "$SSH_PUBLIC_KEY" ]]; do
        read -p "Вставьте ваш публичный SSH-ключ (например, ssh-ed25519 AAA...): " SSH_PUBLIC_KEY
    done
fi

echo -e "\n--- Опциональные компоненты ---"
read -p "Установить Cloudflare WARP? [y/N]: " INSTALL_WARP
read -p "Установить Speedtest CLI (Ookla)? [y/N]: " INSTALL_SPEEDTEST

echo -e "\n--- Дополнительные проверки после установки ---"
read -p "Запустить проверку железа и сети (bench.sh)? [y/N]: " RUN_BENCH
read -p "Запустить проверку геобазы IP (ipregion)? [y/N]: " RUN_GEO
read -p "Запустить проверку разблокировки стримингов (Netflix, ChatGPT)? [y/N]: " RUN_MEDIA
echo -e "==========================================\n"

FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"

echo "Начинаем настройку сервера для $FULL_DOMAIN..."
sleep 2

# Отключаем интерактивные окна apt
export DEBIAN_FRONTEND=noninteractive

# ==========================================
# 1.2. Настройка беспарольного входа по SSH (Опционально)
# ==========================================
if [[ "$SETUP_SSH" =~ ^[Yy]$ ]] && [[ -n "$SSH_PUBLIC_KEY" ]]; then
    echo "Настройка беспарольного входа по SSH для root..."
    
    # Создаем директорию и настраиваем права
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    # Добавляем публичный ключ, если его еще нет в файле
    touch /root/.ssh/authorized_keys
    grep -qF "$SSH_PUBLIC_KEY" /root/.ssh/authorized_keys || echo "$SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys

    # Изменяем настройки в sshd_config
    sed -i "s/^[# ]*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
    grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config || echo "PermitRootLogin yes" >> /etc/ssh/sshd_config

    sed -i "s/^[# ]*PubkeyAuthentication.*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
    grep -q "^PubkeyAuthentication yes" /etc/ssh/sshd_config || echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config

    # Перезапускаем службу SSH
    systemctl restart ssh || systemctl restart sshd
    echo "SSH-доступ по ключу успешно настроен!"
else
    echo "Пропуск настройки SSH по ключу..."
fi

# ==========================================
# 1.5. Настройка Swap-файла (Защита от падений по памяти)
# ==========================================
if [ -z "$(swapon --show)" ]; then
    echo "Создание Swap-файла на 2GB..."
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo "Swap успешно создан!"
else
    echo "Swap-файл уже существует, пропускаем..."
fi

# ==========================================
# 2. Обновление и установка пакетов
# ==========================================
echo "Обновление системы и установка пакетов..."
apt clean
apt update
apt upgrade -y
apt dist-upgrade -y
apt autoremove --purge -y
apt install -y curl wget unzip git ufw fail2ban socat jq certbot python3-certbot-nginx nginx dnsutils chrony iperf3 btop ncdu

# ==========================================
# 2.5. Установка Speedtest CLI (Опционально)
# ==========================================
if [[ "$INSTALL_SPEEDTEST" =~ ^[Yy]$ ]]; then
    echo "Установка Speedtest CLI..."
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash || true

    # Workaround для Ubuntu 24.04 (Noble) - меняем на jammy
    if grep -q "noble" /etc/apt/sources.list.d/ookla_speedtest-cli.list 2>/dev/null; then
        sed -i 's/noble/jammy/g' /etc/apt/sources.list.d/ookla_speedtest-cli.list
        apt update
    fi
    apt install speedtest -y || echo "Speedtest установить не удалось, продолжаем..."
else
    echo "Пропуск установки Speedtest..."
fi

# ==========================================
# 3. Настройка GRUB (Отключение IPv6)
# ==========================================
echo "Отключение IPv6 в GRUB..."
# Безопасное добавление ipv6.disable=1, если его там еще нет
if ! grep -q "ipv6.disable=1" /etc/default/grub; then
    sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="ipv6.disable=1 /' /etc/default/grub
    update-grub
fi

# ==========================================
# 4. Настройка UFW
# ==========================================
echo "Настройка фаервола UFW..."
sed -i 's/IPV6=yes/IPV6=no/' /etc/default/ufw
sed -i 's|net/ipv4/icmp_echo_ignore_all=0|net/ipv4/icmp_echo_ignore_all=1|' /etc/ufw/sysctl.conf

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw limit 22/tcp comment 'SSH Rate Limit'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow from $PANEL_IP to any port 2222 proto tcp comment 'API panel'
echo "y" | ufw enable

# ==========================================
# 5. Тюнинг ядра (Sysctl)
# ==========================================
echo "Применение сетевых настроек ядра..."

# Загрузка модуля BBR
echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
modprobe tcp_bbr || true

cat <<EOF > /etc/sysctl.d/99-vpn-tune.conf
fs.file-max=1048576

net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3

# Отключаем icmp ping
net.ipv4.icmp_echo_ignore_all=1

# Расширяем диапазон портов для исходящих соединений (по умолчанию обычно 32768-60999)
net.ipv4.ip_local_port_range = 1024 65535

# Уменьшаем время удержания сокета в состоянии FIN-WAIT-2 (по умолчанию 60 сек)
net.ipv4.tcp_fin_timeout = 15

# Оптимизация параметров TCP Keepalive (быстрее определяем оборванные сессии)
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

# Разрешаем повторное использование сокетов TIME_WAIT для новых соединений
net.ipv4.tcp_tw_reuse = 1

# Отключаем ipv6
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF
sysctl --system

# ==========================================
# 6. Установка Docker и Warp
# ==========================================
echo "Установка Docker и Warp..."
curl -fsSL https://get.docker.com | sh
if [[ "$INSTALL_WARP" =~ ^[Yy]$ ]]; then
    echo "Установка Cloudflare WARP..."
    bash <(curl -fsSL https://raw.githubusercontent.com/distillium/warp-native/main/install.sh) || echo "Ошибка установки WARP, продолжаем..."
else
    echo "Пропуск установки Cloudflare WARP..."
fi

# ==========================================
# 7. Поднятие Remnanode в Docker
# ==========================================
echo "Запуск Remnanode..."
mkdir -p /opt/remnanode
cat <<EOF > /opt/remnanode/docker-compose.yml
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=2222
      - SECRET_KEY="${REMNA_SECRET}"
EOF
cd /opt/remnanode && docker compose up -d

# ==========================================
# 8. Скачивание заглушки Nginx (Mini-Blog)
# ==========================================
echo "Скачивание и установка заглушки сайта..."
mkdir -p /var/www/stub
mkdir -p /var/lib/letsencrypt/.well-known/acme-challenge/
chown -R www-data:www-data /var/lib/letsencrypt/.well-known
chmod -R 755 /var/lib/letsencrypt/.well-known
echo "test" | tee /var/lib/letsencrypt/.well-known/acme-challenge/test.txt

echo "Загрузка страницы-заглушки из GitHub..."
wget -qO /var/www/stub/index.html "$INDEX_URL"

# Проверка, скачался ли файл
if [ -s /var/www/stub/index.html ]; then
    echo "Заглушка успешно загружена!"
else
    echo "Ошибка загрузки заглушки. Создан запасной файл."
    echo "<html><body><h1>Hello World</h1></body></html>" > /var/www/stub/index.html
fi
# ==========================================
# 9. Получение SSL сертификата (до применения кастомного конфига Nginx)
# ==========================================
echo "Выпуск SSL сертификата..."
echo "[ОЖИДАНИЕ] Проверка привязки домена $FULL_DOMAIN к IP сервера..."
SERVER_IP=$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org)

ATTEMPTS=0
MAX_ATTEMPTS=30

while true; do
    RESOLVED_IP=$(dig +short "$FULL_DOMAIN" | tail -n1)
    
    if [ "$RESOLVED_IP" == "$SERVER_IP" ]; then
        echo -e "-> DNS успешно обновлен! Домен указывает на $SERVER_IP\n"
        break
    fi
    
    ((ATTEMPTS++))
    echo "Попытка $ATTEMPTS/$MAX_ATTEMPTS: DNS еще не обновился (Сервер: $SERVER_IP, Домен: ${RESOLVED_IP:-ПУСТО}). Ждем 10 сек..."
    sleep 10
    
    if [ "$ATTEMPTS" -eq "$MAX_ATTEMPTS" ]; then
        echo -e "\n[ВНИМАНИЕ] Прошло 5 минут, но DNS так и не обновился!"
        echo "Пожалуйста, проверьте у регистратора, что для $FULL_DOMAIN создана A-запись на IP $SERVER_IP."
        echo "(Если используете Cloudflare, отключите оранжевое облако на время установки)."
        read -p "Нажмите Enter, чтобы попробовать еще $MAX_ATTEMPTS раз, или Ctrl+C для прерывания..."
        ATTEMPTS=0 # Сбрасываем счетчик и пробуем снова
    fi
done
certbot --nginx -d "$FULL_DOMAIN" --register-unsafely-without-email --agree-tos --non-interactive

# ==========================================
# 10. Применение кастомного конфига Nginx
# ==========================================
echo "Настройка Nginx Fallback..."
cat <<EOF > /etc/nginx/sites-available/$FULL_DOMAIN
server {
    listen 80;
    server_name $FULL_DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/lib/letsencrypt/;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 127.0.0.1:8443 ssl http2 proxy_protocol default_server;
    server_name _;
    ssl_reject_handshake on;
}

server {
    listen 127.0.0.1:8443 ssl http2 proxy_protocol;
    server_name $FULL_DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$FULL_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$FULL_DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
    ssl_session_cache shared:SSL:1m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;

    location / {
        root /var/www/stub;
        index index.html;
        try_files \$uri \$uri/ /index.html;
        add_header Cache-Control "no-store, no-cache, must-revalidate";
    }
}
EOF

rm -f /etc/nginx/sites-available/default
rm -f /etc/nginx/sites-enabled/default 
ln -sf /etc/nginx/sites-available/$FULL_DOMAIN /etc/nginx/sites-enabled/

nginx -t
systemctl restart nginx

# ==========================================
# 11. Запуск выбранных диагностик
# ==========================================
echo -e "\n=========================================="
echo "Установка основных компонентов завершена!"
echo "=========================================="

if [[ "$RUN_BENCH" =~ ^[Yy]$ ]]; then
    echo -e "\n>>> Запуск bench.sh (Проверка железа и скорости)..."
    wget -qO- bench.sh | bash || true
fi

if [[ "$RUN_GEO" =~ ^[Yy]$ ]]; then
    echo -e "\n>>> Запуск ipregion.sh (Проверка баз IP)..."
    bash <(wget -qO- https://raw.githubusercontent.com/Davoyan/ipregion/main/ipregion.sh) || true
fi

if [[ "$RUN_MEDIA" =~ ^[Yy]$ ]]; then
    echo -e "\n>>> Запуск проверки стримингов (RegionRestrictionCheck)..."
    bash <(curl -L -s check.unlock.media) || true
fi

# ==========================================
# 12. Финал и Ребут
# ==========================================
echo -e "\n=========================================="
echo "Все задачи выполнены успешно!"
echo "Сервер готов к работе. Перезагрузка через 10 секунд..."
echo "(Нажмите Ctrl+C, если хотите отменить перезагрузку и осмотреться)"
echo "=========================================="
sleep 10
reboot
