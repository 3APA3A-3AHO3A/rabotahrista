# ##########################################################################
#  ВЕБ
#  Сертификат Let's Encrypt, Cloudflare DNS и nginx
# ##########################################################################

# Обращение к Cloudflare API. Токен уходит через stdin (--config -),
# а не в аргументах — иначе он виден в ps любому пользователю сервера.
cf_api() {
    local method="$1" path="$2" data="${3:-}"
    local args=(-s --max-time 30 -X "$method"
                "https://api.cloudflare.com/client/v4/$path"
                -H "Content-Type: application/json")
    [[ -n "$data" ]] && args+=(--data "$data")
    printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN" \
        | curl --config - "${args[@]}" 2>/dev/null || echo '{"success":false,"errors":["нет связи с Cloudflare"]}'
    return 0
}

# Возвращает оранжевое облако, если мы его снимали на время выпуска сертификата.
# Вызывается на любом выходе из comp_web: раньше неудачный перевыпуск оставлял
# запись серой, и настоящий IP сервера становился публичным.
cf_restore_proxy() {
    [[ -z "$ZONE_ID" || -z "$RECORD_ID" || -z "$SERVER_IP" ]] && return 0
    local want="false"
    [[ "$CF_PROXIED" == "true" || "$CF_WAS_PROXIED" == "true" ]] && want="true"
    [[ "$want" != "true" ]] && return 0
    echo ">>> Возвращаю оранжевое облако Cloudflare..."
    cf_api PUT "zones/$ZONE_ID/dns_records/$RECORD_ID" \
        '{"type":"A","name":"'"$FULL_DOMAIN"'","content":"'"$SERVER_IP"'","ttl":1,"proxied":true}' >/dev/null
    return 0
}

# Временный конфиг nginx, который отдаёт только ACME-челлендж
ACME_SITE="/etc/nginx/sites-available/00-acme"

acme_serve_start() {
    mkdir -p /var/lib/letsencrypt/.well-known/acme-challenge
    chown -R www-data:www-data /var/lib/letsencrypt/.well-known 2>/dev/null || true
    chmod -R 755 /var/lib/letsencrypt/.well-known
    cat > "$ACME_SITE" <<'EOF'
server {
    listen 80 default_server;
    server_name _;
    location /.well-known/acme-challenge/ {
        root /var/lib/letsencrypt/;
        default_type "text/plain";
    }
    location / { return 404; }
}
EOF
    rm -f /etc/nginx/sites-enabled/default
    ln -sf "$ACME_SITE" /etc/nginx/sites-enabled/00-acme
    if ! nginx -t >>"$SETUP_LOG" 2>&1; then
        echo "  [СБОЙ] временный ACME-конфиг nginx не прошёл проверку (см. $SETUP_LOG)"
        rm -f /etc/nginx/sites-enabled/00-acme
        return 1
    fi
    systemctl restart nginx >>"$SETUP_LOG" 2>&1
}

acme_serve_stop() { rm -f /etc/nginx/sites-enabled/00-acme "$ACME_SITE"; }

# Проверяем не «совпадает ли IP», а то, что реально нужно Let's Encrypt:
# доходит ли запрос к /.well-known/acme-challenge/ до ЭТОГО сервера.
# За оранжевым облаком Cloudflare IP никогда не совпадёт — и это нормально.
acme_reachable() {
    local token file url got i
    token="rh-$(date +%s)-$RANDOM"
    file="/var/lib/letsencrypt/.well-known/acme-challenge/$token"
    echo "$token" > "$file"; chmod 644 "$file"
    url="http://$FULL_DOMAIN/.well-known/acme-challenge/$token"

    ACME_RESOLVED=$(dig +short "$FULL_DOMAIN" A 2>/dev/null | grep -E '^[0-9.]+$' | tail -n1 || true)
    echo "  $FULL_DOMAIN резолвится в ${ACME_RESOLVED:-ПУСТО}, IP этого сервера: ${SERVER_IP:-?}"
    if [[ -n "$ACME_RESOLVED" && -n "$SERVER_IP" && "$ACME_RESOLVED" != "$SERVER_IP" ]]; then
        echo "  IP не совпадают — обычно это прокси Cloudflare (оранжевое облако), выпуску это не мешает."
    fi
    echo "  Проверяю доступность ACME-пути снаружи (до 2 минут)..."
    for i in $(seq 1 20); do
        got=$(curl -fsSL --max-time 10 "$url" 2>/dev/null || true)
        if [[ "$got" == "$token" ]]; then
            echo "  ОК: запрос дошёл до этого сервера (попытка $i). Let's Encrypt тоже дойдёт."
            rm -f "$file"; return 0
        fi
        echo "  Попытка $i/20: пока не отвечает. Жду 6 сек..."
        sleep 6
    done
    rm -f "$file"
    return 1
}

