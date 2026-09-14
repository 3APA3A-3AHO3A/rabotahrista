#!/bin/bash
# ЭТОТ ФАЙЛ СОБРАН АВТОМАТИЧЕСКИ ИЗ lib/*.sh — НЕ РЕДАКТИРУЙТЕ ЕГО ВРУЧНУЮ.
# Правки вносятся в lib/, затем: python3 build.py
# Любое изменение здесь будет затёрто при следующей сборке.
# Собрано из: 00-header.sh, 10-helpers.sh, 20-prompts.sh, 30-state.sh, 40-system.sh, 50-security.sh, 60-node.sh, 70-web.sh, 75-domain.sh, 80-notify.sh, 82-panel.sh, 85-extras.sh, 90-install.sh, 95-menu.sh, 99-main.sh

# ===== lib/00-header.sh ================================================
# ##########################################################################
#  ЗАГОЛОВОК
#  Режимы оболочки, обработчик ошибок и все настройки по умолчанию
# ##########################################################################

# -e  — падать на первой же ошибке, а не идти дальше по сломанному серверу
# -E  — БЕЗ него ERR-трап не наследуется функциями, и падение внутри любой
#       функции обрывает скрипт молча, без единой строки объяснения.
#       Именно поэтому обрыв на Telegram-шаге выглядел как «просто вышел».
set -eE

# Подробный разбор падения: без имени команды такие ошибки ищутся вслепую.
# Классический пример — функция, которая заканчивается проверкой [[ ... ]]:
# при несовпадении она возвращает 1, и set -e молча убивает весь скрипт.
rh_on_error() {
    local code="$1" line="$2"; shift 2
    local cmd="$*"
    {
        echo
        echo "=========================================="
        echo "  ОШИБКА — установка прервана"
        echo "=========================================="
        echo "  команда:      $cmd"
        [[ -n "${FUNCNAME[1]:-}" ]] && echo "  в функции:    ${FUNCNAME[1]}()"
        echo "  строка:       $line"
        echo "  код возврата: $code"
        echo "  полный лог:   ${SETUP_LOG:-(лог ещё не создан)}"
        echo "=========================================="
    } >&2
    exit 1
}
trap 'rh_on_error $? $LINENO "$BASH_COMMAND"' ERR

# === НАСТРОЙКИ ===
INDEX_URL="https://raw.githubusercontent.com/3APA3A-3AHO3A/rabotahrista/main/index.html"
NOTIFY_ENV="/etc/rabotahrista/notify.env"
INSTALL_STATE="/etc/rabotahrista/install.conf"
PANEL_ENV="/etc/rabotahrista/panel.env"
# Пути к генерируемым скриптам — переменными, чтобы тесты могли подставить
# временный каталог и проверить логику, ничего не устанавливая в систему
NOTIFY_BIN="/usr/local/bin/rh-notify.sh"
PANEL_WATCH_BIN="/usr/local/bin/rh-panel-watch.sh"
SETUP_LOG="/var/log/node-setup.log"
REPORT_FILE="/root/node-install-report.txt"
SSH_PORT="${SSH_PORT:-8422}"
ADMIN_USER="${ADMIN_USER:-admin}"
NODE_PORT="2222"        # порт, на который к ноде ходит панель
WARP_PORT="6000"        # локальный прокси-порт Cloudflare WARP
# Пакеты из apt — один список на установку и на отчёт о версиях
APT_PACKAGES="sudo curl wget unzip git ufw fail2ban python3-systemd socat jq certbot python3-certbot-nginx nginx dnsutils chrony iproute2 iperf3 btop ncdu"
# =================

# RH_LIB_ONLY=1 — загрузить только функции, ничего не выполняя (используется тестами)
if [[ -z "${RH_LIB_ONLY:-}" && "$EUID" -ne 0 ]]; then
    echo "Пожалуйста, запустите скрипт с правами root (sudo bash ...)"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
# Без UTF-8 локали bash считает длину строк в байтах — колонки отчёта разъезжаются
if locale -a 2>/dev/null | grep -qix 'C\.UTF-*8'; then export LC_ALL=C.UTF-8; fi

if [[ -z "${RH_LIB_ONLY:-}" ]]; then
    : > "$SETUP_LOG" 2>/dev/null || SETUP_LOG="/tmp/node-setup.log"
    # В лог попадает итоговый отчёт вместе с паролем учётки — 0644 тут не годится
    chmod 600 "$SETUP_LOG" 2>/dev/null || true
fi

SUMMARY=()

# ===== lib/10-helpers.sh ===============================================
# ##########################################################################
#  ХЕЛПЕРЫ
#  Сводка шагов и печать итогового отчёта
# ##########################################################################

# do_step "Метка" функция...  — запускает шаг, пишет результат в сводку (не роняет процесс)
do_step() {
    local label="$1"; shift
    if "$@"; then
        SUMMARY+=("[ OK ]    $label")
    else
        SUMMARY+=("[СБОЙ]    $label  (см. $SETUP_LOG)")
        echo "  [СБОЙ] $label — подробности в $SETUP_LOG"
    fi
    return 0
}

skip_step() { SUMMARY+=("[проп.]   $1"); }

# Строка отчёта ровной колонкой ("метка" дополняется пробелами до 21 символа)
row() {
    local label="$1"; shift
    local n=$(( 21 - ${#label} )); (( n < 1 )) && n=1
    local pad; printf -v pad '%*s' "$n" ''
    printf '  %s%s%s\n' "$label" "$pad" "$*"
}

# Версии всего, что поставили: пакеты apt + то, что ставится мимо apt
collect_versions() {
    local p v
    for p in $APT_PACKAGES; do
        v=$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null || true)
        row "$p" "${v:-НЕ УСТАНОВЛЕН}"
    done
    if command -v docker >/dev/null 2>&1; then
        row "docker" "$(docker --version 2>/dev/null | sed 's/^Docker version //' || echo '?')"
        row "docker compose" "$(docker compose version --short 2>/dev/null || echo '?')"
    else
        row "docker" "НЕ УСТАНОВЛЕН"
    fi
    if command -v speedtest >/dev/null 2>&1; then
        row "speedtest" "$(speedtest --version 2>/dev/null | head -1 || echo '?')"
    fi
    if command -v warp-cli >/dev/null 2>&1; then
        row "warp-cli" "$(warp-cli --version 2>/dev/null | head -1 || echo '?')"
    fi
    return 0
}

# Финальный отчёт: чистит экран и печатает всё одним куском + кладёт в файл
print_summary() {
    local out node_state
    node_state=$(docker inspect -f '{{.State.Status}} (restarts={{.RestartCount}})' remnanode 2>/dev/null || echo "контейнер не найден")
    out=$(
        echo "=========================================="
        echo "  УСТАНОВКА ЗАВЕРШЕНА — $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "=========================================="
        echo
        echo "--- ДОСТУП ПО SSH ---"
        row "Команда входа:" "ssh -p $SSH_PORT $ADMIN_USER@${FULL_DOMAIN:-${SERVER_IP:-$(hostname)}}"
        row "Учётка:" "$ADMIN_USER (sudo без пароля)"
        case "$ADMIN_PASS_SOURCE" in
            manual)    row "Пароль учётки:" "задан вами вручную (в отчёт не пишу)" ;;
            kept)      row "Пароль учётки:" "не менялся — пользователь уже существовал" ;;
            *)         row "Пароль учётки:" "${ADMIN_PASS:-—}"
                       row "" "(сгенерирован; нужен только для аварийной консоли хостера)" ;;
        esac
        row "Root по SSH:" "запрещён"
        row "Вход по паролю:" "запрещён"
        if [[ -n "$SSH_PENDING_REBOOT" ]]; then
            row "ВНИМАНИЕ:" "порт $SSH_PORT заработает ТОЛЬКО ПОСЛЕ ПЕРЕЗАГРУЗКИ"
            row "" "до неё заходи по старому порту — он открыт в UFW (см. ниже)"
        elif [[ -z "$SSH_HARDENED" ]]; then
            row "ВНИМАНИЕ:" "харденинг SSH не применился — смотри шаги ниже"
        fi
        echo
        echo "--- НОДА ---"
        row "Домен:" "${FULL_DOMAIN:-—}"
        row "IP сервера:" "${SERVER_IP:-—}"
        row "Контейнер:" "$node_state"
        row "Порт для панели:" "$NODE_PORT (открыт только для ${PANEL_IP:-—})"
        echo
        echo "--- ФАЕРВОЛ (UFW) ---"
        row "Открыто:" "${UFW_SSH_PORTS:-$SSH_PORT/tcp} (SSH, rate limit), 80/tcp, 443/tcp"
        row "" "$NODE_PORT/tcp только с ${PANEL_IP:-—}"
        echo
        echo "--- ШАГИ УСТАНОВКИ ---"
        printf '%s\n' "${SUMMARY[@]}"
        echo
        echo "--- УСТАНОВЛЕННЫЕ ПАКЕТЫ И ВЕРСИИ ---"
        collect_versions
        echo
        echo "--- ГДЕ ЧТО ЛЕЖИТ ---"
        row "Этот отчёт:" "$REPORT_FILE"
        row "Полный лог:" "$SETUP_LOG"
        row "Ответы установки:" "$INSTALL_STATE"
        row "Compose ноды:" "/opt/remnanode/docker-compose.yml"
        row "Конфиг nginx:" "/etc/nginx/sites-available/${FULL_DOMAIN:-—}"
        [[ -f "$NOTIFY_ENV" ]] && row "Telegram:" "$NOTIFY_ENV"
        echo "=========================================="
    )
    printf '%s\n' "$out" > "$REPORT_FILE" 2>/dev/null || true
    chmod 600 "$REPORT_FILE" 2>/dev/null || true
    # чистим экран от простыни установки — всё важное уже в $out и в файле
    if [[ -t 1 ]]; then clear || true; fi
    printf '%s\n' "$out"
    { echo; echo "=== ОТЧЁТ ($(date)) ==="; printf '%s\n' "$out"; } >> "$SETUP_LOG" 2>&1 || true
    return 0
}

