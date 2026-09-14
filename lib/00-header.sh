#!/bin/bash
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
