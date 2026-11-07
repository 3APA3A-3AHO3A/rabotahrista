# ##########################################################################
#  ОПРОС
#  Всё, что спрашивается у пользователя, и проверка введённого
# ##########################################################################

ask_domain() {
    DOMAIN=$(echo "${DOMAIN:-}" | tr -d '[:space:]')
    while [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]]; do
        [[ -n "$NONINTERACTIVE" ]] && { echo "  [СБОЙ] DOMAIN в конфиге не задан или некорректен"; return 1; }
        read -ep "Введите основной домен (например, domain.com): " DOMAIN
        DOMAIN=$(echo "$DOMAIN" | tr -d '[:space:]')
        [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] || echo -e "\e[31m[Ошибка]\e[0m Только буквы, цифры, точки и дефисы."
    done
    return 0
}

ask_subdomain() {
    SUBDOMAIN=$(echo "${SUBDOMAIN:-}" | tr -d '[:space:]')
    while [[ ! "$SUBDOMAIN" =~ ^[a-zA-Z0-9-]+$ ]]; do
        [[ -n "$NONINTERACTIVE" ]] && { echo "  [СБОЙ] SUBDOMAIN в конфиге не задан или некорректен"; return 1; }
        read -ep "Введите имя ноды/субдомена (например, node-nl-1): " SUBDOMAIN
        SUBDOMAIN=$(echo "$SUBDOMAIN" | tr -d '[:space:]')
        [[ "$SUBDOMAIN" =~ ^[a-zA-Z0-9-]+$ ]] || echo -e "\e[31m[Ошибка]\e[0m Только буквы, цифры и дефисы (без точек)."
    done
    return 0
}