# ===== lib/20-prompts.sh ===============================================
# ##########################################################################
#  ОПРОС
#  Всё, что спрашивается у пользователя, и проверка введённого
# ##########################################################################

ask_domain() {
    DOMAIN=$(echo "${DOMAIN:-}" | tr -d '[:space:]')
    while [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]]; do
        read -ep "Введите основной домен (например, domain.com): " DOMAIN
        DOMAIN=$(echo "$DOMAIN" | tr -d '[:space:]')
        [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] || echo -e "\e[31m[Ошибка]\e[0m Только буквы, цифры, точки и дефисы."
    done
    return 0
}

ask_subdomain() {
    SUBDOMAIN=$(echo "${SUBDOMAIN:-}" | tr -d '[:space:]')
    while [[ ! "$SUBDOMAIN" =~ ^[a-zA-Z0-9-]+$ ]]; do
        read -ep "Введите имя ноды/субдомена (например, node-nl-1): " SUBDOMAIN
        SUBDOMAIN=$(echo "$SUBDOMAIN" | tr -d '[:space:]')
        [[ "$SUBDOMAIN" =~ ^[a-zA-Z0-9-]+$ ]] || echo -e "\e[31m[Ошибка]\e[0m Только буквы, цифры и дефисы (без точек)."
    done
    return 0
}

