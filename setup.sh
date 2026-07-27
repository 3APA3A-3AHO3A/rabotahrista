#!/bin/bash

# Остановка при ошибках и подробное логирование
set -e
trap 'echo -e "\n[ОШИБКА] Скрипт прерван из-за непредвиденной ошибки на строке $LINENO. Код: $?" >&2; exit 1' ERR

# === ПЕРЕМЕННЫЕ НАСТРОЙКИ ===
INDEX_URL="https://raw.githubusercontent.com/3APA3A-3AHO3A/rabotahrista/main/index.html"
NOTIFY_ENV="/etc/rabotahrista/notify.env"
# ============================

if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт с правами root (sudo bash ...)"
  exit 1
fi
export DEBIAN_FRONTEND=noninteractive

# ##########################################################################
#  ХЕЛПЕРЫ
# ##########################################################################
ask_domain() {
    DOMAIN=$(echo "${DOMAIN:-}" | tr -d '[:space:]')
    while [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]]; do
        read -ep "Введите основной домен (например, domain.com): " DOMAIN
        DOMAIN=$(echo "$DOMAIN" | tr -d '[:space:]')
        [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] || echo -e "\e[31m[Ошибка]\e[0m Только буквы, цифры, точки и дефисы."
    done
}
ask_subdomain() {
    SUBDOMAIN=$(echo "${SUBDOMAIN:-}" | tr -d '[:space:]')
    while [[ ! "$SUBDOMAIN" =~ ^[a-zA-Z0-9-]+$ ]]; do
        read -ep "Введите имя ноды/субдомена (например, node-nl-1): " SUBDOMAIN
        SUBDOMAIN=$(echo "$SUBDOMAIN" | tr -d '[:space:]')
        [[ "$SUBDOMAIN" =~ ^[a-zA-Z0-9-]+$ ]] || echo -e "\e[31m[Ошибка]\e[0m Только буквы, цифры и дефисы (без точек)."
    done
}
ask_panel_ip() {
    PANEL_IP=$(echo "${PANEL_IP:-}" | tr -d '[:space:]')
    while [[ ! "$PANEL_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; do
        read -ep "Введите IP-адрес мастер-панели (для UFW): " PANEL_IP
        PANEL_IP=$(echo "$PANEL_IP" | tr -d '[:space:]')
        [[ "$PANEL_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || echo -e "\e[31m[Ошибка]\e[0m Введите корректный IPv4."
    done
}
ask_secret() {
    REMNA_SECRET=$(echo "${REMNA_SECRET:-}" | tr -d '[:space:]')
    while [[ -z "$REMNA_SECRET" ]]; do
        read -ep "Введите SECRET_KEY для Remnanode: " REMNA_SECRET
        REMNA_SECRET=$(echo "$REMNA_SECRET" | tr -d '[:space:]')
    done
}
ask_ssh_key() {
    while [[ -z "$SSH_PUBLIC_KEY" ]]; do
        read -ep "Публичный SSH-ключ (ssh-ed25519 AAA...): " SSH_PUBLIC_KEY
    done
}
ask_cf() {
    [[ -z "$SETUP_CF" ]] && read -ep "Настроить DNS в Cloudflare автоматически? [y/N]: " SETUP_CF
    if [[ "$SETUP_CF" =~ ^[Yy]$ ]]; then
        while [[ -z "$CF_API_TOKEN" ]]; do
            read -ep "API Token Cloudflare (Edit DNS): " CF_API_TOKEN
            CF_API_TOKEN=$(echo "$CF_API_TOKEN" | tr -d '[:space:]')
        done
        [[ -z "$CF_PROXY_CHOICE" ]] && read -ep "Включить Proxy (Оранжевое облако)? [y/N]: " CF_PROXY_CHOICE
        [[ "$CF_PROXY_CHOICE" =~ ^[Yy]$ ]] && CF_PROXIED="true" || CF_PROXIED="false"
    fi
}
get_server_ip() { SERVER_IP=$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org); }

# Отправка сообщения в Telegram из самого скрипта (тихо, если токен не задан)
notify_telegram() {
    [[ -f "$NOTIFY_ENV" ]] && source "$NOTIFY_ENV"
    [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]] && return 0
    local args=(-d "chat_id=${TG_CHAT_ID}" -d "parse_mode=HTML" --data-urlencode "text=$1")
    [[ -n "${TG_TOPIC_ID:-}" ]] && args+=(-d "message_thread_id=${TG_TOPIC_ID}")
    curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" "${args[@]}" >/dev/null 2>&1 || true
}

# ##########################################################################
#  КОМПОНЕНТЫ
# ##########################################################################
comp_ssh() {
    ask_ssh_key
    echo ">>> Настройка входа по SSH-ключу для root..."
    mkdir -p /root/.ssh; chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    grep -qF "$SSH_PUBLIC_KEY" /root/.ssh/authorized_keys || echo "$SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    sed -i "s/^[# ]*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
    grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config || echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
    sed -i "s/^[# ]*PubkeyAuthentication.*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
    grep -q "^PubkeyAuthentication yes" /etc/ssh/sshd_config || echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
    systemctl restart ssh || systemctl restart sshd
    echo "SSH по ключу настроен."
}

comp_swap() {
    if [ -z "$(swapon --show)" ]; then
        echo ">>> Создание Swap 2GB..."
        fallocate -l 2G /swapfile; chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
        grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        echo "Swap создан."
    else
        echo "Swap уже есть, пропускаем."
    fi
}

comp_packages() {
    echo ">>> Обновление системы и установка пакетов..."
    apt clean; apt update; apt upgrade -y; apt dist-upgrade -y; apt autoremove --purge -y
    apt install -y curl wget unzip git ufw fail2ban socat jq certbot python3-certbot-nginx nginx dnsutils chrony iperf3 btop ncdu
    systemctl enable --now chrony >/dev/null 2>&1 || systemctl enable --now chronyd >/dev/null 2>&1 || true
}

comp_speedtest() {
    echo ">>> Установка Speedtest CLI..."
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash || true
    if grep -q "noble" /etc/apt/sources.list.d/ookla_speedtest-cli.list 2>/dev/null; then
        sed -i 's/noble/jammy/g' /etc/apt/sources.list.d/ookla_speedtest-cli.list; apt update
    fi
    apt install speedtest -y || echo "Speedtest установить не удалось."
}

comp_ipv6() {
    echo ">>> Отключение IPv6 в GRUB..."
    if ! grep -q "ipv6.disable=1" /etc/default/grub; then
        sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="ipv6.disable=1 /' /etc/default/grub
        update-grub; echo "IPv6 отключён (применится после ребута)."
    else
        echo "IPv6 уже отключён."
    fi
}

comp_ufw() {
    ask_panel_ip
    echo ">>> Настройка UFW..."
    sed -i 's/IPV6=yes/IPV6=no/' /etc/default/ufw
    sed -i 's|net/ipv4/icmp_echo_ignore_all=0|net/ipv4/icmp_echo_ignore_all=1|' /etc/ufw/sysctl.conf
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw limit 22/tcp comment 'SSH Rate Limit'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    ufw allow from "$PANEL_IP" to any port 2222 proto tcp comment 'API panel'
    ufw --force enable
}

comp_sysctl() {
    echo ">>> Тюнинг ядра (sysctl)..."
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    modprobe tcp_bbr || true
    cat <<EOF > /etc/sysctl.d/99-vpn-tune.conf
fs.file-max=1048576

net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# Меньше уводим в swap
vm.swappiness=10

# Отключаем icmp ping
net.ipv4.icmp_echo_ignore_all=1

# Диапазон исходящих портов
net.ipv4.ip_local_port_range = 1024 65535

# FIN-WAIT-2
net.ipv4.tcp_fin_timeout = 15

# TCP Keepalive
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

# Отключаем ipv6
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF
    sysctl --system
}

comp_docker() {
    echo ">>> Установка Docker..."
    if command -v docker >/dev/null 2>&1; then
        echo "Docker уже установлен."
    else
        curl -fsSL https://get.docker.com | sh
    fi
}

# Защита от переполнения диска: ротация логов Docker + кап journald
comp_disk() {
    echo ">>> Защита диска: ротация логов Docker + journald..."
    mkdir -p /etc/docker
    if [[ -f /etc/docker/daemon.json ]] && command -v jq >/dev/null 2>&1; then
        tmp=$(mktemp)
        if jq '. + {"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' /etc/docker/daemon.json > "$tmp" 2>/dev/null; then
            mv "$tmp" /etc/docker/daemon.json
        else
            rm -f "$tmp"
        fi
    else
        cat <<'EOF' > /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
    fi
    systemctl restart docker || true
    mkdir -p /etc/systemd/journald.conf.d
    cat <<'EOF' > /etc/systemd/journald.conf.d/size.conf
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
EOF
    systemctl restart systemd-journald || true
    echo "Готово. (Docker перезапущен — контейнеры с restart:always поднялись сами.)"
}

comp_warp() {
    echo ">>> Установка/переустановка Cloudflare WARP..."
    bash <(curl -fsSL https://raw.githubusercontent.com/distillium/warp-native/main/install.sh) || echo "Ошибка установки WARP."
}

comp_node() {
    ask_secret
    echo ">>> Разворачивание Remnanode..."
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
    docker compose -f /opt/remnanode/docker-compose.yml ps
}

comp_node_update() {
    echo ">>> Обновление ноды Remnanode..."
    if [[ -f /opt/remnanode/docker-compose.yml ]]; then
        cd /opt/remnanode
        docker compose pull
        docker compose up -d
        docker compose ps
        notify_telegram "⬆️ Нода <code>$(hostname)</code> обновлена ($(date '+%H:%M:%S'))"
    else
        echo "Нода не установлена (/opt/remnanode/docker-compose.yml не найден)."
    fi
}

comp_node_logs() {
    docker compose -f /opt/remnanode/docker-compose.yml ps 2>/dev/null || true
    echo "----- Последние 50 строк логов -----"
    docker logs --tail=50 remnanode 2>&1 || echo "Контейнер remnanode не найден."
}

comp_fail2ban() {
    echo ">>> Настройка fail2ban..."
    apt install -y fail2ban >/dev/null 2>&1 || true
    cat <<'EOF' > /etc/fail2ban/jail.local
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled  = true
backend  = systemd
port     = 22
maxretry = 4
bantime  = 24h

[recidive]
enabled  = true
bantime  = 1w
findtime = 1d
maxretry = 5
EOF
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban
    echo "fail2ban: sshd + recidive активны."
}

comp_autoupdates() {
    echo ">>> Автообновления безопасности (unattended-upgrades)..."
    apt install -y unattended-upgrades >/dev/null 2>&1 || true
    cat <<'EOF' > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    cat <<'EOF' > /etc/apt/apt.conf.d/52unattended-upgrades-local
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
    systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
    echo "Автообновления: только security, авто-ребут ВЫКЛ."
}

# Telegram: SSH-вход + загрузка сервера + падение ноды
comp_telegram() {
    [[ -z "$TG_BOT_TOKEN" && -z "$NONINTERACTIVE" ]] && read -ep "Telegram BOT_TOKEN: " TG_BOT_TOKEN
    [[ -z "$TG_CHAT_ID" && -z "$NONINTERACTIVE" ]]   && read -ep "Telegram CHAT_ID (супергруппа: начинается с -100): " TG_CHAT_ID
    [[ -z "$TG_TOPIC_ID" && -z "$NONINTERACTIVE" ]]  && read -ep "Topic ID темы супергруппы (Enter — если без топиков): " TG_TOPIC_ID
    mkdir -p /etc/rabotahrista
    cat <<EOF > "$NOTIFY_ENV"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
TG_TOPIC_ID="${TG_TOPIC_ID:-}"
EOF
    chmod 600 "$NOTIFY_ENV"

    # универсальный отправщик
    cat <<'SCRIPT' > /usr/local/bin/rh-notify.sh
#!/bin/bash
[[ -f /etc/rabotahrista/notify.env ]] && source /etc/rabotahrista/notify.env
[[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && exit 0
ARGS=(-d "chat_id=${TG_CHAT_ID}" -d "parse_mode=HTML" --data-urlencode "text=$1")
[[ -n "$TG_TOPIC_ID" ]] && ARGS+=(-d "message_thread_id=${TG_TOPIC_ID}")
curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" "${ARGS[@]}" >/dev/null 2>&1
SCRIPT
    chmod 755 /usr/local/bin/rh-notify.sh

    # 1) SSH-вход (pam_exec)
    cat <<'SCRIPT' > /usr/local/bin/rh-ssh-login.sh
#!/bin/bash
[[ "$PAM_TYPE" != "open_session" ]] && exit 0
MSG="🔐 <b>SSH-вход</b>
Сервер: <code>$(hostname)</code>
Пользователь: <code>${PAM_USER}</code>
IP: <code>${PAM_RHOST}</code>
Время: $(date '+%Y-%m-%d %H:%M:%S %Z')"
/usr/local/bin/rh-notify.sh "$MSG" &
exit 0
SCRIPT
    chmod 755 /usr/local/bin/rh-ssh-login.sh
    grep -q "rh-ssh-login.sh" /etc/pam.d/sshd || \
        echo "session optional pam_exec.so seteuid /usr/local/bin/rh-ssh-login.sh" >> /etc/pam.d/sshd

    # 2) Загрузка сервера
    cat <<'UNIT' > /etc/systemd/system/rh-boot-notify.service
[Unit]
Description=Telegram notify on boot
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c '/usr/local/bin/rh-notify.sh "♻️ Сервер <code>$(hostname)</code> загрузился ($(date "+%H:%M:%S %Z"))"'
[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable rh-boot-notify.service >/dev/null 2>&1 || true

    # 3) Падение ноды (таймер каждые 2 мин)
    cat <<'SCRIPT' > /usr/local/bin/rh-node-health.sh
#!/bin/bash
STATE=$(docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null || echo "missing")
FLAG=/run/rh-node-down
if [[ "$STATE" != "true" ]]; then
    if [[ ! -f "$FLAG" ]]; then
        /usr/local/bin/rh-notify.sh "⚠️ Нода <code>$(hostname)</code>: контейнер remnanode НЕ работает (state=${STATE})"
        touch "$FLAG"
    fi
else
    [[ -f "$FLAG" ]] && { /usr/local/bin/rh-notify.sh "✅ Нода <code>$(hostname)</code>: remnanode снова работает"; rm -f "$FLAG"; }
fi
SCRIPT
    chmod 755 /usr/local/bin/rh-node-health.sh
    cat <<'UNIT' > /etc/systemd/system/rh-node-health.service
[Unit]
Description=Remnanode health -> Telegram
[Service]
Type=oneshot
ExecStart=/usr/local/bin/rh-node-health.sh
UNIT
    cat <<'UNIT' > /etc/systemd/system/rh-node-health.timer
[Unit]
Description=Remnanode healthcheck every 2 min
[Timer]
OnBootSec=120
OnUnitActiveSec=120
[Install]
WantedBy=timers.target
UNIT
    systemctl daemon-reload
    systemctl enable --now rh-node-health.timer >/dev/null 2>&1 || true

    /usr/local/bin/rh-notify.sh "✅ Уведомления настроены на <code>$(hostname)</code> (SSH-входы, загрузка, падение ноды)"
    echo "Telegram-уведомления настроены. Тестовое сообщение отправлено."
}

# Веб: заглушка + DNS в CF + сертификат + nginx fallback + оранжевое облако
comp_web() {
    ask_domain; ask_subdomain; ask_cf
    FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"
    get_server_ip

    echo ">>> Установка заглушки..."
    mkdir -p /var/www/stub
    mkdir -p /var/lib/letsencrypt/.well-known/acme-challenge/
    chown -R www-data:www-data /var/lib/letsencrypt/.well-known
    chmod -R 755 /var/lib/letsencrypt/.well-known
    echo "test" | tee /var/lib/letsencrypt/.well-known/acme-challenge/test.txt >/dev/null
    wget -qO /var/www/stub/index.html "$INDEX_URL"
    if [ -s /var/www/stub/index.html ]; then echo "Заглушка загружена."; else
        echo "<html><body><h1>Hello World</h1></body></html>" > /var/www/stub/index.html; fi

    if [[ "$SETUP_CF" =~ ^[Yy]$ ]] && [[ -n "$CF_API_TOKEN" ]]; then
        echo ">>> DNS в Cloudflare..."
        ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
            -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" | jq -r '.result[0].id')
        if [ "$ZONE_ID" == "null" ] || [ -z "$ZONE_ID" ]; then
            echo "[ВНИМАНИЕ] Zone ID не получен. Ручной режим."
        else
            RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$FULL_DOMAIN&type=A" \
                -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" | jq -r '.result[0].id')
            JSON_DATA_GRAY='{"type":"A","name":"'"$FULL_DOMAIN"'","content":"'"$SERVER_IP"'","ttl":1,"proxied":false}'
            if [ "$RECORD_ID" != "null" ] && [ -n "$RECORD_ID" ]; then
                curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
                    -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" --data "$JSON_DATA_GRAY" > /dev/null
            else
                CREATE_RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
                    -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" --data "$JSON_DATA_GRAY")
                RECORD_ID=$(echo "$CREATE_RESPONSE" | jq -r '.result.id')
            fi
            echo "DNS обновлён, ждём 15 сек..."; sleep 15
        fi
    fi

    echo ">>> Выпуск SSL..."
    if [ -d "/etc/letsencrypt/live/$FULL_DOMAIN" ]; then
        echo "Сертификат уже есть, пропускаем."
    else
        ATTEMPTS=0; MAX_ATTEMPTS=30
        while true; do
            RESOLVED_IP=$(dig +short "$FULL_DOMAIN" | tail -n1)
            [ "$RESOLVED_IP" == "$SERVER_IP" ] && { echo "-> DNS указывает на $SERVER_IP"; break; }
            ATTEMPTS=$((ATTEMPTS + 1))
            echo "Попытка $ATTEMPTS/$MAX_ATTEMPTS: DNS ещё не обновился (${RESOLVED_IP:-ПУСТО}). Ждём 10 сек..."
            sleep 10
            if [ "$ATTEMPTS" -eq "$MAX_ATTEMPTS" ]; then
                echo "[ВНИМАНИЕ] DNS не обновился (возможно, за CF Proxy)."
                if [[ -n "$NONINTERACTIVE" ]]; then echo "Неинтерактивный режим — продолжаем.";
                else read -p "Enter — продолжить на свой риск, Ctrl+C — выход..."; fi
                break
            fi
        done
        certbot --nginx -d "$FULL_DOMAIN" --register-unsafely-without-email --agree-tos --non-interactive
    fi

    echo ">>> Nginx Fallback..."
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
    rm -f /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/$FULL_DOMAIN /etc/nginx/sites-enabled/
    nginx -t
    systemctl restart nginx

    if [[ "$CF_PROXIED" == "true" ]] && [[ -n "$RECORD_ID" ]] && [[ "$RECORD_ID" != "null" ]]; then
        echo ">>> Оранжевое облако CF..."
        JSON_DATA_ORANGE='{"type":"A","name":"'"$FULL_DOMAIN"'","content":"'"$SERVER_IP"'","ttl":1,"proxied":true}'
        curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
            -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" --data "$JSON_DATA_ORANGE" > /dev/null
        echo "Оранжевое облако включено."
    fi
}

run_bench() { echo ">>> bench.sh..."; wget -qO- bench.sh | bash || true; }
run_geo()   { echo ">>> ipregion.sh..."; bash <(wget -qO- https://raw.githubusercontent.com/Davoyan/ipregion/main/ipregion.sh) || true; }
run_media() { echo ">>> Проверка стримингов..."; bash <(curl -L -s check.unlock.media) || true; }
comp_diag() {
    [[ "$RUN_BENCH" =~ ^[Yy]$ ]] && run_bench
    [[ "$RUN_GEO"   =~ ^[Yy]$ ]] && run_geo
    [[ "$RUN_MEDIA" =~ ^[Yy]$ ]] && run_media
    return 0
}

# ##########################################################################
#  ПОЛНАЯ УСТАНОВКА (только ядро + базовая безопасность; без вопросов про доп-компоненты)
# ##########################################################################
full_install() {
    echo -e "\n========== ПОЛНАЯ УСТАНОВКА =========="
    ask_domain; ask_panel_ip; ask_subdomain; ask_secret; ask_cf
    echo -e "\n--- SSH ---"
    [[ -z "$SETUP_SSH" ]] && read -ep "Настроить вход по SSH-ключу для root? [y/N]: " SETUP_SSH
    [[ "$SETUP_SSH" =~ ^[Yy]$ ]] && ask_ssh_key
    # WARP/Speedtest/диагностики в полную установку НЕ входят (ставятся из меню).
    # В неинтерактивном режиме включаются флагами INSTALL_WARP=y / RUN_BENCH=y и т.п.
    # Telegram настраивается автоматически, только если в конфиге задан TG_BOT_TOKEN.

    FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"
    echo -e "\nНастройка сервера для $FULL_DOMAIN...\n"; sleep 2

    [[ "$SETUP_SSH" =~ ^[Yy]$ ]] && comp_ssh || echo "Пропуск SSH по ключу..."
    comp_swap
    comp_packages
    comp_fail2ban
    comp_autoupdates
    comp_ipv6
    comp_ufw
    comp_sysctl
    comp_docker
    comp_disk
    [[ "$INSTALL_SPEEDTEST" =~ ^[Yy]$ ]] && comp_speedtest
    [[ "$INSTALL_WARP" =~ ^[Yy]$ ]] && comp_warp
    comp_node
    comp_web
    [[ -n "$TG_BOT_TOKEN" ]] && comp_telegram
    comp_diag

    notify_telegram "🚀 Нода <code>${FULL_DOMAIN}</code> установлена и готова ($(date '+%H:%M:%S %Z'))"

    echo -e "\n=========================================="
    echo "Готово! Перезагрузка через 10 секунд (Ctrl+C — отменить)."
    echo "=========================================="
    sleep 10
    reboot
}

# ##########################################################################
#  МЕНЮ
# ##########################################################################
components_menu() {
    set +e   # компоненты best-effort: ошибка одного не должна ронять меню целиком
    while true; do
        echo -e "\n===== Компоненты (доустановить / переустановить) ====="
        echo " 1) Cloudflare WARP"
        echo " 2) Docker"
        echo " 3) Нода Remnanode (передеплой)"
        echo " 4) Веб: заглушка + сертификат + Nginx (+DNS)"
        echo " 5) UFW-фаервол"
        echo " 6) Sysctl-тюнинг ядра"
        echo " 7) Swap-файл"
        echo " 8) SSH по ключу"
        echo " 9) Speedtest CLI"
        echo "10) Отключить IPv6 в GRUB"
        echo "--- Безопасность / обслуживание ---"
        echo "11) Telegram-уведомления (SSH/ребут/падение ноды)"
        echo "12) fail2ban (jail.local)"
        echo "13) Автообновления безопасности"
        echo "14) Защита диска (лог-ротация Docker + journald)"
        echo "15) Обновить ноду (compose pull)"
        echo "16) Логи/статус ноды"
        echo "--- Диагностика ---"
        echo "17) bench.sh   18) ipregion   19) стриминги"
        echo " 0) Назад"
        read -ep "Выбор: " c
        case "$c" in
            1) comp_warp ;;   2) comp_docker ;;   3) comp_node ;;   4) comp_web ;;
            5) comp_ufw ;;    6) comp_sysctl ;;   7) comp_swap ;;   8) comp_ssh ;;
            9) comp_speedtest ;; 10) comp_ipv6 ;;
            11) comp_telegram ;; 12) comp_fail2ban ;; 13) comp_autoupdates ;; 14) comp_disk ;;
            15) comp_node_update ;; 16) comp_node_logs ;;
            17) run_bench ;; 18) run_geo ;; 19) run_media ;;
            0) set -e; return ;;
            *) echo "Нет такого пункта." ;;
        esac
        echo -e "\n[Готово] Компонент обработан."
    done
}

main_menu() {
    while true; do
        echo -e "\n=========================================="
        echo "  Установщик ноды rabotahrista"
        echo "=========================================="
        echo " 1) Полная установка"
        echo " 2) Доустановить/переустановить компонент"
        echo " 0) Выход"
        read -ep "Выбор: " m
        case "$m" in
            1) full_install ;;
            2) components_menu ;;
            0) exit 0 ;;
            *) echo "Нет такого пункта." ;;
        esac
    done
}

# ##########################################################################
#  ТОЧКА ВХОДА
# ##########################################################################
if [[ -n "$1" && -f "$1" ]]; then
    echo "Загружаю конфигурацию из файла: $1"
    # shellcheck disable=SC1090
    source "$1"
    NONINTERACTIVE=1
fi

if [[ -n "$NONINTERACTIVE" ]] || { [[ -n "$DOMAIN" ]] && [[ -n "$SUBDOMAIN" ]] && [[ -n "$REMNA_SECRET" ]]; }; then
    NONINTERACTIVE=1
    full_install
else
    main_menu
fi
