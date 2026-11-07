# ##########################################################################
#  ВЫХОДЫ ДЛЯ XRAY
#  warp-native (WARP интерфейсом warp через WireGuard) и Psiphon (SOCKS5)
# ##########################################################################

# Оба ставятся их собственными установщиками с GitHub — скрипт их не
# переписывает, а только запускает с нужными ответами и проверяет результат.
# Так обновления авторов приходят сами, а у нас нет второй копии чужого кода.

# Страна сервера — двумя буквами. Спрашиваем у Cloudflare: он отдаёт страну
# того, кто обратился (loc=), без сторонних сервисов геолокации.
node_country() {
    local c
    c=$(curl -fsS --max-time 10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
        | awk -F= '$1=="loc"{print $2}' | tr -d '\r\n')
    [[ "$c" =~ ^[A-Z]{2}$ ]] && echo "$c"
    return 0
}

warp_native_active() {
    ip link show warp >/dev/null 2>&1 && systemctl is-active --quiet wg-quick@warp && return 0
    return 1
}

# Через интерфейс warp трафик должен выходить из Cloudflare (warp=on)
warp_native_works() {
    curl -fsS --max-time 15 --interface warp https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
        | grep -q '^warp=on' && return 0
    return 1
}

comp_warp_native() {
    echo ">>> warp-native (WARP интерфейсом warp)..."
    local cc; cc=$(node_country)
    if [[ "$cc" == "RU" ]]; then
        echo "  Сервер в России — warp-native здесь не работает, пропускаю."
        echo "  Для RU-нод остаётся WARP на порту $WARP_PORT."
        return 0
    fi
    if warp_native_active && [[ -z "${RH_FORCE:-}" ]]; then
        echo "  Уже установлен и работает — не трогаю."
    else
        local f; f=$(mktemp)
        if ! curl -fsSL --max-time 60 "$WARP_NATIVE_URL" -o "$f" || ! bash -n "$f"; then
            rm -f "$f"; echo "  [СБОЙ] не удалось скачать установщик warp-native"; return 1
        fi
        # Ответы установщику: язык — русский, лицензии WARP+ нет, watchdog — 5 мин
        ui_step_status "warp-native: ставлю (wgcf, WireGuard, watchdog)"
        printf '2\n\n1\n' | bash "$f" >>"$SETUP_LOG" 2>&1 || true
        rm -f "$f"
    fi
    if ! warp_native_active; then
        echo "  [СБОЙ] интерфейс warp не поднялся (см. $SETUP_LOG)"
        return 1
    fi
    if warp_native_works; then
        echo "  Готово: интерфейс warp работает, выход через Cloudflare (warp=on)."
        echo "  В Xray: outbound freedom с sockopt.interface=\"warp\", mark 51888."
        return 0
    fi
    echo "  [СБОЙ] интерфейс warp поднят, но трафик через него не выходит в Cloudflare"
    return 1
}

psiphon_active() {
    systemctl is-active --quiet vps-psiphon 2>/dev/null && return 0
    return 1
}

# Адрес, на котором vps-psiphon опубликовал SOCKS: шлюз docker0 или 127.0.0.1
psiphon_socks_addr() {
    local a
    a=$(ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -E ":${PSIPHON_PORT}\$" | head -1)
    a="${a%:*}"
    [[ -z "$a" || "$a" == "0.0.0.0" || "$a" == "*" ]] && a="127.0.0.1"
    echo "$a"
    return 0
}