ask_panel_ip() {
    PANEL_IP=$(echo "${PANEL_IP:-}" | tr -d '[:space:]')
    while [[ ! "$PANEL_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; do
        read -ep "Введите IP-адрес мастер-панели (для UFW): " PANEL_IP
        PANEL_IP=$(echo "$PANEL_IP" | tr -d '[:space:]')
        [[ "$PANEL_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || echo -e "\e[31m[Ошибка]\e[0m Введите корректный IPv4."
    done
    return 0
}

ask_secret() {
    REMNA_SECRET=$(echo "${REMNA_SECRET:-}" | tr -d '[:space:]')
    while [[ -z "$REMNA_SECRET" ]]; do
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
    local p1 p2
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
    TG_ASKED=1
    return 0
}

# ===== lib/30-state.sh =================================================
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

# ===== lib/40-system.sh ================================================
# ##########################################################################
#  СИСТЕМА
#  Базовая подготовка: swap, пакеты, ядро, диск, автообновления
# ##########################################################################

comp_swap() {
    if [ -n "$(swapon --show)" ]; then
        echo ">>> Swap уже есть, пропускаем."
        return 0
    fi
    echo ">>> Создание Swap 2GB..."
    # Раньше команды шли через ';' и запись в fstab добавлялась даже при провале —
    # получался мёртвый swapfile.swap на каждой загрузке и зелёный шаг в сводке.
    if ! fallocate -l 2G /swapfile >>"$SETUP_LOG" 2>&1; then
        rm -f /swapfile
        if ! dd if=/dev/zero of=/swapfile bs=1M count=2048 >>"$SETUP_LOG" 2>&1; then
            echo "  [СБОЙ] не удалось создать /swapfile (нет места или ФС не поддерживает)"
            rm -f /swapfile; return 1
        fi
    fi
    chmod 600 /swapfile
    if ! mkswap /swapfile >>"$SETUP_LOG" 2>&1 || ! swapon /swapfile >>"$SETUP_LOG" 2>&1; then
        echo "  [СБОЙ] mkswap/swapon не отработали (см. $SETUP_LOG)"
        rm -f /swapfile; return 1
    fi
    # В fstab пишем только после того, как swap реально включился
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    return 0
}

comp_packages() {
    echo ">>> Обновление системы и установка пакетов (в фоне, лог: $SETUP_LOG)..."
    local rc=0
    {
        apt-get clean
        apt-get update
        apt-get -y upgrade
        apt-get -y dist-upgrade
        apt-get -y autoremove --purge
        apt-get -y install $APT_PACKAGES
    } >>"$SETUP_LOG" 2>&1 || rc=$?
    systemctl enable --now chrony >/dev/null 2>&1 || systemctl enable --now chronyd >/dev/null 2>&1 || true
    if [[ $rc -ne 0 ]]; then
        echo "  [СБОЙ] apt завершился с ошибкой (см. $SETUP_LOG)."
        echo "         Без пакетов следующие шаги тоже посыплются — разберитесь с apt и повторите."
        return 1
    fi
    # Проверяем не «apt отработал», а что ключевое реально на месте
    local miss=""
    for pkg in nginx certbot ufw fail2ban jq; do
        command -v "$pkg" >/dev/null 2>&1 || miss+=" $pkg"
    done
    if [[ -n "$miss" ]]; then
        echo "  [СБОЙ] после установки не найдены:$miss"
        return 1
    fi
    return 0
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
EOF
    # Ключи ipv6 существуют, только пока стек ipv6 в ядре жив. После ipv6.disable=1
    # из GRUB их нет, и sysctl --system падает с ошибкой на пустом месте.
    if [[ -d /proc/sys/net/ipv6 ]]; then
        cat <<EOF >> /etc/sysctl.d/99-vpn-tune.conf

# Отключаем ipv6
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF
    else
        echo -e "\n# ipv6 уже отключён в ядре (ipv6.disable=1 в GRUB) — ключи sysctl не нужны" \
            >> /etc/sysctl.d/99-vpn-tune.conf
    fi
    sysctl --system >>"$SETUP_LOG" 2>&1
}

comp_ipv6() {
    echo ">>> Отключение IPv6 в GRUB..."
    if ! grep -q "ipv6.disable=1" /etc/default/grub; then
        sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="ipv6.disable=1 /' /etc/default/grub
        update-grub >>"$SETUP_LOG" 2>&1
    fi
}

comp_disk() {
    echo ">>> Защита диска: ротация логов Docker + journald..."
    mkdir -p /etc/docker
    if [[ -f /etc/docker/daemon.json ]]; then
        # Чужой daemon.json не перезаписываем: там могут быть data-root, dns,
        # registry-mirrors. Только аккуратно домешиваем настройки логов через jq.
        if ! command -v jq >/dev/null 2>&1; then
            echo "  [СБОЙ] /etc/docker/daemon.json уже есть, а jq нет — не рискую его перезаписывать"
            return 1
        fi
        tmp=$(mktemp)
        if jq '. + {"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' /etc/docker/daemon.json > "$tmp" 2>/dev/null; then
            mv "$tmp" /etc/docker/daemon.json
        else
            rm -f "$tmp"
            echo "  [СБОЙ] /etc/docker/daemon.json не разбирается как JSON — не трогаю его"
            return 1
        fi
    else
        cat <<'EOF' > /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
    fi
    systemctl restart docker >>"$SETUP_LOG" 2>&1 || true
    mkdir -p /etc/systemd/journald.conf.d
    cat <<'EOF' > /etc/systemd/journald.conf.d/size.conf
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
EOF
    systemctl restart systemd-journald >>"$SETUP_LOG" 2>&1 || true
}

comp_autoupdates() {
    echo ">>> Автообновления безопасности..."
    apt-get install -y unattended-upgrades >>"$SETUP_LOG" 2>&1 || true
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
    if ! command -v unattended-upgrade >/dev/null 2>&1; then
        echo "  [СБОЙ] unattended-upgrades не установлен — автообновлений безопасности не будет"
        return 1
    fi
    return 0
}

comp_os_update() {
    echo ">>> Полное обновление системы (apt). Вывод — на экран."
    if apt-get clean && apt-get update && apt-get -y upgrade && apt-get -y dist-upgrade && apt-get -y autoremove --purge; then
        echo "  Обновление завершено успешно."
        notify_telegram "🧰 ОС обновлена, ухожу в перезагрузку ($(date '+%H:%M:%S'))"
        echo "  Перезагрузка через 5 секунд (Ctrl+C — отменить)..."
        sleep 5
        reboot
    else
        echo "  [СБОЙ] apt-обновление завершилось с ошибкой — перезагрузка отменена."
        return 1
    fi
}

# ===== lib/50-security.sh ==============================================
# ##########################################################################
#  БЕЗОПАСНОСТЬ
#  Пользователь, харденинг SSH, фаервол, fail2ban
# ##########################################################################

# ##########################################################################
#  КОМПОНЕНТЫ  (тяжёлый вывод уходит в $SETUP_LOG, на экране — только шаги)
# ##########################################################################
comp_user() {
    if [[ -z "$SSH_PUBLIC_KEY" && -n "$NONINTERACTIVE" ]]; then
        echo "  [СБОЙ] SSH_PUBLIC_KEY не задан в конфиге"; return 1
    fi
    ask_ssh_params
    ask_ssh_key
    echo ">>> Пользователь $ADMIN_USER..."
    if ! id "$ADMIN_USER" &>/dev/null; then
        adduser --disabled-password --gecos "" "$ADMIN_USER"
        if [[ -z "$ADMIN_PASS" ]]; then
            ADMIN_PASS=$(openssl rand -base64 18); ADMIN_PASS_SOURCE="generated"
        fi
        echo "$ADMIN_USER:$ADMIN_PASS" | chpasswd
        [[ "$ADMIN_PASS_SOURCE" == "generated" ]] && \
            echo "!!! ПАРОЛЬ $ADMIN_USER@$(hostname): $ADMIN_PASS  (повторю в итоговом отчёте)"
    else
        # Существующей учётке пароль молча не меняем — только если явно попросили
        if [[ "$ADMIN_PASS_SOURCE" == "manual" && -n "$ADMIN_PASS" ]]; then
            local yn="y"
            [[ -z "$NONINTERACTIVE" ]] && read -ep "  Пользователь $ADMIN_USER уже есть. Сменить ему пароль на введённый? [y/N]: " yn
            if [[ "$yn" =~ ^[Yy]$ ]]; then
                echo "$ADMIN_USER:$ADMIN_PASS" | chpasswd
                echo "  Пароль изменён."
            else
                ADMIN_PASS=""; ADMIN_PASS_SOURCE="kept"
                echo "  Пароль оставлен прежним."
            fi
        else
            ADMIN_PASS=""; ADMIN_PASS_SOURCE="kept"
            echo "  Пользователь $ADMIN_USER уже существует — пароль не трогаю."
        fi
    fi
    usermod -aG sudo "$ADMIN_USER"

    echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$ADMIN_USER"
    chmod 440 "/etc/sudoers.d/90-$ADMIN_USER"
    if ! visudo -c >/dev/null 2>>"$SETUP_LOG"; then
        # Битый sudoers.d ломает sudo целиком, а следом comp_ssh закроет вход под root
        echo "  [СБОЙ] sudoers не проходит проверку — убираю свой файл"
        rm -f "/etc/sudoers.d/90-$ADMIN_USER"
        return 1
    fi

    local H; H=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
    install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$H/.ssh"
    touch "$H/.ssh/authorized_keys"
    grep -qxF "$SSH_PUBLIC_KEY" "$H/.ssh/authorized_keys" || echo "$SSH_PUBLIC_KEY" >> "$H/.ssh/authorized_keys"
    chmod 600 "$H/.ssh/authorized_keys"
    chown -R "$ADMIN_USER:$ADMIN_USER" "$H/.ssh"

    [[ -s "$H/.ssh/authorized_keys" ]] || { echo "  [СБОЙ] authorized_keys пуст"; return 1; }
    echo "Пользователь готов."
}

# Порты, на которых СЕЙЧАС слушает именно sshd (а не кто попало).
# ss -ltnp показывает процесс; при socket-активации слушателем выступает systemd,
# поэтому его тоже засчитываем — иначе решим, что SSH мёртв, и зря откатимся.
current_sshd_ports() {
    ss -H -ltnp 2>/dev/null \
        | grep -E 'users:\(\("(sshd|systemd)"' \
        | awk '{print $4}' | sed 's/.*://' | sort -un
    return 0
}

sshd_listens_on() {
    grep -qx "$1" <<< "$(current_sshd_ports)"
}

ssh_daemon_active() {
    systemctl is-active --quiet ssh 2>/dev/null && return 0
    systemctl is-active --quiet sshd 2>/dev/null && return 0
    systemctl is-active --quiet ssh.socket 2>/dev/null && return 0
    return 1
}

comp_ssh() {
    ask_ssh_params
    echo ">>> Харденинг SSH: порт $SSH_PORT, root закрыт..."
    local H; H=$(getent passwd "$ADMIN_USER" 2>/dev/null | cut -d: -f6)
    if [[ -z "$H" || ! -s "$H/.ssh/authorized_keys" ]]; then
        echo "  [СБОЙ] У $ADMIN_USER нет SSH-ключа — харденинг отменён, иначе потеряете доступ."
        return 1
    fi
    # Без этой строки основной sshd_config вообще не читает каталог sshd_config.d:
    # наш файл лёг бы «в стол», sshd -t прошёл бы, а порт и root остались бы прежними.
    if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
        echo "  В sshd_config нет Include для sshd_config.d — добавляю первой строкой (бэкап рядом)."
        cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
        sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
    fi

    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/01-hardening.conf <<EOF
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM yes
EOF
    chmod 644 /etc/ssh/sshd_config.d/01-hardening.conf
    # Облачные образы включают вход по паролю своими дроп-инами. Наш файл сортируется
    # первым и всё равно выигрывает, но глушим и их — на случай нестандартных имён.
    sed -i 's/^PasswordAuthentication/#PasswordAuthentication/' \
        /etc/ssh/sshd_config.d/*cloudimg*.conf /etc/ssh/sshd_config.d/*cloud-init*.conf 2>/dev/null || true

    sshd -t || {
        echo "  [СБОЙ] sshd -t не прошёл — убираю свой файл, SSH не трогаю"
        rm -f /etc/ssh/sshd_config.d/01-hardening.conf
        return 1
    }

    # Какой порт sshd возьмёт из конфига при следующем старте (читает файлы, не демон)
    local want_port
    want_port=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)

    # Socket-активация (Ubuntu 22.10+): порт держит systemd через ssh.socket,
    # sshd его вообще не открывает, и строка Port в конфиге игнорируется.
    if systemctl cat ssh.socket >/dev/null 2>&1; then
        systemctl disable --now ssh.socket >>"$SETUP_LOG" 2>&1 || true
    fi
    systemctl enable ssh >>"$SETUP_LOG" 2>&1 || systemctl enable sshd >>"$SETUP_LOG" 2>&1 || true
    # Именно restart: "enable --now" НЕ перезапускает уже запущенный демон,
    # поэтому старый порт продолжал жить до перезагрузки.
    systemctl restart ssh >>"$SETUP_LOG" 2>&1 || systemctl restart sshd >>"$SETUP_LOG" 2>&1 || true

    # Проверяем фактом, а не надеждой. Важно: «порт кем-то занят» — это НЕ успех.
    # Если на порту сидит чужой сервис, а sshd не поднялся, старый доступ уже закрыт.
    local i ok=""
    for i in $(seq 1 10); do
        if sshd_listens_on "$SSH_PORT"; then ok=1; break; fi
        sleep 1
    done

    if [[ -n "$ok" ]] && ssh_daemon_active; then
        SSH_HARDENED=1; SSH_PENDING_REBOOT=""
        echo "  Проверено: sshd слушает порт $SSH_PORT прямо сейчас. Текущая сессия не разорвётся."
        return 0
    fi

    # Демон не работает вообще — это авария, откатываемся немедленно
    if ! ssh_daemon_active; then
        echo "  [СБОЙ] служба sshd не запущена после перезапуска. Откатываю харденинг."
        rm -f /etc/ssh/sshd_config.d/01-hardening.conf
        systemctl restart ssh >>"$SETUP_LOG" 2>&1 || systemctl restart sshd >>"$SETUP_LOG" 2>&1 || true
        SSH_HARDENED=""; SSH_PENDING_REBOOT=""
        return 1
    fi

    if [[ "$want_port" == "$SSH_PORT" ]] && [[ -n "$(current_sshd_ports)" ]]; then
        # Конфиг принят, но демон не перебиндился. Не откатываем — применится на ребуте,
        # а UFW ниже оставит открытым и старый порт, чтобы не потерять доступ.
        SSH_HARDENED=1; SSH_PENDING_REBOOT=1
        echo "  [ВНИМАНИЕ] sshd принял конфиг (sshd -T показывает порт $SSH_PORT), но пока слушает старый порт."
        echo "             Новый порт заработает после перезагрузки. Старый порт останется открыт в UFW."
        return 0
    fi

    echo "  [СБОЙ] sshd не видит порт $SSH_PORT в своём конфиге (sshd -T показывает '${want_port:-?}')."
    echo "         Значит файл харденинга не читается. Откатываю, чтобы не потерять доступ."
    rm -f /etc/ssh/sshd_config.d/01-hardening.conf
    systemctl restart ssh >>"$SETUP_LOG" 2>&1 || systemctl restart sshd >>"$SETUP_LOG" 2>&1 || true
    SSH_HARDENED=""; SSH_PENDING_REBOOT=""
    return 1
}

comp_ufw() {
    ask_panel_ip
    echo ">>> Настройка UFW..."
    # Открываем целевой порт + все, на которых SSH может быть прямо сейчас.
    # Иначе при отложенном применении порта фаервол запер бы нас снаружи.
    local ssh_ports p
    ssh_ports="$SSH_PORT"                                       # куда переезжаем
    for p in $(sshd -T 2>/dev/null | awk '/^port /{print $2}'); do ssh_ports+=" $p"; done
    for p in $(current_sshd_ports); do ssh_ports+=" $p"; done   # где sshd сидит прямо сейчас
    ssh_ports=$(printf '%s\n' $ssh_ports | sort -un)
    UFW_SSH_PORTS=""
    for p in $ssh_ports; do UFW_SSH_PORTS+="${UFW_SSH_PORTS:+, }$p/tcp"; done
    echo "  SSH-порты в правилах: $UFW_SSH_PORTS"

    # IPV6=no означает, что ufw вообще не трогает ip6tables: политика остаётся
    # ACCEPT и все порты открыты миру по IPv6. Отключаем фильтрацию, только если
    # стека IPv6 уже нет в ядре — иначе пусть ufw его фильтрует.
    if [[ -d /proc/sys/net/ipv6 ]]; then
        sed -i 's/^IPV6=no/IPV6=yes/' /etc/default/ufw
        echo "  IPv6 ещё активен — фаервол будет фильтровать и его."
    else
        sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw
    fi
    sed -i 's|net/ipv4/icmp_echo_ignore_all=0|net/ipv4/icmp_echo_ignore_all=1|' /etc/ufw/sysctl.conf
    {
        ufw --force reset
        ufw default deny incoming
        ufw default allow outgoing
        for p in $ssh_ports; do ufw limit "$p/tcp" comment 'SSH Rate Limit'; done
        ufw allow 80/tcp comment 'HTTP'
        ufw allow 443/tcp comment 'HTTPS'
        ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp comment 'API panel'
        ufw --force enable
    } >>"$SETUP_LOG" 2>&1
}

comp_fail2ban() {
    echo ">>> Настройка fail2ban..."
    # python3-systemd нужен для backend=systemd ниже; без него джейл sshd молча не стартует
    apt-get install -y fail2ban python3-systemd >>"$SETUP_LOG" 2>&1 || true
    cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled  = true
backend  = systemd
port     = $SSH_PORT
maxretry = 4
bantime  = 24h

[recidive]
enabled  = true
bantime  = 1w
findtime = 1d
maxretry = 5
EOF
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >>"$SETUP_LOG" 2>&1
    # С backend=systemd fail2ban при старте вычитывает журнал за findtime/bantime,
    # на сервере с большим журналом это заметно дольше двух секунд.
    local i
    for i in $(seq 1 15); do
        if fail2ban-client status sshd >>"$SETUP_LOG" 2>&1; then
            return 0
        fi
        sleep 2
    done
    echo "  [СБОЙ] джейл sshd в fail2ban не поднялся за 30 сек (см. $SETUP_LOG)"
    return 1
}

# ===== lib/60-node.sh ==================================================
# ##########################################################################
#  НОДА
#  Docker и контейнер Remnanode
# ##########################################################################

# Точное совпадение порта. Раньше было grep ":$NODE_PORT" — подстрока,
# из-за неё слушатель на 22220 засчитывался за 2222 и нода считалась живой.
port_is_listening() {
    ss -H -ltn 2>/dev/null | awk '{print $4}' | sed 's/.*://' | grep -qx "$1"
}

comp_docker() {
    echo ">>> Установка Docker..."
    if command -v docker >/dev/null 2>&1; then
        echo "  Docker уже установлен."
        return 0
    fi
    curl -fsSL https://get.docker.com | sh >>"$SETUP_LOG" 2>&1
}

node_status() {
    echo "----- Статус ноды -----"
    docker inspect -f 'Контейнер: {{.State.Status}} (running={{.State.Running}}, restarts={{.RestartCount}}, oom={{.State.OOMKilled}})' remnanode 2>/dev/null || echo "Контейнер remnanode не найден."
    if port_is_listening "$NODE_PORT"; then
        echo "Порт $NODE_PORT (API, к нему подключается панель): СЛУШАЕТ — связь с панелью возможна"
    else
        echo "Порт $NODE_PORT (API, к нему подключается панель): НЕ слушает — панель НЕ подключится к ноде"
    fi
    echo "----- Последние 30 строк логов -----"
    docker logs --tail=30 remnanode 2>&1 || echo "Логи недоступны."
}

comp_node() {
    ask_secret
    echo ">>> Разворачивание Remnanode..."
    mkdir -p /opt/remnanode
    chmod 700 /opt/remnanode
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
      - NODE_PORT=$NODE_PORT
      - SECRET_KEY="${REMNA_SECRET}"
EOF
    chmod 600 /opt/remnanode/docker-compose.yml   # внутри SECRET_KEY ноды
    if ! ( cd /opt/remnanode && docker compose up -d ) >>"$SETUP_LOG" 2>&1; then
        echo "  [СБОЙ] docker compose up не отработал (см. $SETUP_LOG)"
        node_status
        return 1
    fi
    echo "  Ожидание запуска ноды (порт $NODE_PORT, до 30 сек)..."
    local i up=""
    for i in $(seq 1 30); do
        if port_is_listening "$NODE_PORT"; then up=1; break; fi
        sleep 1
    done
    node_status
    if [[ -z "$up" ]]; then
        echo "  [СБОЙ] нода не начала слушать порт $NODE_PORT — панель её не увидит"
        return 1
    fi
    return 0
}

comp_node_update() {
    echo ">>> Обновление ноды Remnanode..."
    if [[ -f /opt/remnanode/docker-compose.yml ]]; then
        if ! ( cd /opt/remnanode && docker compose pull && docker compose up -d ) >>"$SETUP_LOG" 2>&1; then
            echo "  [СБОЙ] обновление не прошло (см. $SETUP_LOG)"
            node_status
            notify_telegram "❌ Нода <code>$(hostname)</code>: обновление НЕ удалось ($(date '+%H:%M:%S'))"
            return 1
        fi
        node_status
        notify_telegram "⬆️ Нода <code>$(hostname)</code> обновлена ($(date '+%H:%M:%S'))"
    else
        echo "  Нода не установлена (/opt/remnanode/docker-compose.yml не найден)."
        return 1
    fi
}

# ===== lib/70-web.sh ===================================================
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
            if [[ -n "$NONINTERACTIVE" ]]; then
                echo "  Неинтерактивный режим — пробую выпустить сертификат всё равно."
            else
                read -ep "  Пробовать выпустить сертификат всё равно? [y/N]: " TRY_ANYWAY
                if [[ ! "$TRY_ANYWAY" =~ ^[Yy]$ ]]; then
                    acme_serve_stop
                    echo "  [СБОЙ] Выпуск сертификата отменён."
                    cf_restore_proxy
                    return 1
                fi
            fi
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

# ===== lib/75-domain.sh ================================================
# ##########################################################################
#  СМЕНА ДОМЕНА НОДЫ
#  Перевод работающей ноды на другой субдомен без переустановки
# ##########################################################################

# Раньше это был отдельный changedomain.sh со своей копией логики выпуска
# сертификата и своим шаблоном nginx. Копия успела разойтись с оригиналом:
# там остался certbot --nginx (который запускался до создания конфига и потому
# не находил нужный server_name) и проверка DNS по совпадению IP, не работающая
# за прокси Cloudflare. Здесь используются те же функции, что и при установке.

comp_change_domain() {
    local old_domain="${FULL_DOMAIN:-}"
    if [[ -z "$old_domain" && -n "${SUBDOMAIN:-}" && -n "${DOMAIN:-}" ]]; then
        old_domain="${SUBDOMAIN}.${DOMAIN}"
    fi
    echo ">>> Смена домена ноды"
    echo "  Текущий домен: ${old_domain:-неизвестен}"

    if [[ -z "$NONINTERACTIVE" ]]; then
        echo "  Заведите A-запись нового субдомена ДО продолжения."
        DOMAIN=""; SUBDOMAIN=""
    fi
    ask_domain
    ask_subdomain
    FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"

    if [[ "$FULL_DOMAIN" == "$old_domain" ]]; then
        echo "  Новый домен совпадает со старым — менять нечего."
        return 0
    fi
    echo "  Переводим ноду: ${old_domain:-?}  ->  $FULL_DOMAIN"

    get_server_ip || true

    # --- сертификат для нового домена ---
    if [[ -d "/etc/letsencrypt/live/$FULL_DOMAIN" ]]; then
        echo "  Сертификат для $FULL_DOMAIN уже есть, выпускать не нужно."
    else
        acme_serve_start || return 1
        if ! acme_reachable; then
            echo "  [ВНИМАНИЕ] ACME-проверка не дошла до сервера."
            echo "    Проверьте A-запись $FULL_DOMAIN и что порт 80 открыт."
            if [[ -z "$NONINTERACTIVE" ]]; then
                read -ep "  Пробовать выпустить сертификат всё равно? [y/N]: " TRY || TRY=""
                if [[ ! "$TRY" =~ ^[Yy]$ ]]; then
                    acme_serve_stop
                    echo "  [СБОЙ] Смена домена отменена, ничего не изменено."
                    return 1
                fi
            fi
        fi
        if ! certbot certonly --webroot -w /var/lib/letsencrypt -d "$FULL_DOMAIN" \
                --register-unsafely-without-email --agree-tos --non-interactive \
                --keep-until-expiring >>"$SETUP_LOG" 2>&1; then
            acme_serve_stop
            echo "  [СБОЙ] Certbot не выпустил сертификат для $FULL_DOMAIN (см. $SETUP_LOG)"
            echo "         Нода осталась на прежнем домене, ничего не сломано."
            return 1
        fi
        acme_serve_stop
    fi

    # --- конфиг nginx (тот же шаблон, что при установке) ---
    if ! write_nginx_site "$FULL_DOMAIN"; then
        echo "  [СБОЙ] nginx не принял конфиг нового домена."
        if [[ -n "$old_domain" && -f "/etc/nginx/sites-available/$old_domain" ]]; then
            echo "  Возвращаю прежний домен, чтобы нода не осталась без веба..."
            write_nginx_site "$old_domain" || echo "  [СБОЙ] и прежний конфиг не поднялся — смотрите $SETUP_LOG"
            FULL_DOMAIN="$old_domain"
            SUBDOMAIN="${old_domain%%.*}"; DOMAIN="${old_domain#*.}"
        fi
        return 1
    fi

    # --- сохранённые ответы: иначе следующий запуск setup.sh вернёт старый домен ---
    save_state
    echo "  Новый домен записан в $INSTALL_STATE"

    # --- метка ноды в уведомлениях, если она была равна старому домену ---
    if [[ -f "$NOTIFY_ENV" ]] && grep -q "NODE_LABEL=\"$old_domain\"" "$NOTIFY_ENV" 2>/dev/null; then
        sed -i "s|NODE_LABEL=\"$old_domain\"|NODE_LABEL=\"$FULL_DOMAIN\"|" "$NOTIFY_ENV"
        echo "  Имя ноды в уведомлениях обновлено на $FULL_DOMAIN"
    fi

    # --- старый сертификат: удаляем только с явного согласия ---
    if [[ -n "$old_domain" && -d "/etc/letsencrypt/live/$old_domain" && -z "$NONINTERACTIVE" ]]; then
        echo
        echo "  Остался сертификат старого домена $old_domain."
        echo "  Его можно удалить, но если планируете вернуться — оставьте."
        read -ep "  Удалить сертификат $old_domain? [y/N]: " DELCERT || DELCERT=""
        if [[ "$DELCERT" =~ ^[Yy]$ ]]; then
            certbot delete --cert-name "$old_domain" --non-interactive >>"$SETUP_LOG" 2>&1 \
                && echo "  Сертификат $old_domain удалён." \
                || echo "  [ВНИМАНИЕ] Удалить сертификат не удалось (см. $SETUP_LOG)"
        else
            echo "  Сертификат $old_domain оставлен."
        fi
    fi
    if [[ -n "$old_domain" && -f "/etc/nginx/sites-available/$old_domain" && -z "$NONINTERACTIVE" ]]; then
        read -ep "  Удалить старый конфиг nginx /etc/nginx/sites-available/$old_domain? [y/N]: " DELCONF || DELCONF=""
        if [[ "$DELCONF" =~ ^[Yy]$ ]]; then
            rm -f "/etc/nginx/sites-available/$old_domain"
            echo "  Старый конфиг удалён."
        else
            echo "  Старый конфиг оставлен (он отключён и ни на что не влияет)."
        fi
    fi

    notify_telegram "🌐 Нода переведена на домен <code>${FULL_DOMAIN}</code> (была <code>${old_domain:-?}</code>)"

    echo
    echo "  =========================================="
    echo "  Нода переведена на $FULL_DOMAIN"
    echo "  =========================================="
    echo "  ОСТАЛОСЬ СДЕЛАТЬ ВРУЧНУЮ: поменять адрес ноды в панели Remnawave."
    echo "  Пока этого нет, панель продолжит ходить на старый адрес."
    return 0
}

# ===== lib/80-notify.sh ================================================
# ##########################################################################
#  УВЕДОМЛЕНИЯ
#  Телеграм: вход по SSH, загрузка сервера, падение ноды
# ##########################################################################

comp_telegram() {
    ask_telegram          # все вопросы заданы здесь же, если ещё не заданы раньше
    echo ">>> Настройка Telegram-уведомлений..."
    local node_ip node_label
    node_ip=$(curl -s --max-time 5 https://api.ipify.org || echo "")

    if [[ -n "$USER_NODE_LABEL" ]]; then
        node_label="$USER_NODE_LABEL"
    elif [[ -n "$FULL_DOMAIN" ]]; then
        node_label="$FULL_DOMAIN"
    else
        node_label=$(hostname)
    fi
    
    mkdir -p "$(dirname "$NOTIFY_ENV")"
    cat <<EOF > "$NOTIFY_ENV"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
TG_TOPIC_ID="${TG_TOPIC_ID:-}"
TG_PROXY="${TG_PROXY:-}"
NODE_LABEL="$node_label"
NODE_IP="$node_ip"
NODE_PORT="$NODE_PORT"
EOF
    chmod 600 "$NOTIFY_ENV"

    # универсальный отправщик: добавляет шапку с именем/IP ноды к любому сообщению
    cat <<SCRIPT > /usr/local/bin/rh-notify.sh
[[ -f "$NOTIFY_ENV" ]] && source "$NOTIFY_ENV"
[[ -z "\$TG_BOT_TOKEN" || -z "\$TG_CHAT_ID" ]] && exit 0
HEADER="🖥 <b>\${NODE_LABEL:-\$(hostname)}</b>"
[[ -n "\$NODE_IP" ]] && HEADER="\$HEADER  <code>\${NODE_IP}</code>"
ARGS=(-s --max-time 15)
[[ -n "\$TG_PROXY" ]] && ARGS+=(-x "\$TG_PROXY")
ARGS+=(-d "chat_id=\${TG_CHAT_ID}" -d "parse_mode=HTML" --data-urlencode "text=\${HEADER}
\$1")
[[ -n "\$TG_TOPIC_ID" ]] && ARGS+=(-d "message_thread_id=\${TG_TOPIC_ID}")
curl "\${ARGS[@]}" -X POST "https://api.telegram.org/bot\${TG_BOT_TOKEN}/sendMessage" >/dev/null 2>&1
SCRIPT
    chmod 755 /usr/local/bin/rh-notify.sh

    # 1) SSH-вход
    cat <<'SCRIPT' > /usr/local/bin/rh-ssh-login.sh
[[ "$PAM_TYPE" != "open_session" ]] && exit 0
/usr/local/bin/rh-notify.sh "🔐 <b>SSH-вход</b>
Пользователь: <code>${PAM_USER}</code>
Откуда IP: <code>${PAM_RHOST}</code>
Время: $(date '+%Y-%m-%d %H:%M:%S %Z')" &
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
ExecStartPre=/bin/sleep 8
ExecStart=/bin/bash -c '/usr/local/bin/rh-notify.sh "♻️ Сервер загрузился ($(date "+%%H:%%M:%%S %%Z"))"'
[Install]
WantedBy=multi-user.target
UNIT

    # Мгновенный вотчер падения/подъёма ноды через docker events
    cat <<'SCRIPT' > /usr/local/bin/rh-node-watch.sh
FLAG=/run/rh-node-down
down(){ [[ -f "$FLAG" ]] || { /usr/local/bin/rh-notify.sh "⚠️ <b>Нода упала</b>: remnanode $1 ($(date '+%H:%M:%S'))"; touch "$FLAG"; }; }
up(){ [[ -f "$FLAG" ]] && { /usr/local/bin/rh-notify.sh "✅ <b>Нода поднялась</b>: remnanode запущен ($(date '+%H:%M:%S'))"; rm -f "$FLAG"; }; }
docker events --filter 'container=remnanode' --filter 'event=start' --filter 'event=die' --filter 'event=stop' --filter 'event=kill' --format '{{.Action}}' 2>/dev/null | \
while read -r ev; do
    case "$ev" in
        start) up ;;
        die|stop|kill) down "$ev" ;;
    esac
done
SCRIPT
    chmod 755 /usr/local/bin/rh-node-watch.sh
    cat <<'UNIT' > /etc/systemd/system/rh-node-watch.service
[Unit]
Description=Watch remnanode docker events -> Telegram (instant)
After=docker.service
Requires=docker.service
[Service]
Restart=always
RestartSec=5
ExecStart=/usr/local/bin/rh-node-watch.sh
[Install]
WantedBy=multi-user.target
UNIT

    # Страховочный опрос: ловит случай "контейнер жив, но порт панели не слушает" (каждые 2 мин).
    # Heredoc без кавычек: $NOTIFY_ENV подставляется сейчас, всё остальное экранировано
    # и остаётся переменными внутри сгенерированного скрипта.
    cat <<SCRIPT > /usr/local/bin/rh-node-health.sh
[[ -f "$NOTIFY_ENV" ]] && source "$NOTIFY_ENV"
PORT="\${NODE_PORT:-2222}"
FLAG=/run/rh-node-down
RUNNING=\$(docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null || echo "false")
LISTEN=no
ss -H -ltn 2>/dev/null | grep -q ":\${PORT}" && LISTEN=yes
if [[ "\$RUNNING" != "true" || "\$LISTEN" != "yes" ]]; then
    [[ -f "\$FLAG" ]] || { /usr/local/bin/rh-notify.sh "⚠️ <b>Проблема ноды</b>: контейнер running=\${RUNNING}, порт \${PORT}=\${LISTEN} — панель может не видеть ноду"; touch "\$FLAG"; }
else
    [[ -f "\$FLAG" ]] && { /usr/local/bin/rh-notify.sh "✅ <b>Нода в норме</b>"; rm -f "\$FLAG"; }
fi
SCRIPT
    chmod 755 /usr/local/bin/rh-node-health.sh
    cat <<'UNIT' > /etc/systemd/system/rh-node-health.service
[Unit]
Description=Remnanode health (safety net) -> Telegram
[Service]
Type=oneshot
ExecStart=/usr/local/bin/rh-node-health.sh
UNIT
    cat <<'UNIT' > /etc/systemd/system/rh-node-health.timer
[Unit]
Description=Remnanode healthcheck safety-net every 2 min
[Timer]
OnBootSec=120
OnUnitActiveSec=120
[Install]
WantedBy=timers.target
UNIT
    systemctl daemon-reload >>"$SETUP_LOG" 2>&1
    systemctl enable rh-boot-notify.service >/dev/null 2>&1 || true
    systemctl enable rh-node-watch.service >/dev/null 2>&1 || true
    systemctl restart rh-node-watch.service >>"$SETUP_LOG" 2>&1 || true
    systemctl enable rh-node-health.timer >/dev/null 2>&1 || true
    systemctl restart rh-node-health.timer >>"$SETUP_LOG" 2>&1 || true

    # Проверяем ответ Telegram, а не просто факт запуска curl: неверный токен,
    # не добавленный в группу бот и недоступный api.telegram.org выглядели как успех.
    local tg_args=(-s --max-time 20)
    [[ -n "$TG_PROXY" ]] && tg_args+=(-x "$TG_PROXY")
    local resp
    resp=$(curl "${tg_args[@]}" -X POST \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" -d "parse_mode=HTML" \
        ${TG_TOPIC_ID:+-d "message_thread_id=${TG_TOPIC_ID}"} \
        --data-urlencode "text=✅ Уведомления настроены (SSH-входы, загрузка, падение/подъём ноды)" 2>/dev/null || true)
    if grep -q '"ok":true' <<< "$resp"; then
        echo "  Тестовое сообщение доставлено в Telegram."
        return 0
    fi
    echo "  [СБОЙ] Telegram не принял сообщение. Ответ API:"
    echo "    $(head -c 300 <<< "${resp:-пустой ответ}")"
    echo "    Проверьте BOT_TOKEN, CHAT_ID и что бот добавлен в группу."
    return 1
}

# ===== lib/82-panel.sh =================================================
# ##########################################################################
#  СТОРОЖ ПАНЕЛИ
#  Дежурная нода замечает, что панель перестала к ней приходить
# ##########################################################################

# Как это работает и почему именно так.
#
# Связь односторонняя: панель сама подключается к ноде на $NODE_PORT и держит
# постоянные TCP-соединения (наблюдение на живой ноде: три ESTABLISHED с IP
# панели, стабильно). Нода к панели не ходит вообще — значит узнать о падении
# панели можно только по косвенному признаку: соединения пропали.
#
# У этого признака есть слабое место. Если машина панели умрёт жёстко (питание,
# паника ядра), сокеты на стороне ноды могут остаться в ESTABLISHED, пока их не
# добьёт TCP-таймаут. Поэтому есть вторая, активная проверка: нода сама стучится
# в порт панели. Она ловит ровно тот случай, который пропускает первая.
#
# Сторож включается на ОДНОЙ дежурной ноде: иначе при падении панели придёт
# столько одинаковых сообщений, сколько у вас нод.

comp_panel_watch() {
    if [[ ! -f "$NOTIFY_ENV" ]]; then
        echo "  [СБОЙ] сначала настройте Telegram-уведомления (пункт 11) — сторожу некуда писать"
        return 1
    fi
    ask_panel_ip
    if [[ -z "$NONINTERACTIVE" ]]; then
        echo "  Активная проверка: нода сама постучится в порт панели."
        echo "  Это ловит жёсткое падение сервера панели, когда соединения зависают."
        echo "  Укажите порт веб-панели (обычно 443). Enter — без активной проверки."
        read -ep "Порт панели для проверки [443]: " PANEL_PROBE_PORT || PANEL_PROBE_PORT=""
        PANEL_PROBE_PORT=$(echo "${PANEL_PROBE_PORT:-443}" | tr -d '[:space:]')
        [[ "$PANEL_PROBE_PORT" =~ ^[0-9]+$ ]] || PANEL_PROBE_PORT=""
    fi
    PANEL_FAIL_CHECKS="${PANEL_FAIL_CHECKS:-3}"

    echo ">>> Настройка сторожа панели..."
    mkdir -p "$(dirname "$PANEL_ENV")"
    cat <<EOF > "$PANEL_ENV"
PANEL_IP="$PANEL_IP"
NODE_PORT="$NODE_PORT"
PANEL_PROBE_PORT="${PANEL_PROBE_PORT:-}"
# Сколько проверок подряд должно провалиться до тревоги (одна проверка = 2 мин).
# 3 — это 6 минут: переживает перезапуск панели, но не проспит настоящее падение.
PANEL_FAIL_CHECKS="$PANEL_FAIL_CHECKS"
EOF
    chmod 600 "$PANEL_ENV"

    # Heredoc без кавычек: $PANEL_ENV подставляется сейчас, остальное экранировано
    # и остаётся переменными внутри сгенерированного скрипта.
    cat <<SCRIPT > "$PANEL_WATCH_BIN"
[[ -f "$PANEL_ENV" ]] || exit 0
source "$PANEL_ENV"
[[ -z "\$PANEL_IP" ]] && exit 0

# Каталог состояния: на сервере это /run (сторож работает от root через systemd),
# в тестах подменяется на временный, чтобы прогон не требовал прав root
STATE_DIR="\${RH_STATE_DIR:-/run}"
COUNT_FILE="\$STATE_DIR/rh-panel-fails"
FLAG="\$STATE_DIR/rh-panel-down"

# 1) Сколько соединений держит панель с этой нодой
CONNS=\$(ss -H -tn state established "( sport = :\${NODE_PORT} )" 2>/dev/null \\
        | grep -c "\${PANEL_IP}:" || true)

# 2) Достучаться до панели самим (ловит жёсткое падение, когда сокеты зависли)
PROBE="skip"
if [[ -n "\$PANEL_PROBE_PORT" ]]; then
    if timeout 5 bash -c "exec 3<>/dev/tcp/\${PANEL_IP}/\${PANEL_PROBE_PORT}" 2>/dev/null; then
        PROBE="ok"
    else
        PROBE="fail"
    fi
fi

REASON=""
[[ "\$CONNS" -eq 0 ]] && REASON="панель не держит ни одного соединения с нодой"
[[ "\$PROBE" == "fail" ]] && REASON="порт \${PANEL_PROBE_PORT} панели не отвечает"
if [[ "\$CONNS" -eq 0 && "\$PROBE" == "ok" ]]; then
    REASON="сервер панели отвечает, но к ноде не подключается"
fi

FAILS=\$(cat "\$COUNT_FILE" 2>/dev/null || echo 0)
if [[ -n "\$REASON" ]]; then
    FAILS=\$((FAILS + 1))
    echo "\$FAILS" > "\$COUNT_FILE"
    if [[ "\$FAILS" -ge "\${PANEL_FAIL_CHECKS:-3}" && ! -f "\$FLAG" ]]; then
        MIN=\$(( FAILS * 2 ))
        $NOTIFY_BIN "🛑 <b>ПАНЕЛЬ НЕ НА СВЯЗИ</b>
Причина: \${REASON}
Не отвечает: ~\${MIN} мин
IP панели: <code>\${PANEL_IP}</code>
Соединений с нодой: \${CONNS}"
        touch "\$FLAG"
    fi
else
    echo 0 > "\$COUNT_FILE"
    if [[ -f "\$FLAG" ]]; then
        $NOTIFY_BIN "✅ <b>Панель снова на связи</b>
Соединений с нодой: \${CONNS} (\$(date '+%H:%M:%S'))"
        rm -f "\$FLAG"
    fi
fi
exit 0
SCRIPT
    chmod 755 "$PANEL_WATCH_BIN"

    cat <<UNIT > /etc/systemd/system/rh-panel-watch.service
[Unit]
Description=Watch master panel connectivity -> Telegram
[Service]
Type=oneshot
ExecStart=$PANEL_WATCH_BIN
UNIT
    cat <<'UNIT' > /etc/systemd/system/rh-panel-watch.timer
[Unit]
Description=Panel connectivity check every 2 min
[Timer]
OnBootSec=180
OnUnitActiveSec=120
[Install]
WantedBy=timers.target
UNIT
    systemctl daemon-reload >>"$SETUP_LOG" 2>&1
    systemctl enable rh-panel-watch.timer >/dev/null 2>&1 || true
    systemctl restart rh-panel-watch.timer >>"$SETUP_LOG" 2>&1

    # Сразу проверяем, что сторож видит панель прямо сейчас
    local conns
    conns=$(ss -H -tn state established "( sport = :${NODE_PORT} )" 2>/dev/null | grep -c "${PANEL_IP}:" || true)
    if [[ "$conns" -gt 0 ]]; then
        echo "  Панель сейчас держит $conns соединений с этой нодой — сторожу есть за чем следить."
    else
        echo "  [ВНИМАНИЕ] Панель сейчас НЕ подключена к этой ноде ($conns соединений)."
        echo "             Либо панель действительно недоступна, либо нода ещё не добавлена в панель."
    fi
    PANEL_WATCH="y"
    echo "  Сторож включён: проверка каждые 2 мин, тревога после $PANEL_FAIL_CHECKS провалов подряд."
    return 0
}

comp_panel_watch_off() {
    echo ">>> Отключаю сторож панели..."
    systemctl disable --now rh-panel-watch.timer >>"$SETUP_LOG" 2>&1 || true
    rm -f /etc/systemd/system/rh-panel-watch.timer /etc/systemd/system/rh-panel-watch.service
    rm -f "$PANEL_WATCH_BIN" /run/rh-panel-down /run/rh-panel-fails
    systemctl daemon-reload >>"$SETUP_LOG" 2>&1
    PANEL_WATCH="n"
    echo "  Сторож отключён. Эта нода больше не следит за панелью."
    return 0
}

# ===== lib/85-extras.sh ================================================
# ##########################################################################
#  ДОПОЛНЕНИЯ
#  Необязательные компоненты и диагностика
# ##########################################################################

comp_warp() {
    echo ">>> Установка/переустановка Cloudflare WARP..."
    {
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/cloudflare-client.list

        apt-get update
        apt-get install -y cloudflare-warp

        warp-cli --accept-tos registration new || echo "y" | warp-cli registration new

        warp-cli --accept-tos mode proxy || warp-cli mode proxy
        warp-cli --accept-tos proxy port "$WARP_PORT" || warp-cli proxy port "$WARP_PORT"

        warp-cli --accept-tos connect || warp-cli connect
    } >>"$SETUP_LOG" 2>&1 || { echo "  Ошибка установки WARP (см. $SETUP_LOG)"; return 1; }
}

comp_speedtest() {
    echo ">>> Установка Speedtest CLI..."
    {
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
        if grep -q "noble" /etc/apt/sources.list.d/ookla_speedtest-cli.list 2>/dev/null; then
            sed -i 's/noble/jammy/g' /etc/apt/sources.list.d/ookla_speedtest-cli.list; apt-get update
        fi
        apt-get install -y speedtest
    } >>"$SETUP_LOG" 2>&1 || { echo "  Speedtest не установился (см. $SETUP_LOG)"; return 1; }
}

run_bench() { echo ">>> bench.sh..."; wget -qO- bench.sh | bash || true; }

run_geo()   { echo ">>> ipregion.sh..."; bash <(wget -qO- https://raw.githubusercontent.com/Davoyan/ipregion/main/ipregion.sh) || true; }

run_censor() { echo ">>> Проверка блокировок/DPI/DNS (censorcheck)..."; bash <(wget -qO- https://raw.githubusercontent.com/vernette/censorcheck/master/censorcheck.sh) || true; }

# ===== lib/90-install.sh ===============================================
# ##########################################################################
#  ПОЛНАЯ УСТАНОВКА
#  Порядок шагов при установке с нуля
# ##########################################################################

# ##########################################################################
#  ПОЛНАЯ УСТАНОВКА
# ##########################################################################
full_install() {
    echo -e "\n========== ПОЛНАЯ УСТАНОВКА =========="
    if [[ -n "$STATE_LOADED" && -z "$NONINTERACTIVE" ]]; then
        echo "Найдены данные прошлой установки: ${SUBDOMAIN}.${DOMAIN}, панель ${PANEL_IP}, учётка ${ADMIN_USER}, порт SSH ${SSH_PORT}"
        read -ep "Обновить с этими данными (без повторного ввода)? [Y/n]: " USE_SAVED || USE_SAVED=""
        if [[ "$USE_SAVED" =~ ^[Nn]$ ]]; then
            DOMAIN=""; SUBDOMAIN=""; PANEL_IP=""; REMNA_SECRET=""
            SETUP_CF=""; CF_API_TOKEN=""; CF_PROXY_CHOICE=""
            SETUP_SSH=""; SSH_PUBLIC_KEY=""; INSTALL_WARP=""; INSTALL_SPEEDTEST=""
            SSH_PORT="8422"; ADMIN_USER="admin"
            SETUP_TG=""; TG_BOT_TOKEN=""; TG_CHAT_ID=""; TG_TOPIC_ID=""
        fi
    fi
    # --- сбор всех ответов заранее ---
    ask_domain; ask_panel_ip; ask_subdomain; ask_secret; ask_cf

    echo -e "\n--- SSH ---"
    ask_ssh_params
    echo "Итого: учётка «$ADMIN_USER», порт SSH $SSH_PORT. Вход под root и вход по паролю будут отключены."

    if [[ -z "$NONINTERACTIVE" ]]; then
        ask_ssh_key

        echo -e "\n--- Доп. компоненты ---"
        [[ -z "$INSTALL_WARP" ]]      && read -ep "Установить Cloudflare WARP? [y/N]: " INSTALL_WARP
        [[ -z "$INSTALL_SPEEDTEST" ]] && read -ep "Установить Speedtest CLI? [y/N]: " INSTALL_SPEEDTEST

        echo -e "\n--- Telegram-уведомления ---"
        [[ -z "$SETUP_TG" && -z "$TG_BOT_TOKEN" ]] && read -ep "Настроить Telegram-уведомления? [y/N]: " SETUP_TG
        [[ "$SETUP_TG" =~ ^[Yy]$ || -n "$TG_BOT_TOKEN" ]] && ask_telegram
    fi
    [[ "$SETUP_TG" =~ ^[Yy]$ || -n "$TG_BOT_TOKEN" ]] && TG_ON=1 || TG_ON=""

    save_state   # запомнить ответы для будущих обновлений
    FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"
    echo -e "\nСтавлю ноду для $FULL_DOMAIN. Тяжёлый вывод — в $SETUP_LOG\n"; sleep 2

    # --- выполнение (каждый шаг пишет результат в сводку) ---
    do_step "Swap" comp_swap
    do_step "Пакеты и обновление системы" comp_packages
    do_step "Пользователь $ADMIN_USER" comp_user
    do_step "Харденинг SSH" comp_ssh
    do_step "fail2ban" comp_fail2ban
    do_step "Автообновления безопасности" comp_autoupdates
    do_step "Отключение IPv6 (GRUB)" comp_ipv6
    do_step "UFW-фаервол" comp_ufw
    do_step "Sysctl-тюнинг" comp_sysctl
    do_step "Docker" comp_docker
    do_step "Защита диска (лог-ротация)" comp_disk
    [[ "$INSTALL_SPEEDTEST" =~ ^[Yy]$ ]] && do_step "Speedtest CLI" comp_speedtest || skip_step "Speedtest CLI"
    [[ "$INSTALL_WARP" =~ ^[Yy]$ ]] && do_step "Cloudflare WARP" comp_warp || skip_step "Cloudflare WARP"
    do_step "Нода Remnanode" comp_node
    do_step "Веб (заглушка+сертификат+nginx)" comp_web
    [[ -n "$TG_ON" ]] && do_step "Telegram-уведомления" comp_telegram || skip_step "Telegram-уведомления"
    if [[ -n "$TG_ON" && "$PANEL_WATCH" =~ ^[Yy]$ ]]; then
        do_step "Сторож панели" comp_panel_watch
    else
        skip_step "Сторож панели (нода не дежурная)"
    fi

    notify_telegram "🚀 Нода <code>${FULL_DOMAIN}</code> установлена ($(date '+%H:%M:%S %Z'))"

    print_summary

    if [[ -z "$NONINTERACTIVE" ]]; then
        echo
        echo "Отчёт выше сохранён в $REPORT_FILE (в нём же пароль учётки)."
        echo "Отключение IPv6 (GRUB) применится только после перезагрузки."
        read -ep "Доустановить/переустановить что-то в меню перед ребутом? [y/N]: " ADDC || ADDC=""
        [[ "$ADDC" =~ ^[Yy]$ ]] && components_menu
        read -ep "Перезагрузить сервер сейчас? [Y/n]: " RB || RB=""
        if [[ "$RB" =~ ^[Nn]$ ]]; then
            echo "Ок. Позже перезагрузи вручную (нужно для IPv6): reboot"
            return
        fi
    fi
    echo "Перезагрузка через 10 секунд (Ctrl+C — отменить)..."
    sleep 10
    reboot
}

# ===== lib/95-menu.sh ==================================================
# ##########################################################################
#  МЕНЮ
#  Главное меню и меню компонентов
# ##########################################################################

# ##########################################################################
#  МЕНЮ
# ##########################################################################
# Запуск компонента из меню.
# Обязательно через "if", а не напрямую: ERR-трап срабатывает даже при set +e,
# и любая ненулевая команда внутри comp_* убивала бы весь установщик.
# Внутри условия и set -e, и ERR-трап подавлены для всего поддерева вызова.
menu_step() {
    local label="$1"; shift
    if "$@"; then
        echo -e "\n[Готово] $label"
    else
        echo -e "\n[СБОЙ] $label — подробности в $SETUP_LOG"
    fi
    return 0
}

# Пункт 8 делает два шага подряд — оборачиваем, чтобы тоже шло через menu_step
comp_user_and_ssh() { comp_user && comp_ssh; }

components_menu() {
    while true; do
        echo -e "\n===== Компоненты (доустановить / переустановить) ====="
        echo " 1) Cloudflare WARP        2) Docker          3) Нода (передеплой)"
        echo " 4) Веб (заглушка+серт)    5) UFW             6) Sysctl-тюнинг"
        echo " 7) Swap                   8) Юзер + SSH-харденинг   9) Speedtest"
        echo "10) IPv6 off (GRUB)"
        echo "--- Безопасность / обслуживание ---"
        echo "11) Telegram-уведомления  12) fail2ban       13) Автообновления"
        echo "21) Сторож панели вкл.    22) Сторож панели выкл."
        echo "23) Сменить домен ноды"
        echo "14) Защита диска          15) Обновить ноду  16) Статус ноды"
        echo "20) Обновить систему (apt upgrade + перезагрузка)"
        echo "--- Диагностика ---"
        echo "17) bench.sh   18) ipregion   19) проверка блокировок (censorcheck)"
        echo " 0) Назад"
        read -ep "Выбор: " c
        case "$c" in
             1) menu_step "Cloudflare WARP"      comp_warp ;;
             2) menu_step "Docker"               comp_docker ;;
             3) menu_step "Нода (передеплой)"    comp_node ;;
             4) menu_step "Веб (заглушка+серт)"  comp_web ;;
             5) menu_step "UFW"                  comp_ufw ;;
             6) menu_step "Sysctl-тюнинг"        comp_sysctl ;;
             7) menu_step "Swap"                 comp_swap ;;
             8) menu_step "Юзер + SSH-харденинг" comp_user_and_ssh ;;
             9) menu_step "Speedtest"            comp_speedtest ;;
            10) menu_step "IPv6 off (GRUB)"      comp_ipv6 ;;
            11) menu_step "Telegram-уведомления" comp_telegram ;;
            12) menu_step "fail2ban"             comp_fail2ban ;;
            13) menu_step "Автообновления"       comp_autoupdates ;;
            14) menu_step "Защита диска"         comp_disk ;;
            15) menu_step "Обновление ноды"      comp_node_update ;;
            16) menu_step "Статус ноды"          node_status ;;
            17) menu_step "bench.sh"             run_bench ;;
            18) menu_step "ipregion"             run_geo ;;
            19) menu_step "censorcheck"          run_censor ;;
            20) menu_step "Обновление системы"   comp_os_update ;;
            21) menu_step "Сторож панели"        comp_panel_watch ;;
            22) menu_step "Отключение сторожа"   comp_panel_watch_off ;;
            23) menu_step "Смена домена ноды"     comp_change_domain ;;
             0) return ;;
             *) echo "Нет такого пункта." ;;
        esac
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

# ===== lib/99-main.sh ==================================================
# ##########################################################################
#  ТОЧКА ВХОДА
#  Три режима: только загрузка функций (тесты), неинтерактивный, меню
# ##########################################################################

# Режим «только функции»: используется tests/, чтобы вызывать функции по одной
# без запуска установки. Работает и при source, и при обычном запуске.
if [[ -n "${RH_LIB_ONLY:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi

# Конфиг-файл первым аргументом — неинтерактивная установка
if [[ -n "$1" && -f "$1" ]]; then
    echo "Загружаю конфигурацию из файла: $1"
    # shellcheck disable=SC1090
    source "$1"
    NONINTERACTIVE=1
    validate_ssh_params
fi

if [[ -n "$NONINTERACTIVE" ]] || { [[ -n "$DOMAIN" ]] && [[ -n "$SUBDOMAIN" ]] && [[ -n "$REMNA_SECRET" ]]; }; then
    NONINTERACTIVE=1
    full_install
else
    # Интерактив: подхватить сохранённые данные прошлой установки как значения по умолчанию
    if [[ -f "$INSTALL_STATE" ]]; then
        # shellcheck disable=SC1090
        source "$INSTALL_STATE"
        STATE_LOADED=1
        validate_ssh_params
    fi
    main_menu
fi
