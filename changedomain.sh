#!/bin/bash

# Остановка при критических ошибках
set -e
trap 'echo -e "\n[ОШИБКА] Скрипт прерван на строке $LINENO." >&2; exit 1' ERR

# Проверка на выполнение от root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт с правами root (sudo bash ...)"
  exit 1
fi

echo -e "\n=========================================="
echo "Утилита миграции ноды на новый домен"
echo "=========================================="

# ==========================================
# 1. Сбор данных
# ==========================================
while [[ -z "$DOMAIN" ]]; do
    read -p "Введите основной домен (например, domain.com): " DOMAIN
done

while [[ -z "$SUBDOMAIN" ]]; do
    read -p "Введите имя этой ноды/субдомен (например, node-1): " SUBDOMAIN
done

FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"
echo -e "\nНачинаем перенос ноды на $FULL_DOMAIN..."

# ==========================================
# 2. Проверка DNS
# ==========================================
SERVER_IP=$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org)
echo -e "\n[ОЖИДАНИЕ] Проверка привязки домена $FULL_DOMAIN к IP $SERVER_IP..."

ATTEMPTS=0
MAX_ATTEMPTS=30

while true; do
    # Добавлено || true, чтобы set -e не убил скрипт, если команда dig вернет ошибку
    RESOLVED_IP=$(dig +short "$FULL_DOMAIN" 2>/dev/null | tail -n1 || true)
    
    if [ "$RESOLVED_IP" == "$SERVER_IP" ]; then
        echo -e "-> DNS успешно обновлен! Домен указывает на $SERVER_IP\n"
        break
    fi
    
    # БЕЗОПАСНЫЙ инкремент (не возвращает ошибку при нуле)
    ATTEMPTS=$((ATTEMPTS + 1))
    
    echo "Попытка $ATTEMPTS/$MAX_ATTEMPTS: DNS еще не обновился (Сервер: $SERVER_IP, Домен: ${RESOLVED_IP:-ПУСТО}). Ждем 10 сек..."
    sleep 10
    
    if [ "$ATTEMPTS" -eq "$MAX_ATTEMPTS" ]; then
        echo -e "\n[ВНИМАНИЕ] Прошло 5 минут, но DNS так и не обновился!"
        echo "Убедитесь, что создали A-запись для $SUBDOMAIN, ведущую на $SERVER_IP."
        read -p "Нажмите Enter, чтобы попробовать еще $MAX_ATTEMPTS раз, или Ctrl+C для выхода..."
        ATTEMPTS=0
    fi
done

# ==========================================
# 3. Выпуск нового SSL сертификата
# ==========================================
echo "Выпуск SSL сертификата для $FULL_DOMAIN..."
certbot --nginx -d "$FULL_DOMAIN" --register-unsafely-without-email --agree-tos --non-interactive

# ==========================================
# 4. Настройка нового конфига Nginx
# ==========================================
echo "Генерация нового конфига Nginx..."

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

# ==========================================
# 5. Интерактивная зачистка (Nginx + Certbot)
# ==========================================
echo -e "\n=========================================="
echo "=== Очистка старых конфигураций Nginx ==="
declare -a nginx_configs
shopt -s nullglob
for conf in /etc/nginx/sites-available/*; do
    [ -f "$conf" ] || continue
    basename_conf=$(basename "$conf")
    # Исключаем только что созданный конфиг
    if [[ "$basename_conf" != "$FULL_DOMAIN" ]]; then
        nginx_configs+=("$basename_conf")
    fi
done

if [ ${#nginx_configs[@]} -gt 0 ]; then
    echo "Найдены следующие конфигурации Nginx:"
    for i in "${!nginx_configs[@]}"; do
        echo "$((i+1)): ${nginx_configs[$i]}"
    done
    echo "c: Пропустить этот шаг"
    
    read -p "Укажите номера для удаления (например: 1, 2) или 'c': " choices
    if [[ "$choices" != "c" && "$choices" != "C" && -n "$choices" ]]; then
        # Заменяем запятые на пробелы для цикла
        choices=$(echo "$choices" | tr ',' ' ')
        for choice in $choices; do
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#nginx_configs[@]}" ]; then
                index=$((choice-1))
                conf_to_delete="${nginx_configs[$index]}"
                echo " -> Удаление файла: $conf_to_delete"
                rm -f "/etc/nginx/sites-available/$conf_to_delete"
            fi
        done
    fi
else
    echo "Старых конфигураций Nginx не найдено."
fi

echo -e "\n=== Очистка сертификатов Certbot ==="
declare -a certbot_certs
for cert_conf in /etc/letsencrypt/renewal/*.conf; do
    cert_name=$(basename "$cert_conf" .conf)
    # Исключаем только что созданный сертификат
    if [[ "$cert_name" != "$FULL_DOMAIN" ]]; then
        certbot_certs+=("$cert_name")
    fi
done
shopt -u nullglob

if [ ${#certbot_certs[@]} -gt 0 ]; then
    echo "Найдены следующие сертификаты в Certbot:"
    for i in "${!certbot_certs[@]}"; do
        echo "$((i+1)): ${certbot_certs[$i]}"
    done
    echo "c: Пропустить этот шаг"
    
    read -p "Укажите номера для удаления (например: 1 3) или 'c': " choices
    if [[ "$choices" != "c" && "$choices" != "C" && -n "$choices" ]]; then
        choices=$(echo "$choices" | tr ',' ' ')
        for choice in $choices; do
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#certbot_certs[@]}" ]; then
                index=$((choice-1))
                cert_to_delete="${certbot_certs[$index]}"
                echo " -> Удаление сертификата: $cert_to_delete"
                # Используем штатную команду certbot, добавлено || true для безопасности
                certbot delete --cert-name "$cert_to_delete" --non-interactive || true
            fi
        done
    fi
else
    echo "Старых сертификатов Certbot не найдено."
fi

# ==========================================
# 6. Перезапуск Nginx
# ==========================================
echo -e "\nПерезапуск Nginx..."

# Безопасно очищаем симлинки, чтобы не было "мертвых" конфигов
rm -f /etc/nginx/sites-enabled/*

# Включаем только наш новый домен
ln -sf /etc/nginx/sites-available/$FULL_DOMAIN /etc/nginx/sites-enabled/

# Проверяем конфиг и применяем
nginx -t
systemctl restart nginx

echo -e "\n=========================================="
echo "✅ УСПЕШНО! Нода переведена на $FULL_DOMAIN."
echo "=========================================="