comp_psiphon() {
    echo ">>> Psiphon (SOCKS5 на порту $PSIPHON_PORT)..."
    if ! command -v docker >/dev/null 2>&1; then
        echo "  [СБОЙ] Psiphon работает в контейнере, а docker не установлен"
        return 1
    fi
    local region
    region=$(echo "${PSIPHON_REGION:-}" | tr -d '[:space:]' | tr 'a-z' 'A-Z')
    # Одна страна или пул через запятую: DE или DE,NL,FR
    if [[ -n "$region" && ! "$region" =~ ^[A-Z]{2}(,[A-Z]{2})*$ ]]; then
        echo "  [ВНИМАНИЕ] PSIPHON_REGION='$region' — не код страны (нужно, например, DE или DE,NL), беру страну сервера."
        region=""
    fi
    if [[ -z "$region" ]]; then
        region=$(node_country)
        # vps-psiphon сам не выходит через RU (и ещё ряд стран): для таких
        # серверов страну не задаём — Psiphon выберет выход сам
        if [[ " RU BY IR SY CU KP CN VE " == *" $region "* ]]; then
            echo "  Сервер в $region — выход в этой стране Psiphon запрещён, регион выберет сам."
            region=""
        fi
    fi
    if psiphon_active && [[ -z "${RH_FORCE:-}" ]]; then
        echo "  Уже установлен и работает — не переустанавливаю."
    else
        local f args=(--no-http --bulk-test-mb 0)
        [[ -n "$region" ]] && args+=(--region "$region")
        f=$(mktemp)
        if ! curl -fsSL --max-time 60 "$PSIPHON_URL" -o "$f" || ! bash -n "$f"; then
            rm -f "$f"; echo "  [СБОЙ] не удалось скачать установщик vps-psiphon"; return 1
        fi
        echo "  Флаги: ${args[*]}"
        ui_step_status "Psiphon: ставлю и жду первый туннель"
        bash "$f" "${args[@]}" </dev/null >>"$SETUP_LOG" 2>&1 || true
        rm -f "$f"
    fi
    # Порог скорости в вотчдоге отключаем: на части нод он ложно браковал выходы
    if [[ -f /etc/default/vps-psiphon ]]; then
        if grep -q '^MIN_THROUGHPUT_KBPS=' /etc/default/vps-psiphon; then
            sed -i 's/^MIN_THROUGHPUT_KBPS=.*/MIN_THROUGHPUT_KBPS=0/' /etc/default/vps-psiphon
        else
            echo 'MIN_THROUGHPUT_KBPS=0' >> /etc/default/vps-psiphon
        fi
    fi
    if ! psiphon_active; then
        echo "  [СБОЙ] служба vps-psiphon не запущена (см. $SETUP_LOG)"
        return 1
    fi
    local addr i
    addr=$(psiphon_socks_addr)
    for i in $(seq 1 12); do
        ui_step_status "Psiphon: проверяю SOCKS $addr:$PSIPHON_PORT ($i/12)"
        if curl -fsS --max-time 15 --socks5-hostname "$addr:$PSIPHON_PORT" \
                https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q '^loc='; then
            echo "  Готово: SOCKS5 $addr:$PSIPHON_PORT отвечает, регион ${region:-auto}."
            return 0
        fi
        sleep 5
    done
    echo "  [СБОЙ] служба работает, но через SOCKS $addr:$PSIPHON_PORT ничего не открывается"
    echo "         состояние: vps-psiphon; журнал: vps-psiphon logs"
    return 1
}

# Из меню — переустановка по требованию, даже если уже работает
comp_warp_native_menu() { local RH_FORCE=1; comp_warp_native; }
comp_psiphon_menu()     { local RH_FORCE=1; comp_psiphon; }

# Готовые outbound'ы Xray для тех выходов, что реально работают на этой ноде —
# чтобы вставить в профиль ноды в панели, не вспоминая адреса и порты.
# Теги — предложение, переименуйте под свои правила маршрутизации.
egress_outbounds_json() {
    local items=() addr
    if ip link show warp >/dev/null 2>&1; then
        items+=('{ "tag": "warp-native", "protocol": "freedom",
    "settings": { "domainStrategy": "ForceIPv4" },
    "streamSettings": { "sockopt": { "interface": "warp", "mark": 51888, "tcpFastOpen": true } } }')
    fi
    if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -qx "127.0.0.1:$WARP_PORT"; then
        items+=('{ "tag": "warp-socks", "protocol": "socks",
    "settings": { "servers": [ { "address": "127.0.0.1", "port": '"$WARP_PORT"' } ] } }')
    fi
    if systemctl is-active --quiet vps-psiphon 2>/dev/null; then
        addr=$(psiphon_socks_addr)
        items+=('{ "tag": "psiphon", "protocol": "socks",
    "settings": { "servers": [ { "address": "'"$addr"'", "port": '"$PSIPHON_PORT"' } ] } }')
    fi
    [[ ${#items[@]} -eq 0 ]] && return 0
    local i
    echo "["
    for i in "${!items[@]}"; do
        printf '  %s' "${items[$i]}"
        [[ $i -lt $(( ${#items[@]} - 1 )) ]] && echo "," || echo
    done
    echo "]"
    return 0
}