ask_panel_ip() {
    PANEL_IP=$(echo "${PANEL_IP:-}" | tr -d '[:space:]')
    while [[ ! "$PANEL_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; do
        [[ -n "$NONINTERACTIVE" ]] && { echo "  [СБОЙ] PANEL_IP в конфиге не задан или некорректен"; return 1; }
        read -ep "Введите IP-адрес мастер-панели (для UFW): " PANEL_IP
        PANEL_IP=$(echo "$PANEL_IP" | tr -d '[:space:]')
        [[ "$PANEL_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || echo -e "\e[31m[Ошибка]\e[0m Введите корректный IPv4."
    done
    return 0
}

ask_secret() {
    REMNA_SECRET=$(echo "${REMNA_SECRET:-}" | tr -d '[:space:]')
    while [[ -z "$REMNA_SECRET" ]]; do
        [[ -n "$NONINTERACTIVE" ]] && { echo "  [СБОЙ] REMNA_SECRET в конфиге не задан или некорректен"; return 1; }
        read -ep "Введите SECRET_KEY для Remnanode: " REMNA_SECRET
        REMNA_SECRET=$(echo "$REMNA_SECRET" | tr -d '[:space:]')
    done
    return 0
}

# Проверяет, что строка — действительно публичный SSH-ключ.
# Без этой проверки опечатка или обрезанный при копировании ключ приводит к тому,
# что скрипт отключает вход по паролю и запирает сервер: ключ-то "непустой".
ssh_key_valid() {
    local key="$1"
    [[ -z "$key" ]] && return 1
    command -v ssh-keygen >/dev/null 2>&1 || return 0   # нечем проверить — не мешаем
    local tmp; tmp=$(mktemp)
    printf '%s\n' "$key" > "$tmp"
    if ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"; return 0
    fi
    rm -f "$tmp"; return 1
}

ask_ssh_key() {
    while ! ssh_key_valid "$SSH_PUBLIC_KEY"; do
        if [[ -n "$SSH_PUBLIC_KEY" ]]; then
            echo -e "\e[31m[Ошибка]\e[0m Это не похоже на публичный SSH-ключ."
            echo "  Нужна одна строка целиком, например: ssh-ed25519 AAAAC3Nza... you@host"
            SSH_PUBLIC_KEY=""
        fi
        [[ -n "$NONINTERACTIVE" ]] && { echo "  [СБОЙ] SSH_PUBLIC_KEY в конфиге некорректен"; return 1; }
        read -ep "Публичный SSH-ключ (ssh-ed25519 AAA...): " SSH_PUBLIC_KEY
    done
    return 0
}

# Дополнительные ключи той же учётке: второй компьютер, коллега, Claude.
# Хранятся в SSH_EXTRA_KEYS по одному на строку. Основной ключ остаётся
# обязательным, эти — по желанию; спрашиваем, только если их ещё нет.
ask_extra_keys() {
    [[ -n "$NONINTERACTIVE" || -n "${SSH_EXTRA_KEYS:-}" ]] && return 0
    local k
    while true; do
        read -ep "Ещё один публичный ключ для этой учётки (Enter — не нужно): " k || k=""
        k=$(echo "$k" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [[ -z "$k" ]] && break
        if ssh_key_valid "$k"; then
            SSH_EXTRA_KEYS+="${SSH_EXTRA_KEYS:+$'\n'}$k"
            echo "  Ключ добавлен."
        else
            echo -e "\e[31m[Ошибка]\e[0m Это не похоже на публичный SSH-ключ — пропускаю."
        fi
    done
    return 0
}

# --- Версия ноды ------------------------------------------------------------
# Тег образа remnawave/node: latest или конкретная версия (3.4.3). Конкретная
# нужна, когда свежая версия что-то ломает и ноду откатывают: с latest любая
# переустановка вернула бы сломанную версию обратно.
validate_node_version() {
    REMNANODE_VERSION=$(echo "${REMNANODE_VERSION:-}" | tr -d '[:space:]')
    if [[ -n "$REMNANODE_VERSION" && ! "$REMNANODE_VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        echo "  [ВНИМАНИЕ] REMNANODE_VERSION='$REMNANODE_VERSION' — не похоже на тег образа, ставлю latest."
        REMNANODE_VERSION=""
    fi
    [[ -z "$REMNANODE_VERSION" ]] && REMNANODE_VERSION="latest"
    return 0
}

# Спрашивается при каждой интерактивной установке. Если нода уже стоит на
# закреплённой версии, она предлагается по умолчанию — чтобы Enter не отменил
# откат. На чистом сервере Enter — latest.
ask_node_version() {
    [[ -n "$NONINTERACTIVE" ]] && { validate_node_version; return 0; }
    local v def="${REMNANODE_VERSION:-latest}"
    read -ep "Версия ноды Remnawave, например 3.4.3 (Enter — $def): " v || v=""
    v=$(echo "$v" | tr -d '[:space:]')
    REMNANODE_VERSION="${v:-$def}"
    validate_node_version
    return 0
}

# --- Учётка ИИ-агента -----------------------------------------------------
# Отдельный вход для Claude и других агентов, которые ходят на сервер по MCP.
# Зачем отдельный: в уведомлении о входе видно, кто зашёл — человек или агент,
# а доступ агента можно закрыть, не трогая свою учётку.
validate_agent_params() {
    # Запасное имя не должно совпасть с админ-учёткой, если её саму назвали agent
    local fallback="agent"
    [[ "${ADMIN_USER:-}" == "agent" ]] && fallback="ai-agent"
    AGENT_USER=$(echo "${AGENT_USER:-}" | tr -d '[:space:]')
    [[ -z "$AGENT_USER" ]] && AGENT_USER="$fallback"
    if [[ ! "$AGENT_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || [[ "$AGENT_USER" == "root" ]] \
       || [[ "$AGENT_USER" == "$ADMIN_USER" ]] || (( ${#AGENT_USER} > 32 )); then
        echo "  [ВНИМАНИЕ] Некорректное AGENT_USER='$AGENT_USER' (или совпадает с админ-учёткой) — использую '$fallback'."
        AGENT_USER="$fallback"
    fi
    return 0
}

ask_agent_key() {
    [[ -n "$NONINTERACTIVE" || -n "${AGENT_SSH_KEYS:-}" ]] && return 0
    local k
    echo "  Учётка для ИИ-агентов (Claude и др. по MCP): свой ключ, sudo, в уведомлениях"
    echo "  вход подписан как вход агента. Не нужна — просто Enter."
    while true; do
        read -ep "Публичный ключ агента (Enter — не создавать): " k || k=""
        k=$(echo "$k" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [[ -z "$k" ]] && break
        if ssh_key_valid "$k"; then
            AGENT_SSH_KEYS="$k"
            read -ep "Имя учётки агента [${AGENT_USER:-agent}]: " k || k=""
            k=$(echo "$k" | tr -d '[:space:]')
            [[ -n "$k" ]] && AGENT_USER="$k"
            validate_agent_params
            break
        fi
        echo -e "\e[31m[Ошибка]\e[0m Это не похоже на публичный SSH-ключ."
    done
    return 0
}

# --- Имя админ-учётки и порт SSH -------------------------------------------
# Проверка значений, пришедших из окружения/конфига (неинтерактивный режим).
validate_ssh_params() {
    ADMIN_USER=$(echo "${ADMIN_USER:-}" | tr -d '[:space:]')
    if [[ ! "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || [[ "$ADMIN_USER" == "root" ]] || (( ${#ADMIN_USER} > 32 )); then
        [[ -n "$ADMIN_USER" ]] && echo "  [ВНИМАНИЕ] Некорректное ADMIN_USER='$ADMIN_USER' — использую 'admin'."
        ADMIN_USER="admin"
    fi
    SSH_PORT=$(echo "${SSH_PORT:-}" | tr -d '[:space:]')
    if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
        [[ -n "$SSH_PORT" ]] && echo "  [ВНИМАНИЕ] Некорректный SSH_PORT='$SSH_PORT' — использую 8422."
        SSH_PORT="8422"
    fi
    return 0
}

ask_admin_user() {
    local input yn
    while true; do
        read -ep "Имя администраторской учётки [$ADMIN_USER]: " input
        input=$(echo "$input" | tr -d '[:space:]')
        [[ -z "$input" ]] && break                      # Enter — оставить как есть
        if [[ ! "$input" =~ ^[a-z_][a-z0-9_-]*$ ]] || (( ${#input} > 32 )); then
            echo -e "\e[31m[Ошибка]\e[0m Строчные латинские буквы, цифры, _ и -; первым символом буква или _ (до 32 символов)."
            continue
        fi
        if [[ "$input" == "root" ]]; then
            echo -e "\e[31m[Ошибка]\e[0m root не подходит — скрипт как раз закрывает вход под root."
            continue
        fi
        if id "$input" &>/dev/null; then
            read -ep "  Пользователь '$input' в системе уже есть. Использовать его (добавлю ключ и sudo)? [y/N]: " yn
            [[ "$yn" =~ ^[Yy]$ ]] || continue
        fi
        ADMIN_USER="$input"
        break
    done
    return 0
}

ask_ssh_port() {
    local input
    while true; do
        read -ep "Порт SSH [$SSH_PORT]: " input
        input=$(echo "$input" | tr -d '[:space:]')
        [[ -z "$input" ]] && break                      # Enter — оставить как есть
        if [[ ! "$input" =~ ^[0-9]+$ ]] || (( input < 1 || input > 65535 )); then
            echo -e "\e[31m[Ошибка]\e[0m Порт — целое число от 1 до 65535."
            continue
        fi
        if [[ " 80 443 $NODE_PORT $WARP_PORT " == *" $input "* ]]; then
            echo -e "\e[31m[Ошибка]\e[0m Порт $input уже занят: 80/443 — веб, $NODE_PORT — API ноды, $WARP_PORT — WARP."
            continue
        fi
        if (( input < 1024 )) && [[ "$input" != "22" ]]; then
            echo -e "\e[33m[Внимание]\e[0m $input — системный порт (<1024), его могут занять другие сервисы."
        fi
        if [[ "$input" != "22" ]] && ss -H -ltn 2>/dev/null | awk '{print $4}' | sed 's/.*://' | grep -qx "$input"; then
            echo -e "\e[33m[Внимание]\e[0m Порт $input уже кто-то слушает. Если это не ваш sshd — SSH не поднимется."
        fi
        SSH_PORT="$input"
        break
    done
    return 0
}

ask_admin_password() {
    local p1 p2 yn
    # Если учётка уже есть, решение про пароль принимаем СЕЙЧАС, а не во время
    # установки: иначе скрипт замрёт с вопросом посреди работ.
    if id "$ADMIN_USER" &>/dev/null; then
        echo "  Пользователь $ADMIN_USER уже существует."
        read -ep "  Сменить ему пароль? [y/N]: " yn
        if [[ ! "$yn" =~ ^[Yy]$ ]]; then
            ADMIN_PASS=""; ADMIN_PASS_SOURCE="kept"
            echo "  Пароль останется прежним."
            return 0
        fi
    fi
    while true; do
        read -s -p "Пароль для учётки $ADMIN_USER (Enter — сгенерировать случайный): " p1; echo
        if [[ -z "$p1" ]]; then
            ADMIN_PASS=""; ADMIN_PASS_SOURCE="generated"
            echo "  Пароль будет сгенерирован и показан в итоговом отчёте."
            return 0
        fi
        if (( ${#p1} < 8 )); then
            echo -e "\e[31m[Ошибка]\e[0m Минимум 8 символов."
            continue
        fi
        read -s -p "Повторите пароль: " p2; echo
        if [[ "$p1" != "$p2" ]]; then
            echo -e "\e[31m[Ошибка]\e[0m Пароли не совпали, ещё раз."
            continue
        fi
        ADMIN_PASS="$p1"; ADMIN_PASS_SOURCE="manual"
        break
    done
}

# Спрашивает параметры один раз за запуск; в неинтерактиве только проверяет.
ask_ssh_params() {
    [[ -n "$SSH_PARAMS_ASKED" ]] && return 0
    if [[ -z "$NONINTERACTIVE" ]]; then
        validate_ssh_params
        echo "Enter — оставить значение, указанное в квадратных скобках."
        ask_admin_user
        ask_admin_password
        ask_ssh_port
    else
        [[ -n "$ADMIN_PASS" ]] && ADMIN_PASS_SOURCE="manual" || ADMIN_PASS_SOURCE="generated"
    fi
    validate_ssh_params
    SSH_PARAMS_ASKED=1
}

ask_cf() {
    [[ -z "$SETUP_CF" && -z "$NONINTERACTIVE" ]] && read -ep "Настроить DNS в Cloudflare автоматически? [y/N]: " SETUP_CF
    if [[ "$SETUP_CF" =~ ^[Yy]$ ]]; then
        if [[ -n "$NONINTERACTIVE" ]]; then
            # Спрашивать некому: без токена DNS не настроить — так и говорим
            [[ -z "$CF_API_TOKEN" ]] && { echo "  [СБОЙ] SETUP_CF=y, а CF_API_TOKEN в конфиге пуст"; return 1; }
            [[ "$CF_PROXY_CHOICE" =~ ^[Yy]$ ]] && CF_PROXIED="true" || CF_PROXIED="false"
            return 0
        fi
        while [[ -z "$CF_API_TOKEN" ]]; do
            read -ep "API Token Cloudflare (Edit DNS): " CF_API_TOKEN
            CF_API_TOKEN=$(echo "$CF_API_TOKEN" | tr -d '[:space:]')
        done
        [[ -z "$CF_PROXY_CHOICE" ]] && read -ep "Включить Proxy (Оранжевое облако)? [y/N]: " CF_PROXY_CHOICE
        [[ "$CF_PROXY_CHOICE" =~ ^[Yy]$ ]] && CF_PROXIED="true" || CF_PROXIED="false"
    fi
    return 0
}

# ВАЖНО: заканчивается явным "return 0".
# Без него последняя строка ([[ -z ... ]] без совпадения) вернула бы 1,
# и вызов "[[ ... ]] && ask_telegram" убивал бы весь скрипт из-за set -e.
ask_telegram() {
    [[ -n "$TG_ASKED" || -n "$NONINTERACTIVE" ]] && return 0
    [[ -z "$TG_BOT_TOKEN" ]] && read -ep "Telegram BOT_TOKEN: " TG_BOT_TOKEN
    [[ -z "$TG_CHAT_ID" ]]   && read -ep "Telegram CHAT_ID (супергруппа: начинается с -100): " TG_CHAT_ID
    [[ -z "$TG_TOPIC_ID" ]]  && read -ep "Topic ID темы супергруппы (Enter — если без топиков): " TG_TOPIC_ID
    # Прокси нужен, если сервер не достаёт api.telegram.org напрямую.
    # Спрашиваем здесь, а не в момент установки: все вопросы должны быть заданы заранее.
    if [[ -z "$TG_PROXY" ]]; then
        echo "  Если сервер не достаёт api.telegram.org напрямую, укажите прокси."
        echo "  Формат: socks5h://user:pass@host:port или http://host:port. Enter — без прокси."
        read -ep "Прокси для Telegram: " TG_PROXY
    fi
    [[ -z "$USER_NODE_LABEL" ]] && read -ep "Как называть эту ноду в уведомлениях (например NL-1): " USER_NODE_LABEL
    if [[ -z "$PANEL_WATCH" ]]; then
        echo "  Дежурная нода следит, не пропала ли связь с панелью, и пишет в Telegram."
        echo "  Включайте ТОЛЬКО на одной ноде: иначе при падении панели напишут все сразу."
        read -ep "Сделать эту ноду дежурной по панели? [y/N]: " PANEL_WATCH
    fi
    [[ "$PANEL_WATCH" =~ ^[Yy]$ ]] && ask_panel_watch_params
    TG_ASKED=1
    return 0
}

# Параметры сторожа панели. Отдельной функцией, потому что спрашиваются они
# и при полной установке (заранее, вместе с остальными вопросами), и при
# включении сторожа из меню. Задаются один раз за запуск.
ask_panel_watch_params() {
    [[ -n "$PANEL_PARAMS_ASKED" || -n "$NONINTERACTIVE" ]] && return 0
    if [[ -z "$PANEL_PROBE_PORT" ]]; then
        echo "  Дополнительно нода может сама стучаться в порт панели."
        echo "  Это ловит жёсткое падение сервера панели, при котором соединения зависают"
        echo "  и по ним кажется, что всё в порядке."
        read -ep "  Порт веб-панели для проверки [443; 0 — не проверять]: " PANEL_PROBE_PORT
        PANEL_PROBE_PORT=$(echo "${PANEL_PROBE_PORT:-443}" | tr -d '[:space:]')
        [[ "$PANEL_PROBE_PORT" =~ ^[0-9]+$ ]] || PANEL_PROBE_PORT="443"
        [[ "$PANEL_PROBE_PORT" == "0" ]] && PANEL_PROBE_PORT=""
    fi
    PANEL_PARAMS_ASKED=1
    return 0
}
