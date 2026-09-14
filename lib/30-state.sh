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

# Восстановление ответов с уже настроенной ноды.
#
# Ноды, поставленные до появления install.conf, при запуске меню спрашивают
# всё заново — и человек по памяти вводит домен, IP панели и секрет. Одна
# опечатка на рабочем сервере обходится дорого. Поэтому вычитываем то, что
# уже настроено, прямо с сервера и подставляем как значения по умолчанию.
#
# Только чтение: ничего не меняет, все значения потом показываются в вопросах.
detect_existing_setup() {
    local v

    # Домен — из выпущенного сертификата, иначе из включённого конфига nginx
    if [[ -z "${DOMAIN:-}${SUBDOMAIN:-}" ]]; then
        v=$(ls -d /etc/letsencrypt/live/*/ 2>/dev/null | head -1)
        [[ -n "$v" ]] && v=$(basename "$v")
        if [[ -z "$v" ]]; then
            v=$(find /etc/nginx/sites-enabled -maxdepth 1 \( -type l -o -type f \) \
                -printf '%f\n' 2>/dev/null | grep -v '^default$' | head -1)
        fi
        if [[ "$v" == *.*.* ]]; then
            SUBDOMAIN="${v%%.*}"
            DOMAIN="${v#*.}"
        fi
    fi

    # IP панели — из правила ufw, открывающего порт ноды
    if [[ -z "${PANEL_IP:-}" ]]; then
        PANEL_IP=$(ufw status 2>/dev/null | grep -w "$NODE_PORT" \
                   | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -1)
    fi

    # Секрет ноды — из compose (кавычки вокруг значения снимаем)
    if [[ -z "${REMNA_SECRET:-}" && -f /opt/remnanode/docker-compose.yml ]]; then
        REMNA_SECRET=$(grep -m1 'SECRET_KEY=' /opt/remnanode/docker-compose.yml 2>/dev/null \
                       | sed 's/.*SECRET_KEY=//' | tr -d '"'"'"'" \r\n')
    fi

    # Порт SSH и админ-учётка — из живой конфигурации
    if [[ -z "${SSH_PORT_DETECTED:-}" ]]; then
        v=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
        [[ "$v" =~ ^[0-9]+$ ]] && SSH_PORT="$v"
        SSH_PORT_DETECTED=1
    fi
    if [[ -z "${ADMIN_USER_DETECTED:-}" ]]; then
        v=$(find /etc/sudoers.d -maxdepth 1 -name '90-*' -printf '%f\n' 2>/dev/null | head -1)
        v="${v#90-}"
        [[ -n "$v" ]] && id "$v" &>/dev/null && ADMIN_USER="$v"
        ADMIN_USER_DETECTED=1
    fi

    # Telegram — из файла уведомлений
    if [[ -f "$NOTIFY_ENV" ]]; then
        local key
        for key in TG_BOT_TOKEN TG_CHAT_ID TG_TOPIC_ID TG_PROXY; do
            [[ -n "${!key:-}" ]] && continue
            v=$(grep -m1 "^${key}=" "$NOTIFY_ENV" 2>/dev/null | cut -d= -f2- | sed 's/^"//; s/"$//')
            [[ -n "$v" ]] && printf -v "$key" '%s' "$v"
        done
        if [[ -z "${USER_NODE_LABEL:-}" ]]; then
            USER_NODE_LABEL=$(grep -m1 '^NODE_LABEL=' "$NOTIFY_ENV" 2>/dev/null | cut -d= -f2- | sed 's/^"//; s/"$//')
        fi
        [[ -n "$TG_BOT_TOKEN" && -z "${SETUP_TG:-}" ]] && SETUP_TG="y"
    fi

    # Дежурная ли эта нода и с какими параметрами
    if [[ -f "$PANEL_ENV" ]]; then
        [[ -z "${PANEL_WATCH:-}" ]] && PANEL_WATCH="y"
        local key
        for key in PANEL_PROBE_PORT PANEL_FAIL_CHECKS; do
            [[ -n "${!key:-}" ]] && continue
            v=$(grep -m1 "^${key}=" "$PANEL_ENV" 2>/dev/null | cut -d= -f2- | sed 's/^"//; s/"$//')
            [[ -n "$v" ]] && printf -v "$key" '%s' "$v"
        done
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

# Любое сообщение уходит с шапкой: имя ноды и её IP. Без этого при обходе
# нескольких нод непонятно, к какой из них относится пришедшее уведомление.
tg_header() {
    local h="🖥 <b>${NODE_LABEL:-$(hostname)}</b>"
    [[ -n "${NODE_IP:-}" ]] && h="$h  <code>${NODE_IP}</code>"
    printf '%s' "$h"
}

notify_telegram() {
    [[ -f "$NOTIFY_ENV" ]] && source "$NOTIFY_ENV"
    [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]] && return 0
    local args=(-s --max-time 15)
    [[ -n "${TG_PROXY:-}" ]] && args+=(-x "$TG_PROXY")
    args+=(-d "chat_id=${TG_CHAT_ID}" -d "parse_mode=HTML" --data-urlencode "text=$(tg_header)
$1")
    [[ -n "${TG_TOPIC_ID:-}" ]] && args+=(-d "message_thread_id=${TG_TOPIC_ID}")
    curl "${args[@]}" -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" >/dev/null 2>&1 || true
}
