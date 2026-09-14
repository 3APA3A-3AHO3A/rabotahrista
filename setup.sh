#!/bin/bash
# ЭТОТ ФАЙЛ СОБРАН АВТОМАТИЧЕСКИ ИЗ lib/*.sh — НЕ РЕДАКТИРУЙТЕ ЕГО ВРУЧНУЮ.
# Правки вносятся в lib/, затем: python3 build.py
# Любое изменение здесь будет затёрто при следующей сборке.
# Собрано из: 00-header.sh, 10-helpers.sh, 20-prompts.sh, 30-state.sh, 40-system.sh, 50-security.sh, 60-node.sh, 70-web.sh, 75-domain.sh, 80-notify.sh, 82-panel.sh, 85-extras.sh, 90-install.sh, 92-repair.sh, 94-check.sh, 95-menu.sh, 99-main.sh

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
# Каталоги nginx и Let's Encrypt — переменными, чтобы тесты могли подставить
# временное дерево и проверить логику выбора домена, ничего не трогая в системе.
NGINX_AVAIL="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
LE_LIVE="/etc/letsencrypt/live"
LE_RENEWAL="/etc/letsencrypt/renewal"
# Метка «этот конфиг nginx писали мы». По ней установщик отличает свой файл от
# чужого сайта, живущего на той же ноде: чужой не перезаписывается без копии и
# никогда не снимается с публикации.
NGINX_MARK="# rabotahrista: конфиг ноды, перезаписывается установщиком"
# Наш дроп-ин с харденингом SSH. Имя начинается с 01, чтобы читаться раньше
# большинства чужих файлов; переменной — чтобы путь был в одном месте и чтобы
# тесты могли подставить свой каталог, не трогая настоящий sshd.
SSH_HARDEN_FILE="/etc/ssh/sshd_config.d/01-hardening.conf"
NODE_PORT="2222"        # порт, на который к ноде ходит панель
WARP_PORT="6000"        # локальный прокси-порт Cloudflare WARP
# Пакеты из apt — один список на установку и на отчёт о версиях
APT_PACKAGES="sudo curl wget unzip git ufw fail2ban python3-systemd socat jq certbot python3-certbot-nginx nginx dnsutils chrony iproute2 iperf3 btop ncdu"
# =================

# RH_LIB_ONLY=1 — загрузить только функции, ничего не выполняя (используется тестами)
if [[ -z "${RH_LIB_ONLY:-}" && "$EUID" -ne 0 ]]; then
    # Подсказываем рабочую команду: "sudo bash <(curl ...)" НЕ работает, потому
    # что sudo закрывает лишние файловые дескрипторы, а <(...) — это как раз он.
    echo "Нужны права root. Скрипт сам отключает вход под root, поэтому запускать так:"
    echo
    echo "  curl -fsSL https://raw.githubusercontent.com/3APA3A-3AHO3A/rabotahrista/main/setup.sh -o /tmp/setup.sh"
    echo "  sudo bash /tmp/setup.sh"
    echo
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
# Без UTF-8 локали bash считает длину строк в байтах — колонки отчёта разъезжаются
if locale -a 2>/dev/null | grep -qix 'C\.UTF-*8'; then export LC_ALL=C.UTF-8; fi

