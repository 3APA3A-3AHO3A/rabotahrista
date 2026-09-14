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

# ##########################################################################
#  NGINX — ПРАВИЛА ИГРЫ
#
#  Установщик считает nginx чужой территорией. Поводом стала авария: он
#  неверно определил домен ноды, переписал конфиг соседнего сайта своим
#  шаблоном и снял с публикации настоящий конфиг ноды. Чинили руками.
#
#  Теперь так:
#    * автоматическая починка (--repair, пункт 4 меню) nginx НЕ ТРОГАЕТ
#      вообще — только печатает, что и как поправить;
#    * ручная правка (пункт 2 -> 4 меню, смена домена) сначала показывает
#      готовый конфиг целиком и спрашивает подтверждение;
#    * сам, без спроса, конфиг пишется в одном случае — когда в nginx для
#      этого домена ещё ничего нет и других сайтов тоже нет. Ломать нечего.
# ##########################################################################

# Каталог, из которого отдаётся ACME-челлендж. Файлы сюда кладёт certbot,
# а отдаёт их nginx — той самой location, которую мы рекомендуем прописать.
acme_prepare_webroot() {
    mkdir -p /var/lib/letsencrypt/.well-known/acme-challenge
    chown -R www-data:www-data /var/lib/letsencrypt/.well-known 2>/dev/null || true
    chmod -R 755 /var/lib/letsencrypt/.well-known
    return 0
}