# Пишет конфиг nginx для домена, включает его и перезапускает nginx.
# Вынесено в функцию, потому что этим же занимается смена домена (lib/75-domain.sh):
# две копии шаблона рано или поздно разъедутся.
write_nginx_site() {
    local dom="$1"
    echo ">>> Конфиг nginx для $dom..."
    cat <<EOF > "/etc/nginx/sites-available/$dom"
server {
    listen 80;
    server_name $dom;

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
    server_name $dom;

    ssl_certificate /etc/letsencrypt/live/$dom/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$dom/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
    ssl_session_cache shared:SSL:1m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;

    # Нужно для продления: при "Always Use HTTPS" в Cloudflare проверка приходит
    # сюда по HTTPS, и без этого блока отдавалась бы заглушка вместо токена.
    location /.well-known/acme-challenge/ {
        root /var/lib/letsencrypt/;
        default_type "text/plain";
    }

    location / {
        root /var/www/stub;
        index index.html;
        try_files \$uri \$uri/ /index.html;
        add_header Cache-Control "no-store, no-cache, must-revalidate";
    }
}
EOF
    rm -f /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    # Конфиг прошлой ноды (другой субдомен) содержит такой же default_server на
    # 127.0.0.1:8443 — nginx -t упадёт на duplicate. Снимаем всё лишнее.
    local link
    for link in /etc/nginx/sites-enabled/*; do
        [[ -e "$link" ]] || continue
        [[ "$(basename "$link")" == "$dom" ]] && continue
        grep -q 'proxy_protocol' "$link" 2>/dev/null && rm -f "$link"
    done
    ln -sf "/etc/nginx/sites-available/$dom" /etc/nginx/sites-enabled/
    if ! nginx -t >>"$SETUP_LOG" 2>&1; then
        echo "  [СБОЙ] nginx -t не прошёл (см. $SETUP_LOG)"
        return 1
    fi
    systemctl restart nginx >>"$SETUP_LOG" 2>&1
    if ! systemctl is-active --quiet nginx; then
        echo "  [СБОЙ] nginx не запустился (см. $SETUP_LOG)"
        return 1
    fi
    return 0
}

comp_web() {
    ask_domain; ask_subdomain; ask_cf
    FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"
    get_server_ip

    echo ">>> Заглушка сайта..."
    mkdir -p /var/www/stub
    wget -qO /var/www/stub/index.html "$INDEX_URL"
    [ -s /var/www/stub/index.html ] || echo "<html><body><h1>Hello World</h1></body></html>" > /var/www/stub/index.html

    if [[ "$SETUP_CF" =~ ^[Yy]$ ]] && [[ -n "$CF_API_TOKEN" ]]; then
        echo ">>> DNS в Cloudflare..."
        if [[ -z "$SERVER_IP" ]]; then
            echo "  [СБОЙ] не знаю внешний IP сервера — нечего прописывать в DNS"
            return 1
        fi
        local resp
        resp=$(cf_api GET "zones?name=$DOMAIN")
        ZONE_ID=$(jq -r '.result[0].id // empty' <<< "$resp")
        if [[ -z "$ZONE_ID" ]]; then
            echo "  [ВНИМАНИЕ] Зона $DOMAIN не найдена или у токена нет прав."
            echo "    Ответ API: $(jq -rc '.errors // .success' <<< "$resp" 2>/dev/null | head -c 200)"
            echo "    Продолжаю в ручном режиме: A-запись должна быть заведена вами."
        else
            resp=$(cf_api GET "zones/$ZONE_ID/dns_records?name=$FULL_DOMAIN&type=A")
            RECORD_ID=$(jq -r '.result[0].id // empty' <<< "$resp")
            # Запоминаем, было ли включено оранжевое облако: снимем на время выпуска
            # сертификата и вернём обратно, даже если выпуск сорвётся.
            CF_WAS_PROXIED=$(jq -r '.result[0].proxied // false' <<< "$resp")
            local gray='{"type":"A","name":"'"$FULL_DOMAIN"'","content":"'"$SERVER_IP"'","ttl":1,"proxied":false}'
            if [[ -n "$RECORD_ID" ]]; then
                resp=$(cf_api PUT "zones/$ZONE_ID/dns_records/$RECORD_ID" "$gray")
            else
                resp=$(cf_api POST "zones/$ZONE_ID/dns_records" "$gray")
                RECORD_ID=$(jq -r '.result.id // empty' <<< "$resp")
            fi
            if [[ "$(jq -r '.success' <<< "$resp")" != "true" ]]; then
                echo "  [СБОЙ] Cloudflare отклонил запись:"
                echo "    $(jq -rc '.errors' <<< "$resp" 2>/dev/null | head -c 300)"
                return 1
            fi
            echo "  A-запись $FULL_DOMAIN -> $SERVER_IP обновлена (пока без прокси)."
            sleep 10
        fi
    fi

    echo ">>> Выпуск SSL..."
    if [ -d "/etc/letsencrypt/live/$FULL_DOMAIN" ]; then
        echo "  Сертификат уже есть, пропускаем."
    else
        acme_serve_start || return 1
        if ! acme_reachable; then
            echo "  [ВНИМАНИЕ] ACME-проверка не дошла до сервера. Возможные причины:"
            echo "    - A-запись $FULL_DOMAIN ведёт на другой сервер (сейчас: ${ACME_RESOLVED:-ПУСТО}, здесь: $SERVER_IP)"
            echo "    - порт 80 закрыт (проверь: ufw status | grep 80)"
            echo "    - в Cloudflare включено правило, ломающее /.well-known/acme-challenge/"
            # Спросить заранее нельзя — ответ зависит от результата проверки,
            # а останавливать установку вопросом мы не имеем права. Поэтому
            # пробуем: проверка бывает ложноотрицательной (сервер не всегда
            # достаёт собственный внешний адрес), а неудачная попытка certbot
            # ничего не ломает — шаг просто пометится сбоем.
            echo "  Пробую выпустить сертификат несмотря на это."
        fi
        if ! certbot certonly --webroot -w /var/lib/letsencrypt -d "$FULL_DOMAIN" \
                --register-unsafely-without-email --agree-tos --non-interactive \
                --keep-until-expiring >>"$SETUP_LOG" 2>&1; then
            acme_serve_stop
            echo "  [СБОЙ] Certbot не выпустил сертификат (см. $SETUP_LOG)"
            cf_restore_proxy
            return 1
        fi
        acme_serve_stop
    fi

    if ! write_nginx_site "$FULL_DOMAIN"; then
        cf_restore_proxy
        return 1
    fi

    cf_restore_proxy
    return 0
}