# Диагностика ничего не меняет — значит и лог прошлой установки не затирает
if [[ -z "${RH_LIB_ONLY:-}" && "${1:-}" != "--check" ]]; then
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
        row "Конфиг nginx:" "$NGINX_AVAIL/${FULL_DOMAIN:-—}"
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

    # Домен ноды.
    #
    # Раньше здесь стояло "первый сертификат по алфавиту". На ноде, где живёт
    # ещё один сайт, это выбирало ЧУЖОЙ домен: gateway.example.com сортируется
    # раньше node-nl-1.example.com. Дальше починка переписывала конфиг соседа
    # шаблоном ноды и снимала с публикации настоящий конфиг ноды.
    #
    # Поэтому теперь: берём только то, что можно доказать, а при неоднозначности
    # честно ничего не выбираем и говорим об этом.
    DOMAIN_AMBIGUOUS=""
    if [[ -z "${DOMAIN:-}${SUBDOMAIN:-}" ]]; then
        local cand=() f b
        # Кандидат первого сорта: включённый конфиг nginx, у которого есть
        # собственный сертификат. Это и есть работающий сайт.
        for f in "$NGINX_ENABLED"/*; do
            [[ -e "$f" ]] || continue
            b=$(basename "$f")
            [[ "$b" == "default" || "$b" == "00-acme" ]] && continue
            [[ "$b" == *.*.* && -d "$LE_LIVE/$b" ]] || continue
            cand+=("$b")
        done
        # Ничего не включено — смотрим на выпущенные сертификаты.
        if [[ ${#cand[@]} -eq 0 ]]; then
            for f in "$LE_LIVE"/*/; do
                [[ -d "$f" ]] || continue
                b=$(basename "$f")
                [[ "$b" == *.*.* ]] && cand+=("$b")
            done
        fi
        if [[ ${#cand[@]} -eq 1 ]]; then
            SUBDOMAIN="${cand[0]%%.*}"
            DOMAIN="${cand[0]#*.}"
        elif [[ ${#cand[@]} -gt 1 ]]; then
            DOMAIN_AMBIGUOUS="${cand[*]}"
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
        # Источник истины — наш файл харденинга, а не sshd -T. Чужой дроп-ин с
        # именем раньше по алфавиту (00-*.conf от хостера) перебивает Port, и
        # sshd -T покажет ЕГО порт. Взяв это значение, починка закрепила бы
        # чужие настройки вместо того, чтобы вернуть свои.
        # Именно через if: без файла awk вернёт 2, и set -e убьёт весь скрипт
        # ещё до меню — а файла нет ровно на тех нодах, где харденинга не было.
        v=""
        if [[ -f "$SSH_HARDEN_FILE" ]]; then
            v=$(awk '/^[[:space:]]*Port[[:space:]]/{print $2; exit}' "$SSH_HARDEN_FILE" 2>/dev/null || true)
        fi
        [[ "$v" =~ ^[0-9]+$ ]] || v=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
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
    # Проверяем по ИМЕНИ КОМАНДЫ, а оно не всегда совпадает с именем пакета:
    # у fail2ban исполняемый файл называется fail2ban-client.
    local miss=""
    for pkg in nginx certbot ufw fail2ban-client jq; do
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
        # Согласие на смену пароля уже получено в ask_admin_password
        if [[ "$ADMIN_PASS_SOURCE" == "manual" && -n "$ADMIN_PASS" ]]; then
            echo "$ADMIN_USER:$ADMIN_PASS" | chpasswd
            echo "  Пароль пользователя $ADMIN_USER изменён."
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

# sshd применяет ПЕРВОЕ встреченное значение директивы. Если выше строки
# Include в основном sshd_config уже стоит PermitRootLogin yes (так делают
# образы некоторых хостеров), наш файл харденинга лежит ниже и проигрывает:
# порт меняется, а root и пароли остаются открытыми. Такие строки гасим.
ssh_neutralize_conflicts() {
    local inc_line conflicts n
    inc_line=$(grep -nE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' \
               /etc/ssh/sshd_config 2>/dev/null | head -1 | cut -d: -f1)
    [[ -z "$inc_line" ]] && return 0
    conflicts=$(awk -v n="$inc_line" \
        'NR<n && /^[[:space:]]*(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)[[:space:]]/ {print NR}' \
        /etc/ssh/sshd_config 2>/dev/null)
    if [[ -n "$conflicts" ]]; then
        cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
        for n in $conflicts; do
            sed -i "${n}s|^|# отключено харденингом rabotahrista: |" /etc/ssh/sshd_config
        done
        echo "  Выше Include нашлись строки, перебивавшие харденинг — закомментированы (строки: $(echo $conflicts | tr '\n' ' '))"
    fi

    # Дроп-ины читаются по алфавиту, и тот же принцип «первое значение
    # побеждает» действует между ними. Наш файл называется 01-hardening.conf,
    # значит всё, что сортируется раньше (00-*.conf и подобное), перебивает его.
    local f base
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [[ -e "$f" ]] || continue
        base=$(basename "$f")
        [[ "$base" < "$(basename "$SSH_HARDEN_FILE")" ]] || continue
        grep -qE '^[[:space:]]*(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)[[:space:]]' "$f" || continue
        cp -a "$f" "$f.bak.$(date +%Y%m%d%H%M%S)"
        sed -i -E 's|^([[:space:]]*(PermitRootLogin\|PasswordAuthentication\|KbdInteractiveAuthentication\|ChallengeResponseAuthentication)[[:space:]])|# отключено харденингом rabotahrista: \1|' "$f"
        echo "  $base читается раньше нашего файла и перебивал харденинг — строки закомментированы"
    done
    return 0
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
    cat > "$SSH_HARDEN_FILE" <<EOF
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM yes
EOF
    chmod 644 "$SSH_HARDEN_FILE"
    # Облачные образы включают вход по паролю своими дроп-инами. Наш файл сортируется
    # первым и всё равно выигрывает, но глушим и их — на случай нестандартных имён.
    sed -i 's/^PasswordAuthentication/#PasswordAuthentication/' \
        /etc/ssh/sshd_config.d/*cloudimg*.conf /etc/ssh/sshd_config.d/*cloud-init*.conf 2>/dev/null || true

    ssh_neutralize_conflicts

    sshd -t || {
        echo "  [СБОЙ] sshd -t не прошёл — убираю свой файл, SSH не трогаю"
        rm -f "$SSH_HARDEN_FILE"
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
        # Порт мог быть таким и до нас — это ничего не доказывает. Проверяем
        # то, ради чего всё затевалось: закрыты ли root и вход по паролю.
        local eff_root eff_pass
        eff_root=$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2}')
        eff_pass=$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')
        if [[ "$eff_root" != "no" || "$eff_pass" != "no" ]]; then
            echo "  [СБОЙ] порт применился, но харденинг — нет: root=$eff_root, пароли=$eff_pass"
            echo "         кто задаёт эти значения:"
            grep -rniE '^[[:space:]]*(PermitRootLogin|PasswordAuthentication)' \
                /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | head -5 | sed 's/^/           /'
            SSH_HARDENED=""
            return 1
        fi
        SSH_HARDENED=1; SSH_PENDING_REBOOT=""
        echo "  Проверено: sshd слушает порт $SSH_PORT, root и вход по паролю закрыты."
        return 0
    fi

    # Демон не работает вообще — это авария, откатываемся немедленно
    if ! ssh_daemon_active; then
        echo "  [СБОЙ] служба sshd не запущена после перезапуска. Откатываю харденинг."
        rm -f "$SSH_HARDEN_FILE"
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
    rm -f "$SSH_HARDEN_FILE"
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

# Без группы docker обычный пользователь получает "permission denied" на
# /var/run/docker.sock и вынужден писать sudo перед каждой командой. Прав это
# не добавляет: у админ-учётки и так sudo без пароля — только удобство.
# Вынесено отдельно, потому что на старых нодах Docker уже стоит, и раньше
# comp_docker в этом случае выходил сразу, не дойдя до usermod.
docker_group_member() {
    if [[ -z "${ADMIN_USER:-}" ]] || ! id "$ADMIN_USER" &>/dev/null; then
        return 0
    fi
    if ! getent group docker >/dev/null 2>&1; then
        echo "  Группы docker нет — пропускаю."
        return 0
    fi
    if id -nG "$ADMIN_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        echo "  $ADMIN_USER уже в группе docker."
        return 0
    fi
    usermod -aG docker "$ADMIN_USER"
    echo "  $ADMIN_USER добавлен в группу docker — подхватится в НОВОЙ сессии SSH."
    return 0
}

comp_docker() {
    echo ">>> Установка Docker..."
    if command -v docker >/dev/null 2>&1; then
        echo "  Docker уже установлен."
    else
        curl -fsSL https://get.docker.com | sh >>"$SETUP_LOG" 2>&1
    fi
    docker_group_member
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
    if [[ -d "$LE_LIVE/$FULL_DOMAIN" ]]; then
        echo "  Сертификат для $FULL_DOMAIN уже есть, выпускать не нужно."
    else
        if ! acme_reachable; then
            echo "  [ВНИМАНИЕ] ACME-проверка не дошла до сервера."
            echo "    Проверьте A-запись $FULL_DOMAIN, порт 80 и отдачу"
            echo "    /.well-known/acme-challenge/ в nginx для нового домена."
            if [[ -z "$NONINTERACTIVE" ]]; then
                read -ep "  Пробовать выпустить сертификат всё равно? [y/N]: " TRY || TRY=""
                if [[ ! "$TRY" =~ ^[Yy]$ ]]; then
                    echo "  [СБОЙ] Смена домена отменена, ничего не изменено."
                    return 1
                fi
            fi
        fi
        if ! certbot certonly --webroot -w /var/lib/letsencrypt -d "$FULL_DOMAIN" \
                --register-unsafely-without-email --agree-tos --non-interactive \
                --keep-until-expiring >>"$SETUP_LOG" 2>&1; then
            echo "  [СБОЙ] Certbot не выпустил сертификат для $FULL_DOMAIN (см. $SETUP_LOG)"
            echo "         Нода осталась на прежнем домене, ничего не сломано."
            return 1
        fi
    fi

    # --- конфиг nginx: показываем и ждём подтверждения ---
    nginx_advise "$FULL_DOMAIN"
    local APPLY=""
    if [[ -z "$NONINTERACTIVE" ]]; then
        read -ep "  Записать конфиг нового домена и перезапустить nginx? [y/N]: " APPLY || APPLY=""
    fi
    if [[ ! "$APPLY" =~ ^[Yy]$ ]]; then
        echo "  Конфиг nginx не тронут. Сертификат для $FULL_DOMAIN уже выпущен —"
        echo "  допишите конфиг сами по образцу выше, нода останется на прежнем домене до этого."
        return 0
    fi
    if ! nginx_apply_site "$FULL_DOMAIN"; then
        echo "  [СБОЙ] nginx не принял конфиг нового домена."
        if [[ -n "$old_domain" && -f "$NGINX_AVAIL/$old_domain" ]]; then
            echo "  Возвращаю прежний домен, чтобы нода не осталась без веба..."
            nginx_apply_site "$old_domain" || echo "  [СБОЙ] и прежний конфиг не поднялся — смотрите $SETUP_LOG"
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
    if [[ -n "$old_domain" && -d "$LE_LIVE/$old_domain" && -z "$NONINTERACTIVE" ]]; then
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
    if [[ -n "$old_domain" && -f "$NGINX_AVAIL/$old_domain" && -z "$NONINTERACTIVE" ]]; then
        read -ep "  Удалить старый конфиг nginx $NGINX_AVAIL/$old_domain? [y/N]: " DELCONF || DELCONF=""
        if [[ "$DELCONF" =~ ^[Yy]$ ]]; then
            rm -f "$NGINX_AVAIL/$old_domain"
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
#!/bin/bash
# PATH задан явно: этот скрипт вызывается в том числе из pam_exec, который
# запускает команды с почти пустым окружением. Без PATH не находился бы curl,
# и уведомление о входе по SSH молча не отправлялось.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
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
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
[[ "$PAM_TYPE" != "open_session" ]] && exit 0
# setsid обязателен: PAM дожидается только самого скрипта, а отправку мы уводим
# в фон, чтобы не задерживать вход. Без отвязки от сессии фоновый curl успевали
# убить при зачистке процессов раньше, чем он достучится до Telegram.
setsid /usr/local/bin/rh-notify.sh "🔐 <b>SSH-вход</b>
Пользователь: <code>${PAM_USER}</code>
Откуда IP: <code>${PAM_RHOST}</code>
Время: $(date '+%Y-%m-%d %H:%M:%S %Z')" >/dev/null 2>&1 &
exit 0
SCRIPT
    chmod 755 /usr/local/bin/rh-ssh-login.sh
    # Строку переписываем, а не дописываем: на старых нодах она уже есть в
    # прежнем виде (с seteuid), и простое "добавить, если нет" её не обновит.
    # seteuid убран: notify.env доступен только root, читать его надо от root.
    sed -i '\|rh-ssh-login\.sh|d' /etc/pam.d/sshd
    echo "session optional pam_exec.so /usr/local/bin/rh-ssh-login.sh" >> /etc/pam.d/sshd

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
#!/bin/bash
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
#!/bin/bash
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
        --data-urlencode "text=🖥 <b>${node_label}</b>${node_ip:+  <code>${node_ip}</code>}
✅ Уведомления настроены (SSH-входы, загрузка, падение/подъём ноды)" 2>/dev/null || true)
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
    # Вопросы задаются заранее (ask_panel_watch_params), а не здесь: во время
    # установки скрипт не должен останавливаться и ждать ввода.
    ask_panel_watch_params
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
#!/bin/bash
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

# ===== lib/92-repair.sh ================================================
# ##########################################################################
#  ПОЧИНКА УЖЕ НАСТРОЕННОЙ НОДЫ
#  Один проход без вопросов: sudo bash setup.sh --repair
# ##########################################################################

# Зачем отдельный режим. При обходе парка нод находки повторяются: права на
# файлы с секретами, отсутствие ACME-пути в конфиге nginx, сломанные служебные
# скрипты. Ходить по меню на каждой ноде и вводить домен с токеном руками —
# долго и есть риск опечататься на рабочем сервере.
#
# Режим ничего не переустанавливает: не трогает ufw, не пересоздаёт контейнер,
# не перезагружает сервер. Все ответы берутся с самой ноды.

# Хостеры после ремонта сервера кладут свои дроп-ины в /etc/ssh/sshd_config.d/.
# Имена вида 00-*.conf сортируются раньше нашего 01-hardening.conf, а sshd
# берёт ПЕРВОЕ встреченное значение — и root с паролями снова открыты, хотя
# файл харденинга на месте и порт правильный. Проверяем фактом (sshd -T) и
# трогаем конфиг ТОЛЬКО если он действительно разъехался.
repair_ssh_hardening() {
    local eff_root eff_pass eff_port

    # Впервые харденинг не накатываем: он отключает вход по паролю и требует
    # проверенный SSH-ключ, а это разговор с человеком. Только восстанавливаем.
    if [[ ! -f "$SSH_HARDEN_FILE" ]]; then
        echo "  Харденинг на этой ноде не применялся — пропускаю."
        echo "  Первичная настройка спросит ключ: меню, пункт 2 -> 8."
        return 0
    fi

    eff_root=$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2}')
    eff_pass=$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')
    eff_port=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    if [[ -z "$eff_root$eff_pass" ]]; then
        echo "  [СБОЙ] sshd не отвечает на sshd -T — вслепую чинить SSH опасно."
        return 1
    fi

    if [[ "$eff_root" == "no" && "$eff_pass" == "no" ]] && sshd_listens_on "$SSH_PORT"; then
        echo "  Харденинг на месте: порт $SSH_PORT, root и вход по паролю закрыты. Не трогаю."
        return 0
    fi

    echo "  Харденинг разъехался: root=$eff_root, пароли=$eff_pass, порт в конфиге=${eff_port:-?}"
    echo "  Восстанавливаю на порт $SSH_PORT. Бэкапы конфигов останутся рядом,"
    echo "  при неудаче харденинг откатится, пока текущая сессия жива."
    comp_ssh
}

repair_perms() {
    local rc=0 f
    if [[ -d /opt/remnanode ]]; then
        chmod 700 /opt/remnanode || rc=1
        [[ -f /opt/remnanode/docker-compose.yml ]] && { chmod 600 /opt/remnanode/docker-compose.yml || rc=1; }
    fi
    for f in "$SETUP_LOG" "$INSTALL_STATE" "$NOTIFY_ENV" "$PANEL_ENV" "$REPORT_FILE"; do
        [[ -f "$f" ]] && { chmod 600 "$f" || rc=1; }
    done
    echo "  Права приведены к 600 (каталог ноды — 700)."
    return $rc
}

# Проверка, что служебные скрипты действительно годные: файл без первой строки
# исполняется через /bin/sh, где нет [[ ]], и молча не работает.
repair_verify() {
    local f bad=""
    for f in /usr/local/bin/rh-notify.sh /usr/local/bin/rh-ssh-login.sh \
             /usr/local/bin/rh-node-watch.sh /usr/local/bin/rh-node-health.sh \
             /usr/local/bin/rh-panel-watch.sh; do
        [[ -f "$f" ]] || continue
        head -1 "$f" | grep -q '^#!' || bad+=" $(basename "$f")"
    done
    if [[ -n "$bad" ]]; then
        echo "  [СБОЙ] без первой строки (#!/bin/bash):$bad"
        return 1
    fi
    echo "  Служебные скрипты на месте и начинаются с #!/bin/bash."
    return 0
}

run_repair() {
    echo
    echo "=========================================="
    echo "  ПОЧИНКА УЖЕ НАСТРОЕННОЙ НОДЫ"
    echo "=========================================="
    echo "  Фаервол, контейнер, пакеты и nginx не трогаются, перезагрузки не будет."
    echo "  SSH правится, только если харденинг фактически слетел."
    echo "  По nginx будет только рекомендация — правки там делаете вы."
    echo

    FULL_DOMAIN=""
    [[ -n "${SUBDOMAIN:-}" && -n "${DOMAIN:-}" ]] && FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"
    echo "  Нода:     ${FULL_DOMAIN:-не определена}"
    echo "  Панель:   ${PANEL_IP:-не определена}"
    echo "  Учётка:   ${ADMIN_USER:-?} | порт SSH: ${SSH_PORT:-?}"
    echo "  Telegram: $([[ -n "${TG_BOT_TOKEN:-}" ]] && echo "настроен" || echo "не настроен")"
    echo

    do_step "Права на файлы с секретами" repair_perms
    do_step "Харденинг SSH (root и пароли)" repair_ssh_hardening
    do_step "Группа docker у ${ADMIN_USER:-админа}" docker_group_member

    # nginx автоматическая починка НЕ ТРОГАЕТ. Человек не видит, что именно
    # правится, а на сервере рядом с нодой может жить чужой сайт — однажды
    # починка переписала его конфиг и сняла с публикации конфиг ноды.
    if [[ -n "${DOMAIN_AMBIGUOUS:-}" ]]; then
        echo "  На ноде несколько доменов: $DOMAIN_AMBIGUOUS"
        echo "  Какой из них принадлежит ноде — решать вам."
        skip_step "Конфиг nginx — доменов несколько, разбирайтесь вручную (пункт 2 -> 4)"
    elif [[ -n "$FULL_DOMAIN" ]]; then
        nginx_advise "$FULL_DOMAIN" || true
        skip_step "Конфиг nginx — только рекомендация, ничего не изменено"
    else
        skip_step "Конфиг nginx — домен не определён"
    fi

    if [[ -f "$NOTIFY_ENV" ]]; then
        do_step "Скрипты уведомлений и юниты" comp_telegram
    else
        skip_step "Уведомления — Telegram на этой ноде не настроен (пункт 2 -> 11)"
    fi

    if [[ -f "$PANEL_ENV" ]]; then
        do_step "Сторож панели" comp_panel_watch
    else
        skip_step "Сторож панели — нода не дежурная"
    fi

    do_step "Проверка служебных скриптов" repair_verify

    save_state || true

    echo
    echo "=========================================="
    echo "  ИТОГ ПОЧИНКИ"
    echo "=========================================="
    printf '%s\n' "${SUMMARY[@]}"
    echo "=========================================="
    echo
    echo "Ответы ноды сохранены в $INSTALL_STATE"
    echo "Проверьте результат:   sudo bash /tmp/setup.sh --check"
    echo "Продление сертификата: sudo certbot renew --dry-run"
    return 0
}

# ===== lib/94-check.sh =================================================
# ##########################################################################
#  ДИАГНОСТИКА НОДЫ
#
#  Функция rh_check НИЧЕГО НЕ МЕНЯЕТ — только читает и рассказывает, что нашла.
#  Это сознательное ограничение, и оно проверяется тестом, а не обещанием:
#  диагностику запускают на живой ноде посреди рабочего дня.
#
#  Живёт здесь, а не в отдельном файле, чтобы на сервер приезжал ОДИН скрипт:
#  меню -> «Диагностика», и всё. Из этого же модуля сборщик делает
#  самостоятельный check.sh для тех, кому нужна только проверка.
# ##########################################################################

rhc_ok()   { printf '  \033[32m[ ok ]\033[0m %s\n' "$*"; }
rhc_warn() { printf '  \033[33m[ ?? ]\033[0m %s\n' "$*"; rhc_warnings=$((rhc_warnings+1)); }
rhc_bad()  { printf '  \033[31m[ !! ]\033[0m %s\n' "$*"; rhc_problems=$((rhc_problems+1)); }
rhc_info() { printf '         %s\n' "$*"; }
rhc_sect() { printf '\n\033[1m── %s\033[0m\n' "$*"; }
rhc_fix()  { rhc_fixes+=("$*"); }

# Порты, на которых сейчас слушает SSH. При socket-активации слушателем
# выступает systemd, поэтому его тоже засчитываем.
rhc_ports()     { ss -H -ltnp 2>/dev/null | grep -E 'users:\(\("(sshd|systemd)"' \
                  | awk '{print $4}' | sed 's/.*://' | sort -un; return 0; }
rhc_listening() { ss -H -ltn 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -un; return 0; }
rhc_hasport()   { grep -qx "$1" <<< "$(rhc_listening)"; }
rhc_perm()      { stat -c '%a' "$1" 2>/dev/null || echo "?"; }
# grep -c при нуле совпадений печатает "0" И возвращает ненулевой код.
# Из-за этого "|| echo 0" дописывал второй ноль, получалось "0\n0",
# и арифметическое сравнение падало с syntax error.
rhc_num()       { local v; v=$(printf '%s' "${1:-}" | head -1 | tr -cd '0-9'); echo "${v:-0}"; }

# rh_check [--deep]   — вызывать ТОЛЬКО в подоболочке: ( rh_check )
rh_check() {
    # Диагностика перебирает десятки проверок, половина из которых штатно
    # возвращает ненулевой код. Внутри установщика это поймал бы ERR-трап.
    set +e
    trap - ERR

    local rhc_problems=0 rhc_warnings=0
    local rhc_fixes=()
    local rhc_deep="" rhc_compose="/opt/remnanode/docker-compose.yml"
    [[ "${1:-}" == "--deep" ]] && rhc_deep=1

    if [[ "$EUID" -ne 0 ]]; then
        echo "Нужны права root."
        return 1
    fi

    printf '\033[1m==========================================\n'
    printf '  ДИАГНОСТИКА НОДЫ  —  %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '==========================================\033[0m\n'

    # ----------------------------------------------------------------------
    rhc_sect "Система"
    # ----------------------------------------------------------------------
    rhc_info "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") | ядро $(uname -r)"
    rhc_info "хост $(hostname) | uptime $(uptime -p 2>/dev/null || echo '?')"
    rhc_info "внешний IP: $(curl -fs --max-time 8 https://api.ipify.org 2>/dev/null || echo 'не определился')"

    if [[ -f "$INSTALL_STATE" ]]; then
        rhc_ok "install.conf найден — нода ставилась этим скриптом"
        # shellcheck disable=SC1090
        source "$INSTALL_STATE" 2>/dev/null || true
    else
        # Не проблема: установщик умеет вычитывать настройки с самого сервера,
        # а файл создаётся при первой же правке через меню.
        rhc_info "нет $INSTALL_STATE — нода ставилась ранней версией"
        rhc_info "настройки будут вычитаны с сервера; файл появится после первой правки через меню"
    fi
    local rhc_np="${NODE_PORT:-2222}"

    if [[ -z "$(swapon --show 2>/dev/null)" ]]; then
        rhc_warn "swap не подключён"
        rhc_fix "swap: меню, пункт 2 -> 7"
    else
        rhc_ok "swap: $(swapon --show=SIZE --noheadings 2>/dev/null | tr -d ' \n')"
    fi

    # ----------------------------------------------------------------------
    rhc_sect "SSH"
    # ----------------------------------------------------------------------
    local rhc_inc rhc_hard="$SSH_HARDEN_FILE" rhc_conflict
    rhc_inc=$(grep -nE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' \
              /etc/ssh/sshd_config 2>/dev/null | head -1 | cut -d: -f1)

    if [[ -z "$rhc_inc" ]]; then
        if [[ -f "$rhc_hard" ]]; then
            rhc_bad "файл харденинга есть, но sshd_config его НЕ ЧИТАЕТ — настройки не применены"
            rhc_fix "SSH: меню, пункт 4 (починка) — вернёт Include и перезальёт харденинг"
        else
            rhc_info "sshd_config.d не подключён, и файла харденинга нет"
        fi
    else
        rhc_ok "sshd_config читает каталог sshd_config.d (строка $rhc_inc)"
        # sshd берёт ПЕРВОЕ встреченное значение. Если Include стоит не в начале,
        # директивы выше него побеждают — и харденинг применяется лишь частично.
        rhc_conflict=$(awk -v n="$rhc_inc" \
            'NR<n && /^[[:space:]]*(PermitRootLogin|PasswordAuthentication)[[:space:]]/ {print "    строка "NR": "$0}' \
            /etc/ssh/sshd_config 2>/dev/null)
        if [[ -n "$rhc_conflict" ]]; then
            rhc_bad "выше Include заданы настройки, которые перебивают харденинг:"
            echo "$rhc_conflict"
            rhc_info "sshd берёт первое встреченное значение, поэтому файл харденинга ниже игнорируется"
            rhc_fix "SSH: меню, пункт 4 (починка) — закомментирует эти строки"
        fi
    fi

    # Дроп-ины читаются по алфавиту, и между ними действует тот же принцип.
    # Хостеры кладут файлы вида 00-*.conf — они сортируются раньше нашего.
    local rhc_f rhc_base rhc_early=""
    for rhc_f in /etc/ssh/sshd_config.d/*.conf; do
        [[ -e "$rhc_f" ]] || continue
        rhc_base=$(basename "$rhc_f")
        [[ "$rhc_base" < "$(basename "$SSH_HARDEN_FILE")" ]] || continue
        grep -qE '^[[:space:]]*(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)[[:space:]]' \
             "$rhc_f" || continue
        rhc_early+=" $rhc_base"
    done
    if [[ -n "$rhc_early" ]]; then
        rhc_bad "чужие дроп-ины читаются раньше нашего и перебивают харденинг:$rhc_early"
        rhc_info "такое оставляет хостер после ремонта сервера — настройки возвращаются к своим"
        rhc_fix "SSH: меню, пункт 4 (починка) — закомментирует эти строки и перезапустит sshd"
    fi

    if [[ -f "$rhc_hard" ]]; then
        rhc_ok "файл харденинга на месте"
    else
        rhc_bad "нет $rhc_hard — харденинг SSH на этой ноде не применялся"
        rhc_fix "SSH: меню, пункт 2 -> 8 (первичный харденинг спросит ключ)"
    fi

    local rhc_cfgport rhc_live
    rhc_cfgport=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    rhc_live=$(rhc_ports | tr '\n' ' ')
    rhc_info "порт в конфиге: ${rhc_cfgport:-?} | слушает сейчас: ${rhc_live:-никто}"
    if [[ -n "$rhc_cfgport" ]] && grep -qx "$rhc_cfgport" <<< "$(rhc_ports)"; then
        rhc_ok "sshd слушает тот порт, что указан в конфиге"
    elif [[ -n "$rhc_live" ]]; then
        rhc_warn "порт из конфига не совпадает с рабочим — настройки применятся после перезагрузки"
    else
        rhc_bad "sshd не слушает вообще ничего"
    fi

    local rhc_root rhc_pass
    rhc_root=$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2}')
    rhc_pass=$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')
    if [[ -z "$rhc_root$rhc_pass" ]]; then
        rhc_warn "не удалось прочитать настройки sshd (sshd -T) — sshd не установлен?"
    else
        if [[ "$rhc_root" == "no" ]]; then
            rhc_ok "вход под root запрещён"
        else
            rhc_bad "вход под root разрешён ($rhc_root)"
            rhc_fix "SSH: меню, пункт 4 (починка)"
        fi
        if [[ "$rhc_pass" == "no" ]]; then
            rhc_ok "вход по паролю запрещён"
        else
            rhc_bad "вход по паролю разрешён ($rhc_pass)"
            rhc_fix "SSH: меню, пункт 4 (починка)"
        fi
    fi

    local rhc_home rhc_keys
    if [[ -n "${ADMIN_USER:-}" ]] && id "$ADMIN_USER" &>/dev/null; then
        rhc_home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
        rhc_keys=$(rhc_num "$(grep -cvE '^[[:space:]]*(#|$)' "$rhc_home/.ssh/authorized_keys" 2>/dev/null)")
        if [[ "$rhc_keys" -gt 0 ]]; then
            rhc_ok "у $ADMIN_USER ключей: $rhc_keys"
        else
            rhc_bad "у $ADMIN_USER нет ни одного SSH-ключа"
        fi
    fi

    # ----------------------------------------------------------------------
    rhc_sect "Фаервол"
    # ----------------------------------------------------------------------
    local rhc_p rhc_ipv6
    if ufw status 2>/dev/null | head -1 | grep -q 'active'; then
        rhc_ok "ufw включён"
        for rhc_p in $(rhc_ports); do
            if ufw status 2>/dev/null | grep -qE "(^| )$rhc_p/tcp"; then
                rhc_ok "SSH-порт $rhc_p открыт в ufw"
            else
                rhc_bad "SSH-порт $rhc_p НЕ открыт в ufw — после разрыва сессии не зайти"
                rhc_fix "ufw: ufw limit $rhc_p/tcp"
            fi
        done
        if ufw status 2>/dev/null | grep -q "$rhc_np"; then
            rhc_ok "порт ноды $rhc_np есть в правилах"
        else
            rhc_bad "порт ноды $rhc_np не открыт — панель не достучится"
            rhc_fix "ufw: меню, пункт 2 -> 5"
        fi
        rhc_ipv6=$(grep -E '^IPV6=' /etc/default/ufw 2>/dev/null | cut -d= -f2)
        if [[ -d /proc/sys/net/ipv6 ]]; then
            if [[ "$rhc_ipv6" == "yes" ]]; then
                rhc_ok "IPv6 живой и фильтруется фаерволом"
            else
                rhc_bad "IPv6 активен, но ufw его НЕ фильтрует (IPV6=$rhc_ipv6) — все порты открыты по IPv6"
                rhc_fix "IPv6: меню, пункт 2 -> 5 (перенастроит ufw) либо 10 (выключить IPv6 в GRUB)"
            fi
        else
            rhc_ok "IPv6 отключён в ядре — фильтровать нечего"
        fi
    else
        rhc_bad "ufw выключен"
        rhc_fix "ufw: меню, пункт 2 -> 5"
    fi

    local rhc_banned
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        if fail2ban-client status sshd >/dev/null 2>&1; then
            rhc_banned=$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned/{print $2}' | tr -d ' ')
            rhc_ok "fail2ban работает, джейл sshd активен (забанено сейчас: ${rhc_banned:-0})"
        else
            rhc_bad "fail2ban запущен, но джейл sshd НЕ поднялся — брутфорс никто не блокирует"
            dpkg -l python3-systemd 2>/dev/null | grep -q '^ii' \
                || rhc_fix "fail2ban: меню, пункт 2 -> 12 (доставит python3-systemd)"
        fi
    else
        rhc_bad "fail2ban не запущен"
        rhc_fix "fail2ban: меню, пункт 2 -> 12"
    fi

    # ----------------------------------------------------------------------
    rhc_sect "Нода"
    # ----------------------------------------------------------------------
    local rhc_perms rhc_state rhc_restarts rhc_img
    if [[ -f "$rhc_compose" ]]; then
        rhc_perms=$(rhc_perm "$rhc_compose")
        if [[ "$rhc_perms" == "600" ]]; then
            rhc_ok "docker-compose.yml с правами 600"
        else
            rhc_bad "docker-compose.yml с правами $rhc_perms — SECRET_KEY ноды читает любой пользователь"
            rhc_fix "права: меню, пункт 4 (починка)"
        fi
    else
        rhc_bad "нет $rhc_compose — нода не развёрнута"
    fi

    if command -v docker >/dev/null 2>&1; then
        rhc_state=$(docker inspect -f '{{.State.Status}}' remnanode 2>/dev/null | head -1 | tr -d '\n')
        [[ -z "$rhc_state" ]] && rhc_state="контейнера нет"
        rhc_restarts=$(docker inspect -f '{{.RestartCount}}' remnanode 2>/dev/null || echo "?")
        rhc_img=$(docker inspect -f '{{.Config.Image}}' remnanode 2>/dev/null || echo "?")
        if [[ "$rhc_state" == "running" ]]; then
            rhc_ok "контейнер remnanode: running (перезапусков: $rhc_restarts, образ $rhc_img)"
            [[ "${rhc_restarts:-0}" -gt 5 ]] && rhc_warn "много перезапусков — смотри docker logs remnanode"
        else
            rhc_bad "контейнер remnanode: $rhc_state"
            rhc_fix "нода: меню, пункт 2 -> 3 (передеплой)"
        fi
        if rhc_hasport "$rhc_np"; then
            rhc_ok "порт $rhc_np слушает — панель сможет подключиться"
        else
            rhc_bad "порт $rhc_np не слушает — панель ноду не увидит"
        fi
        # На нодах, где Docker стоял раньше установщика, учётка оставалась вне
        # группы docker: команды работали только через sudo.
        if [[ -n "${ADMIN_USER:-}" ]] && id "$ADMIN_USER" &>/dev/null; then
            if id -nG "$ADMIN_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
                rhc_ok "$ADMIN_USER в группе docker — docker ps работает без sudo"
            else
                rhc_warn "$ADMIN_USER не в группе docker — docker ps ответит permission denied"
                rhc_fix "docker: меню, пункт 4 (починка); применится в новой сессии SSH"
            fi
        fi
    else
        rhc_bad "docker не установлен"
    fi

    # ----------------------------------------------------------------------
    rhc_sect "Сертификат и nginx"
    # ----------------------------------------------------------------------
    local rhc_full rhc_certdir rhc_cn rhc_end rhc_days rhc_ngx rhc_auth rhc_enabled
    rhc_full="${SUBDOMAIN:-}${SUBDOMAIN:+.}${DOMAIN:-}"
    rhc_certdir=$(ls -d "$LE_LIVE"/*/ 2>/dev/null | head -1)
    if [[ -n "$rhc_certdir" ]]; then
        rhc_cn=$(basename "$rhc_certdir")
        rhc_end=$(openssl x509 -enddate -noout -in "$rhc_certdir/fullchain.pem" 2>/dev/null | cut -d= -f2)
        rhc_days=$(( ( $(date -d "$rhc_end" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
        if [[ "$rhc_days" -gt 25 ]]; then
            rhc_ok "сертификат $rhc_cn: осталось $rhc_days дн."
        elif [[ "$rhc_days" -gt 0 ]]; then
            rhc_bad "сертификат $rhc_cn истекает через $rhc_days дн. — продление не сработало"
        else
            rhc_bad "сертификат $rhc_cn ПРОСРОЧЕН"
        fi

        rhc_ngx="$NGINX_AVAIL/${rhc_full:-$rhc_cn}"
        if [[ -f "$rhc_ngx" ]]; then
            if awk '/listen .*8443/,0' "$rhc_ngx" | grep -q 'acme-challenge'; then
                rhc_ok "в TLS-блоке nginx есть путь для ACME — продление по HTTPS пройдёт"
            else
                rhc_bad "в TLS-блоке nginx НЕТ пути для ACME"
                rhc_info "при «Always Use HTTPS» в Cloudflare продление тихо провалится через ~60 дней"
                rhc_fix "сертификат: меню, пункт 4 (починка) — перезапишет конфиг nginx правильно"
            fi
        fi
        rhc_auth=$(awk -F= '/^authenticator/{gsub(/ /,"",$2); print $2; exit}' \
                   "$LE_RENEWAL/$rhc_cn.conf" 2>/dev/null)
        if [[ "$rhc_auth" == "webroot" ]]; then
            rhc_ok "продление через webroot — конфиг nginx при этом не трогается"
        elif [[ -z "$rhc_auth" ]]; then
            rhc_warn "не нашёл настройки продления ($LE_RENEWAL/$rhc_cn.conf)"
        else
            rhc_warn "продление настроено через «$rhc_auth», а не webroot"
            rhc_info "так делали ранние версии установщика: плагин nginx на время проверки"
            rhc_info "сам правит конфиг, а за «Always Use HTTPS» в Cloudflare может не сработать"
            rhc_fix "продление: проверьте пунктом 5 меню (настоящий dry-run), и если красный —"
            rhc_fix "  sudo certbot certonly --webroot -w /var/lib/letsencrypt --cert-name $rhc_cn -d $rhc_cn --keep-until-expiring"
        fi
    else
        rhc_warn "сертификатов Let's Encrypt не найдено"
    fi

    if systemctl is-active --quiet nginx 2>/dev/null; then
        if nginx -t >/dev/null 2>&1; then
            rhc_ok "nginx работает, конфиг валиден"
        else
            rhc_bad "nginx работает, но конфиг невалиден (nginx -t)"
        fi
    else
        rhc_bad "nginx не запущен"
    fi

    # Сайты перечисляем поимённо и отмечаем свои. На ноде может жить ещё один
    # сайт — установщик его не трогает, но знать о нём полезно: именно из-за
    # соседнего домена он однажды выбрал не тот конфиг.
    local rhc_site rhc_name rhc_defs=""
    rhc_enabled=0
    for rhc_site in "$NGINX_ENABLED"/*; do
        [[ -e "$rhc_site" ]] || continue
        rhc_name=$(basename "$rhc_site")
        rhc_enabled=$((rhc_enabled+1))
        if grep -qF "$NGINX_MARK" "$rhc_site" 2>/dev/null; then
            rhc_info "сайт $rhc_name — наш (конфиг ноды)"
        else
            rhc_info "сайт $rhc_name — не наш, установщик его не трогает"
        fi
        grep -qE 'listen[^;]*8443[^;]*default_server' "$rhc_site" 2>/dev/null \
            && rhc_defs+=" $rhc_name"
    done
    if [[ "$rhc_enabled" -eq 0 ]]; then
        rhc_bad "в sites-enabled пусто — nginx ничего не обслуживает"
    fi
    # Их может быть только один на весь nginx, иначе nginx -t падает на duplicate
    if [[ $(wc -w <<< "$rhc_defs") -gt 1 ]]; then
        rhc_bad "default_server на 8443 объявлен больше одного раза:$rhc_defs"
        rhc_fix "nginx: оставить default_server ровно в одном конфиге"
    fi
    # Сертификатов больше одного — значит на ноде живёт ещё домен. Сам по себе
    # это не сбой, но установщик в такой ситуации не должен угадывать.
    local rhc_certs=""
    for rhc_site in "$LE_LIVE"/*/; do
        [[ -d "$rhc_site" ]] && rhc_certs+=" $(basename "$rhc_site")"
    done
    if [[ $(wc -w <<< "$rhc_certs") -gt 1 ]]; then
        rhc_info "сертификатов на ноде несколько: $rhc_certs"
        rhc_info "домен ноды берётся из install.conf — проверьте, что там правильный"
    fi
    if [[ -n "$rhc_full" ]]; then
        if [[ -e "$NGINX_ENABLED/$rhc_full" ]]; then
            rhc_ok "конфиг ноды $rhc_full опубликован"
        else
            rhc_bad "конфиг ноды $rhc_full НЕ опубликован (нет ссылки в sites-enabled)"
            rhc_fix "nginx: ln -sf ${NGINX_AVAIL}/$rhc_full ${NGINX_ENABLED}/"
        fi
    fi

    if [[ -n "$rhc_deep" ]] && command -v certbot >/dev/null 2>&1 && [[ -n "$rhc_certdir" ]]; then
        rhc_info "проверяю продление вживую (certbot --dry-run, до минуты)..."
        if certbot renew --dry-run >/dev/null 2>&1; then
            rhc_ok "тестовое продление прошло — сертификат продлится сам"
        else
            rhc_bad "тестовое продление ПРОВАЛИЛОСЬ — через 90 дней сертификат умрёт"
            rhc_info "подробности: certbot renew --dry-run"
        fi
    fi

    # ----------------------------------------------------------------------
    rhc_sect "Уведомления"
    # ----------------------------------------------------------------------
    local rhc_u rhc_pwip rhc_conns
    if [[ -f "$NOTIFY_ENV" ]]; then
        rhc_perms=$(rhc_perm "$NOTIFY_ENV")
        if [[ "$rhc_perms" == "600" ]]; then
            rhc_ok "notify.env с правами 600"
        else
            rhc_bad "notify.env с правами $rhc_perms — токен бота читает любой"
            rhc_fix "права: меню, пункт 4 (починка)"
        fi
        for rhc_u in rh-node-watch.service rh-node-health.timer; do
            if systemctl is-active --quiet "$rhc_u" 2>/dev/null; then
                rhc_ok "$rhc_u работает"
            else
                rhc_bad "$rhc_u не работает — о падении ноды не узнаете"
                rhc_fix "уведомления: меню, пункт 4 (починка)"
            fi
        done
        # Юнит уведомления о загрузке долго был сломан: systemd съедает %H/%M/%S
        if [[ -f /etc/systemd/system/rh-boot-notify.service ]]; then
            if grep -q '%[HMSZ]' /etc/systemd/system/rh-boot-notify.service \
               && ! grep -q '%%' /etc/systemd/system/rh-boot-notify.service; then
                rhc_bad "юнит rh-boot-notify сломан: неэкранированные %H/%M/%S — о загрузке сервера уведомлений НЕТ"
                rhc_fix "уведомления: меню, пункт 4 (починка) — перепишет юнит правильно"
            elif systemctl is-enabled --quiet rh-boot-notify.service 2>/dev/null; then
                rhc_ok "уведомление о загрузке сервера настроено"
            else
                rhc_warn "rh-boot-notify не включён в автозапуск"
            fi
        else
            rhc_warn "нет юнита уведомления о загрузке сервера"
        fi
        if grep -q 'rh-ssh-login.sh' /etc/pam.d/sshd 2>/dev/null; then
            rhc_ok "уведомление о входе по SSH подключено"
        else
            rhc_warn "уведомление о входе по SSH не подключено"
        fi
        if [[ -f "$PANEL_ENV" ]]; then
            rhc_pwip=$(grep -E '^PANEL_IP=' "$PANEL_ENV" 2>/dev/null | cut -d'"' -f2)
            if systemctl is-active --quiet rh-panel-watch.timer 2>/dev/null; then
                rhc_ok "эта нода дежурная: следит за связью с панелью $rhc_pwip"
            else
                rhc_bad "сторож панели настроен, но таймер не работает"
                rhc_fix "сторож панели: меню, пункт 2 -> 21"
            fi
        else
            rhc_info "эта нода за панелью не следит (сторож включается на одной дежурной, пункт 21)"
        fi
        rhc_conns=$(rhc_num "$(ss -H -tn state established "( sport = :$rhc_np )" 2>/dev/null | grep -c .)")
        if [[ "$rhc_conns" -gt 0 ]]; then
            rhc_ok "панель сейчас держит $rhc_conns соединений с нодой"
        else
            rhc_bad "панель НЕ подключена к этой ноде прямо сейчас"
        fi
    else
        rhc_warn "Telegram-уведомления не настроены — о падении ноды никто не сообщит"
        rhc_fix "уведомления: меню, пункт 2 -> 11"
    fi

    # ----------------------------------------------------------------------
    rhc_sect "Права на файлы с секретами"
    # ----------------------------------------------------------------------
    for rhc_f in "$INSTALL_STATE" "$SETUP_LOG" "$REPORT_FILE"; do
        [[ -f "$rhc_f" ]] || continue
        rhc_perms=$(rhc_perm "$rhc_f")
        if [[ "$rhc_perms" == "600" ]]; then
            rhc_ok "$(basename "$rhc_f"): $rhc_perms"
        else
            rhc_bad "$(basename "$rhc_f"): права $rhc_perms, внутри секреты"
            rhc_fix "права: меню, пункт 4 (починка)"
        fi
    done

    # ----------------------------------------------------------------------
    rhc_sect "Обновления"
    # ----------------------------------------------------------------------
    local rhc_sec
    if command -v unattended-upgrade >/dev/null 2>&1; then
        rhc_ok "автообновления безопасности установлены"
    else
        rhc_warn "unattended-upgrades не установлен"
        rhc_fix "автообновления: меню, пункт 2 -> 13"
    fi
    rhc_sec=$(rhc_num "$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst.*security')")
    if [[ "$rhc_sec" -gt 0 ]]; then
        rhc_warn "ждут установки обновлений безопасности: $rhc_sec"
    else
        rhc_ok "обновления безопасности установлены"
    fi

    # ----------------------------------------------------------------------
    printf '\n\033[1m==========================================\n'
    printf '  ИТОГ: проблем %s, предупреждений %s\n' "$rhc_problems" "$rhc_warnings"
    printf '==========================================\033[0m\n'
    if [[ ${#rhc_fixes[@]} -gt 0 ]]; then
        printf '\nЧто чинить (по убыванию важности):\n'
        printf '  • %s\n' "${rhc_fixes[@]}"
        printf '\nПолную установку заново запускать НЕ НУЖНО: она сбрасывает правила ufw,\n'
        printf 'пересоздаёт контейнер и уходит в перезагрузку. Лечите точечно.\n'
    fi

    [[ "$rhc_problems" -eq 0 ]] && return 0
    return 1
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
    # Ответы, которые человек только что ввёл, надо запомнить: иначе на ноде
    # без install.conf их придётся вводить заново при каждой следующей правке.
    save_state || true
    return 0
}

# Пункт 8 делает два шага подряд — оборачиваем, чтобы тоже шло через menu_step
comp_user_and_ssh() { comp_user && comp_ssh; }

# Диагностика из меню. Обязательно в подоболочке и обязательно внутри "if":
# rh_check штатно возвращает 1, когда нашла проблемы, и снимает себе set -e.
menu_check() {
    if ( rh_check "$@" ); then
        echo
        echo "Проблем не найдено."
    else
        echo
        echo "Найденное чинится пунктом 4 — он сам разберётся, что именно."
    fi
    return 0
}

# Починка из меню. NONINTERACTIVE делаем локальным: внутри вызова компоненты
# не задают вопросов, а после возврата из функции всё как было.
menu_repair() {
    local NONINTERACTIVE=1
    if run_repair; then
        echo
        echo "Проверить результат: пункт 3."
    else
        echo
        echo "Починка завершилась с ошибкой — подробности в $SETUP_LOG"
    fi
    return 0
}

components_menu() {
    while true; do
        echo -e "\n===== Компоненты (доустановить / переустановить) ====="
        echo " 1) Cloudflare WARP        2) Docker          3) Нода (передеплой)"
        echo " 4) Веб: серт + конфиг nginx (покажет и спросит)"
        echo " 5) UFW                    6) Sysctl-тюнинг"
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
             4) menu_step "Веб (серт + конфиг nginx)" comp_web_menu ;;
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
        echo " 1) Полная установка (чистый сервер)"
        echo " 2) Доустановить/переустановить компонент"
        echo " 3) Диагностика — что не так с этой нодой (ничего не меняет)"
        echo " 4) Починка по итогам диагностики"
        echo " 5) Диагностика + реальный тест продления сертификата (до минуты)"
        echo " 0) Выход"
        read -ep "Выбор: " m
        case "$m" in
            1) full_install ;;
            2) components_menu ;;
            3) menu_check ;;
            4) menu_repair ;;
            5) menu_check --deep ;;
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

# Диагностика без меню: тот же код, что в пункте 3. Ничего не меняет.
if [[ "${1:-}" == "--check" ]]; then
    if [[ -f "$INSTALL_STATE" ]]; then
        # shellcheck disable=SC1090
        source "$INSTALL_STATE"
    fi
    # Через "if": rh_check штатно возвращает 1, когда нашла проблемы, и без
    # этого set -e с ERR-трапом напечатали бы поверх отчёта аварийную простыню.
    if ( rh_check "${2:-}" ); then exit 0; else exit 1; fi
fi

# Починка уже настроенной ноды: без вопросов, без переустановки
if [[ "${1:-}" == "--repair" ]]; then
    NONINTERACTIVE=1
    if [[ -f "$INSTALL_STATE" ]]; then
        # shellcheck disable=SC1090
        source "$INSTALL_STATE"
    fi
    detect_existing_setup
    validate_ssh_params
    run_repair
    exit 0
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
    fi
    # Дополняем тем, что можно вычитать с самого сервера. Вызывается всегда:
    # install.conf может существовать, но быть неполным — например, создан
    # ранней версией или после точечной правки через меню.
    detect_existing_setup
    if [[ -z "$STATE_LOADED" && -n "${DOMAIN:-}${PANEL_IP:-}${REMNA_SECRET:-}${TG_BOT_TOKEN:-}" ]]; then
        echo "Файла с ответами нет, но нода настроена — вычитал с сервера:"
        [[ -n "${SUBDOMAIN:-}${DOMAIN:-}" ]] && echo "  домен:    ${SUBDOMAIN}.${DOMAIN}"
        [[ -n "${PANEL_IP:-}" ]]             && echo "  панель:   $PANEL_IP"
        [[ -n "${REMNA_SECRET:-}" ]]         && echo "  секрет:   найден в docker-compose.yml"
        [[ -n "${TG_BOT_TOKEN:-}" ]]         && echo "  Telegram: токен и chat_id найдены"
        echo "  Значения подставлены в вопросы — проверьте их там."
        STATE_LOADED=1
    fi
    validate_ssh_params
    main_menu
fi