# Проверяем не «совпадает ли IP», а то, что реально нужно Let's Encrypt:
# доходит ли запрос к /.well-known/acme-challenge/ до ЭТОГО сервера.
# За оранжевым облаком Cloudflare IP никогда не совпадёт — и это нормально.
acme_reachable() {
    local token file url got i
    acme_prepare_webroot
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

# Наш ли это конфиг. Метку добавили не сразу, поэтому файлы прежних версий
# узнаём по двум приметам шаблона: заглушка ssl_reject_handshake и корень
# /var/www/stub. Всё остальное — чужое, и мы к нему не прикасаемся.
rh_owns_nginx_site() {
    local f="$1"
    grep -qF "$NGINX_MARK" "$f" 2>/dev/null && return 0
    grep -q 'ssl_reject_handshake' "$f" 2>/dev/null \
        && grep -q '/var/www/stub' "$f" 2>/dev/null && return 0
    return 1
}

# Кто, кроме конфига $1, объявляет заглушку default_server на 8443.
# Она в nginx может быть только одна: вторая — и nginx -t падает на duplicate.
nginx_other_default() {
    local dom="$1" link base
    for link in "$NGINX_ENABLED"/*; do
        [[ -e "$link" ]] || continue
        base=$(basename "$link")
        if [[ "$base" == "$dom" ]]; then continue; fi
        if grep -qE 'listen[^;]*8443[^;]*default_server' "$link" 2>/dev/null; then
            echo "$base"
            return 0
        fi
    done
    return 0
}

# Насколько безопасно писать конфиг самим, без человека:
#   clean   — файла для домена нет и других сайтов нет: ломать нечего
#   ours    — файл наш, перезапись его же шаблоном сюрпризом не будет
#   foreign — файл или соседний сайт чужие: только показываем и советуем
nginx_write_safety() {
    local dom="$1" link base
    local site="$NGINX_AVAIL/$dom"
    if [[ -f "$site" ]]; then
        if rh_owns_nginx_site "$site"; then echo "ours"; else echo "foreign"; fi
        return 0
    fi
    for link in "$NGINX_ENABLED"/*; do
        [[ -e "$link" ]] || continue
        base=$(basename "$link")
        if [[ "$base" == "default" ]]; then continue; fi
        echo "foreign"
        return 0
    done
    echo "clean"
    return 0
}

# Единственное место, где живёт шаблон конфига. Печатает его в stdout и
# ничего не трогает: из этой же функции берётся и текст рекомендации.
# $2 = http-only — только блок на 80 порту. Он нужен ДО выпуска сертификата:
# TLS-блок ссылается на файлы, которых ещё нет, и nginx -t на них упадёт.
nginx_render_site() {
    local dom="$1" mode="${2:-full}"
    echo "$NGINX_MARK"
    cat <<EOF
server {
    listen 80;
    server_name $dom;

    location /.well-known/acme-challenge/ {
        root /var/lib/letsencrypt/;
        default_type "text/plain";
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
    if [[ "$mode" == "http-only" ]]; then
        return 0
    fi

    if [[ -z "$(nginx_other_default "$dom")" ]]; then
        cat <<'EOF'

server {
    listen 127.0.0.1:8443 ssl http2 proxy_protocol default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOF
    fi

    cat <<EOF

server {
    listen 127.0.0.1:8443 ssl http2 proxy_protocol;
    server_name $dom;

    ssl_certificate ${LE_LIVE}/$dom/fullchain.pem;
    ssl_certificate_key ${LE_LIVE}/$dom/privkey.pem;

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
    return 0
}

# Что сейчас с конфигом этого домена. Только читает.
nginx_report_state() {
    local dom="$1" other
    local site="$NGINX_AVAIL/$dom"
    echo "  Домен ноды:  $dom"
    if [[ ! -f "$site" ]]; then
        echo "  Конфиг:      $site — НЕТ"
    elif rh_owns_nginx_site "$site"; then
        echo "  Конфиг:      $site — есть, наш"
    else
        echo "  Конфиг:      $site — есть, писали НЕ мы (трогать не буду)"
    fi
    if [[ -e "$NGINX_ENABLED/$dom" ]]; then
        echo "  Публикация:  включён"
    else
        echo "  Публикация:  ВЫКЛЮЧЕН (ссылки в sites-enabled нет)"
    fi
    if [[ -f "$site" ]] && ! awk '/listen .*8443/,0' "$site" 2>/dev/null | grep -q 'acme-challenge'; then
        echo "  ACME в TLS:  НЕТ — продление за «Always Use HTTPS» провалится"
    fi
    other=$(nginx_other_default "$dom")
    if [[ -n "$other" ]]; then
        echo "  Заглушка:    default_server на 8443 держит $other — свою не добавляю"
    fi
    return 0
}

# Рекомендация вместо правки. Ничего не меняет — это её единственная задача.
nginx_advise() {
    local dom="$1" tmp
    echo
    echo "=========================================="
    echo "  КОНФИГ NGINX — РЕКОМЕНДАЦИЯ"
    echo "=========================================="
    nginx_report_state "$dom"
    echo
    echo "  Ничего не изменено. Ниже — конфиг, который скрипт считает правильным."
    echo "  Сверьте со своим и перенесите то, чего не хватает."
    echo
    echo "------ $NGINX_AVAIL/$dom ------"
    nginx_render_site "$dom"
    echo "------ конец конфига ------"
    echo
    tmp=$(mktemp) && nginx_render_site "$dom" > "$tmp" 2>/dev/null || tmp=""
    if [[ -n "$tmp" && -f "$NGINX_AVAIL/$dom" ]]; then
        if diff -u "$NGINX_AVAIL/$dom" "$tmp" >/dev/null 2>&1; then
            echo "  Ваш конфиг уже совпадает с рекомендуемым — править нечего."
        else
            echo "  Отличия от того, что лежит сейчас (- ваше, + рекомендуемое):"
            diff -u "$NGINX_AVAIL/$dom" "$tmp" 2>/dev/null | tail -n +3 | sed 's/^/    /'
        fi
        echo
    fi
    if [[ -n "$tmp" ]]; then rm -f "$tmp"; fi
    echo "  Применить руками:"
    echo "    sudo nano $NGINX_AVAIL/$dom"
    echo "    sudo ln -sf $NGINX_AVAIL/$dom $NGINX_ENABLED/"
    echo "    sudo nginx -t && sudo systemctl reload nginx"
    echo
    echo "  Либо дать это сделать скрипту: меню, пункт 2 -> 4 (спросит подтверждение)."
    echo "=========================================="
    return 0
}

# Собственно запись. Зовётся только там, где человек этого явно захотел,
# либо на сервере, где в nginx ещё ничего нет.
nginx_apply_site() {
    local dom="$1" mode="${2:-full}"
    local site="$NGINX_AVAIL/$dom" backup=""
    echo ">>> Пишу конфиг nginx для $dom..."

    if [[ -f "$site" ]] && ! grep -qF "$NGINX_MARK" "$site" 2>/dev/null; then
        backup="$site.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$site" "$backup"
        echo "  Конфиг без нашей метки — сохранил копию: $(basename "$backup")"
    fi

    nginx_render_site "$dom" "$mode" > "$site"
    ln -sf "$site" "$NGINX_ENABLED"/
    if ! nginx -t >>"$SETUP_LOG" 2>&1; then
        echo "  [СБОЙ] nginx -t не прошёл (см. $SETUP_LOG)"
        if [[ -n "$backup" ]]; then
            cp -a "$backup" "$site"
            echo "  Вернул прежний конфиг $dom из копии."
        else
            rm -f "$NGINX_ENABLED/$dom"
            echo "  Снял свой конфиг с публикации, чтобы nginx остался рабочим."
        fi
        nginx -t >>"$SETUP_LOG" 2>&1 \
            || echo "  [ВНИМАНИЕ] nginx -t не проходит и после отката — конфиг был сломан ещё до нас."
        return 1
    fi
    systemctl reload nginx >>"$SETUP_LOG" 2>&1 || systemctl restart nginx >>"$SETUP_LOG" 2>&1 || true
    if ! systemctl is-active --quiet nginx; then
        echo "  [СБОЙ] nginx не работает после применения (см. $SETUP_LOG)"
        return 1
    fi
    echo "  Готово: конфиг записан и опубликован."
    return 0
}

# Что делает полная установка. Вопросов не задаёт — их задают заранее.
nginx_auto_site() {
    local dom="$1" safety
    if [[ -n "${NGINX_MENU:-}" ]]; then
        return 0                      # в меню конфиг показывают и спрашивают отдельно
    fi
    safety=$(nginx_write_safety "$dom")
    case "$safety" in
        clean|ours)
            nginx_apply_site "$dom"
            return $?
            ;;
        *)
            echo "  В nginx уже есть конфиги, написанные не нами — не трогаю."
            nginx_advise "$dom"
            return 1
            ;;
    esac
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
    if [ -d "$LE_LIVE/$FULL_DOMAIN" ]; then
        echo "  Сертификат уже есть, пропускаем."
    else
        # Раньше на время выпуска подкладывался временный конфиг с
        # "listen 80 default_server" и снималась ссылка на default — то есть
        # ради сертификата правился чужой nginx. Больше так не делаем:
        # HTTP-часть своего конфига публикуется только на чистом сервере.
        if [[ "$(nginx_write_safety "$FULL_DOMAIN")" == "clean" ]]; then
            nginx_apply_site "$FULL_DOMAIN" http-only || { cf_restore_proxy; return 1; }
        fi
        if ! acme_reachable; then
            echo "  [СБОЙ] ACME-путь снаружи не отдаётся — сертификат не выпускаю."
            echo "         Причины: A-запись ведёт на другой сервер (сейчас ${ACME_RESOLVED:-ПУСТО}, здесь ${SERVER_IP:-?}),"
            echo "         закрыт порт 80, или в nginx нет отдачи /.well-known/acme-challenge/."
            echo "         Нужный кусок конфига — ниже."
            nginx_advise "$FULL_DOMAIN"
            cf_restore_proxy
            return 1
        fi
        if ! certbot certonly --webroot -w /var/lib/letsencrypt -d "$FULL_DOMAIN" \
                --register-unsafely-without-email --agree-tos --non-interactive \
                --keep-until-expiring >>"$SETUP_LOG" 2>&1; then
            echo "  [СБОЙ] Certbot не выпустил сертификат (см. $SETUP_LOG)"
            cf_restore_proxy
            return 1
        fi
    fi

    if ! nginx_auto_site "$FULL_DOMAIN"; then
        cf_restore_proxy
        return 1
    fi

    cf_restore_proxy
    return 0
}

# Пункт меню «Веб». Из full_install не вызывается, поэтому здесь можно и нужно
# спрашивать: показываем готовый конфиг, отличия от текущего — и ждём "y".
comp_web_nginx() {
    local dom="${FULL_DOMAIN:-}" ans
    if [[ -z "$dom" ]]; then
        ask_domain; ask_subdomain
        dom="${SUBDOMAIN}.${DOMAIN}"
    fi
    nginx_advise "$dom"
    if [[ -n "$NONINTERACTIVE" ]]; then
        echo "  Автоматический режим — конфиг не трогаю."
        return 0
    fi
    read -ep "  Записать этот конфиг и перезапустить nginx? [y/N]: " ans || ans=""
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        echo "  Ничего не изменено."
        return 0
    fi
    nginx_apply_site "$dom"
}

comp_web_menu() {
    local NGINX_MENU=1
    comp_web || echo "  (шаг сертификата завершился с ошибкой — конфиг всё равно покажу)"
    comp_web_nginx
}
