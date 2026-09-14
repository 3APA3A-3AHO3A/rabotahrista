# ##########################################################################
#  СОСТОЯНИЕ
#  Сохранение ответов между запусками, IP сервера, отправка в Telegram
# ##########################################################################

get_server_ip() {
    SERVER_IP=$(curl -fs --max-time 10 https://api.ipify.org 2>/dev/null || true)
    [[ -z "$SERVER_IP" ]] && SERVER_IP=$(curl -fs --max-time 10 https://ifconfig.me 2>/dev/null || true)
    [[ -z "$SERVER_IP" ]] && SERVER_IP=$(wget -qO- --timeout=10 https://api.ipify.org 2>/dev/null || true)
    SERVER_IP=$(echo "$SERVER_IP" | tr -d '[:space:]')
    if [[ ! "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "  [ВНИМАНИЕ] Не удалось определить внешний IP сервера."
        SERVER_IP=""
        return 1
    fi
    return 0
}

# Сохранение введённых данных для будущих обновлений (chmod 600 — внутри секреты/токены)
save_state() {
    mkdir -p "$(dirname "$INSTALL_STATE")"
    # Значения экранируются через %q: файл потом читается через "source" от root,
    # и секрет вида a$(команда) иначе выполнился бы, а пароль с $ — молча испортился.
    {
        for _v in DOMAIN SUBDOMAIN PANEL_IP REMNA_SECRET SETUP_CF CF_API_TOKEN \
                  CF_PROXY_CHOICE SETUP_SSH SSH_PUBLIC_KEY SSH_PORT ADMIN_USER \
                  USER_NODE_LABEL INSTALL_WARP INSTALL_SPEEDTEST SETUP_TG \
                  TG_BOT_TOKEN TG_CHAT_ID TG_TOPIC_ID TG_PROXY PANEL_WATCH \
                  PANEL_PROBE_PORT PANEL_FAIL_CHECKS; do
            printf '%s=%q\n' "$_v" "${!_v-}"
        done
        unset _v
    } > "$INSTALL_STATE"
    chmod 600 "$INSTALL_STATE"
}

notify_telegram() {
    [[ -f "$NOTIFY_ENV" ]] && source "$NOTIFY_ENV"
    [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]] && return 0
    local args=(-s --max-time 15)
    [[ -n "${TG_PROXY:-}" ]] && args+=(-x "$TG_PROXY")
    args+=(-d "chat_id=${TG_CHAT_ID}" -d "parse_mode=HTML" --data-urlencode "text=$1")
    [[ -n "${TG_TOPIC_ID:-}" ]] && args+=(-d "message_thread_id=${TG_TOPIC_ID}")
    curl "${args[@]}" -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" >/dev/null 2>&1 || true
}
