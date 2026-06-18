#!/bin/bash

# Остановка при ошибках и подробное логирование
set -e
trap 'echo -e "\n[ОШИБКА] Скрипт прерван из-за непредвиденной ошибки на строке $LINENO. Код: $?" >&2; exit 1' ERR

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
# 8. Настройка файловой структуры для Nginx (Заглушка)
# ==========================================
echo "Создание заглушки сайта..."
mkdir -p /var/www/stub
mkdir -p /var/lib/letsencrypt/.well-known/acme-challenge/
chown -R www-data:www-data /var/lib/letsencrypt/.well-known
chmod -R 755 /var/lib/letsencrypt/.well-known
echo "test" | tee /var/lib/letsencrypt/.well-known/acme-challenge/test.txt

# Записываем HTML (используем 'EOF' в кавычках, чтобы Bash не трогал код внутри)
cat <<'EOF' > /var/www/stub/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-width=1.0">
    <title>Nexus Cloud | Secure Workspace</title>
    <style>
        :root {
            --primary: #2563eb;
            --primary-hover: #1d4ed8;
            --bg: #0f172a;
            --surface: #1e293b;
            --text-main: #f8fafc;
            --text-muted: #94a3b8;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: system-ui, -apple-system, sans-serif; background-color: var(--bg); color: var(--text-main); display: flex; flex-direction: column; min-height: 100vh; overflow-x: hidden; }
        
        /* Navbar */
        nav { display: flex; justify-content: space-between; align-items: center; padding: 1.5rem 5%; background: rgba(30, 41, 59, 0.8); backdrop-filter: blur(10px); border-bottom: 1px solid #334155; }
        .logo { font-size: 1.5rem; font-weight: 800; letter-spacing: -0.5px; display: flex; align-items: center; gap: 10px; }
        .logo-icon { width: 30px; height: 30px; background: linear-gradient(135deg, #3b82f6, #8b5cf6); border-radius: 8px; }
        .server-status { display: flex; align-items: center; gap: 8px; font-size: 0.875rem; color: #10b981; font-weight: 500; background: rgba(16, 185, 129, 0.1); padding: 6px 12px; border-radius: 20px; }
        .status-dot { width: 8px; height: 8px; background-color: #10b981; border-radius: 50%; box-shadow: 0 0 10px #10b981; animation: pulse 2s infinite; }
        
        /* Main Container */
        main { flex: 1; display: grid; grid-template-columns: 1fr 1fr; align-items: center; gap: 4rem; padding: 4rem 5%; max-width: 1400px; margin: 0 auto; }
        
        /* Left Side: Marketing / Justification */
        .hero-text h1 { font-size: 3.5rem; line-height: 1.1; margin-bottom: 1.5rem; }
        .hero-text h1 span { background: linear-gradient(135deg, #60a5fa, #a78bfa); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
        .hero-text p { font-size: 1.125rem; color: var(--text-muted); margin-bottom: 2rem; line-height: 1.6; max-width: 500px; }
        .features { display: grid; gap: 1.5rem; }
        .feature-item { display: flex; align-items: center; gap: 1rem; background: var(--surface); padding: 1rem 1.5rem; border-radius: 12px; border: 1px solid #334155; }
        .feature-icon { width: 40px; height: 40px; background: rgba(59, 130, 246, 0.1); color: #60a5fa; border-radius: 8px; display: flex; align-items: center; justify-content: center; font-weight: bold; font-size: 1.2rem;}
        
        /* Right Side: Login Form */
        .login-card { background: var(--surface); padding: 3rem; border-radius: 24px; box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.5); border: 1px solid #334155; position: relative; overflow: hidden; }
        .login-card::before { content: ''; position: absolute; top: 0; left: 0; right: 0; height: 4px; background: linear-gradient(90deg, #3b82f6, #8b5cf6); }
        .form-header { text-align: center; margin-bottom: 2.5rem; }
        .form-header h2 { font-size: 1.75rem; margin-bottom: 0.5rem; }
        .form-header p { color: var(--text-muted); font-size: 0.9rem; }
        .input-group { margin-bottom: 1.5rem; }
        .input-group label { display: block; font-size: 0.875rem; color: var(--text-muted); margin-bottom: 0.5rem; font-weight: 500; }
        .input-group input { width: 100%; padding: 1rem; background: #0f172a; border: 1px solid #334155; border-radius: 8px; color: white; font-size: 1rem; transition: border-color 0.3s; }
        .input-group input:focus { outline: none; border-color: var(--primary); box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.2); }
        .btn-submit { width: 100%; padding: 1rem; background: var(--primary); color: white; border: none; border-radius: 8px; font-size: 1rem; font-weight: 600; cursor: pointer; transition: background 0.3s; display: flex; justify-content: center; align-items: center; gap: 10px; }
        .btn-submit:hover { background: var(--primary-hover); }
        
        /* Loading Animation */
        .loader { border: 3px solid rgba(255,255,255,0.3); border-radius: 50%; border-top: 3px solid white; width: 20px; height: 20px; animation: spin 1s linear infinite; display: none; }
        
        /* Footer */
        footer { padding: 2rem 5%; border-top: 1px solid #334155; text-align: center; color: var(--text-muted); font-size: 0.875rem; display: flex; justify-content: space-between; }
        .fake-metrics { display: flex; gap: 20px; }
        .metric span { font-weight: 600; color: #cbd5e1; }

        @keyframes pulse { 0% { box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.4); } 70% { box-shadow: 0 0 0 10px rgba(16, 185, 129, 0); } 100% { box-shadow: 0 0 0 0 rgba(16, 185, 129, 0); } }
        @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }

        /* Responsive */
        @media (max-width: 968px) {
            main { grid-template-columns: 1fr; padding: 2rem 5%; gap: 3rem; }
            .hero-text h1 { font-size: 2.5rem; }
            footer { flex-direction: column; gap: 1rem; }
        }
    </style>
</head>
<body>

    <nav>
        <div class="logo">
            <div class="logo-icon"></div>
            Nexus Cloud
        </div>
        <div class="server-status">
            <div class="status-dot"></div>
            Node Active
        </div>
    </nav>

    <main>
        <div class="hero-text">
            <h1>Your private <span>Enterprise Data Node</span></h1>
            <p>Access your secure workspace. Sync large project files, stream internal media assets, and manage continuous automated backups.</p>
            
            <div class="features">
                <div class="feature-item">
                    <div class="feature-icon">⚡</div>
                    <div>
                        <h3 style="font-size: 1.1rem; margin-bottom: 4px;">High-Speed Sync</h3>
                        <p style="font-size: 0.9rem; margin: 0; color: var(--text-muted);">Transfer multi-gigabyte files seamlessly.</p>
                    </div>
                </div>
                <div class="feature-item">
                    <div class="feature-icon">🎥</div>
                    <div>
                        <h3 style="font-size: 1.1rem; margin-bottom: 4px;">4K Media Streaming</h3>
                        <p style="font-size: 0.9rem; margin: 0; color: var(--text-muted);">Direct buffer-free access to raw video assets.</p>
                    </div>
                </div>
            </div>
        </div>

        <div class="login-card">
            <div class="form-header">
                <h2>Secure Portal Login</h2>
                <p>Authorized personnel only. Sessions are heavily encrypted.</p>
            </div>
            <form id="fakeLogin">
                <div class="input-group">
                    <label for="username">Workspace ID / Email</label>
                    <input type="text" id="username" placeholder="admin@nexus.local" required autocomplete="off">
                </div>
                <div class="input-group">
                    <label for="password">Access Token</label>
                    <input type="password" id="password" placeholder="••••••••••••" required>
                </div>
                <button type="submit" class="btn-submit" id="submitBtn">
                    <span id="btnText">Establish Connection</span>
                    <div class="loader" id="loader"></div>
                </button>
            </form>
        </div>
    </main>

    <footer>
        <div>&copy; <script>document.write(new Date().getFullYear())</script> Nexus Infrastructure. All rights reserved.</div>
        <div class="fake-metrics">
            <div class="metric">Traffic 24h: <span id="traffic-val">1.40 TB</span></div>
            <div class="metric">Uptime: <span id="uptime-val">99.9%</span></div>
        </div>
    </footer>

    <script>
        function updateDynamicMetrics() {
            const now = new Date();

            const baseTraffic = 1.2;
            const hourFactor = (now.getHours() * 0.02) + (now.getDate() * 0.01);
            const dynamicTraffic = (baseTraffic + (hourFactor % 0.7)).toFixed(2);
            
            document.getElementById('traffic-val').innerText = dynamicTraffic + ' TB';

            const uptimeFactor = 99.9 + ((now.getDate() % 9) / 100);
            document.getElementById('uptime-val').innerText = uptimeFactor.toFixed(2) + '%';
        }

        updateDynamicMetrics();

        document.getElementById('fakeLogin').addEventListener('submit', function(e) {
            e.preventDefault();
            
            const btn = document.getElementById('submitBtn');
            const text = document.getElementById('btnText');
            const loader = document.getElementById('loader');
            const inputs = document.querySelectorAll('input');

            text.innerText = 'Establishing TLS Tunnel...';
            loader.style.display = 'block';
            btn.style.opacity = '0.8';
            btn.style.cursor = 'wait';
            inputs.forEach(i => i.disabled = true);

            fetch('/api/v1/auth/token', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({
                    username: document.getElementById('username').value,
                    hash: btoa(document.getElementById('password').value)
                })
            })
            .then(response => {
                throw new Error('Access Denied');
            })
            .catch(err => {
               
                setTimeout(() => {
                    text.innerText = 'Connection Refused: Invalid Token';
                    loader.style.display = 'none';
                    btn.style.background = '#ef4444';
                    
                    setTimeout(() => {
                        text.innerText = 'Establish Connection';
                        btn.style.background = 'var(--primary)';
                        btn.style.opacity = '1';
                        btn.style.cursor = 'pointer';
                        inputs.forEach(i => {
                            i.disabled = false;
                            i.value = '';
                        });
                    }, 3000);
                }, 1800);
            });
        });
    </script>
</body>
</html>
EOF

# ==========================================
# 9. Получение SSL сертификата (до применения кастомного конфига Nginx)
# ==========================================
echo "Выпуск SSL сертификата..."
echo "[ОЖИДАНИЕ] Проверка привязки домена $FULL_DOMAIN к IP сервера..."
SERVER_IP=$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org)

for i in {1..30}; do
    # Получаем IP, на который указывает домен
    RESOLVED_IP=$(dig +short "$FULL_DOMAIN" | tail -n1)
    
    if [ "$RESOLVED_IP" == "$SERVER_IP" ]; then
        echo -e "-> DNS успешно обновлен! Домен указывает на $SERVER_IP\n"
        break
    fi
    
    echo "Попытка $i/30: DNS еще не обновился (Сервер: $SERVER_IP, Домен: ${RESOLVED_IP:-ПУСТО}). Ждем 10 сек..."
    sleep 10
    
    if [ "$i" -eq 30 ]; then
        echo -e "\n[ОШИБКА] DNS так и не обновился за 5 минут. Проверьте DNS. Скрипт прерван."
        exit 1
    fi
done
# Выпускаем сертификат с помощью стандартного конфига Nginx, чтобы Certbot сделал всё сам
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
    # Этот блок ловит всё, что не подошло по домену
    listen 127.0.0.1:8443 ssl http2 proxy_protocol default_server;
    server_name _;

    # Жестко обрываем TLS-соединение до выдачи сертификата!
    ssl_reject_handshake on;
}

server {
    listen 127.0.0.1:8443 ssl http2 proxy_protocol;
    server_name $FULL_DOMAIN;

    # SSL сертификаты Let's Encrypt
    ssl_certificate /etc/letsencrypt/live/$FULL_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$FULL_DOMAIN/privkey.pem;

    # Безопасность SSL
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

# Удаляем дефолтные конфиги, как ты и просил
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
