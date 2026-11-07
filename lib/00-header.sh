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
# Откуда скачивать сам установщик. Нужен, когда он запущен через bash <(curl ...):
# такой «файл» — временный канал, и перезапустить себя внутри tmux по нему нельзя.
SETUP_URL="https://raw.githubusercontent.com/3APA3A-3AHO3A/rabotahrista/main/setup.sh"
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
# Признаки выключенного IPv6: стека нет в ядре или флаг уже стоит в GRUB
RH_IPV6_PROC="/proc/sys/net/ipv6"
RH_GRUB_DEFAULT="/etc/default/grub"
# Копии того, что скрипт удаляет. Не в каталогах nginx: оттуда он читает всё подряд
RH_BACKUP_DIR="/etc/rabotahrista/backup"
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
PSIPHON_PORT="1080"     # SOCKS5 Psiphon (vps-psiphon), им пользуется Xray ноды
# Сторонние установщики выходов — прямо из их репозиториев на GitHub
WARP_NATIVE_URL="https://raw.githubusercontent.com/distillium/warp-native/main/install.sh"
PSIPHON_URL="https://raw.githubusercontent.com/Chara-Freedom/vps-psiphon/main/psiphon_install.sh"
# Geo-базы для Xray внутри ноды (Loyalsoldier) и их ежедневное обновление
GEODATA_DIR="/opt/remnanode/geodata"
GEODATA_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
GEODATA_BIN="/usr/local/bin/rh-geodata-update.sh"
GEODATA_CRON="/etc/cron.d/rh-geodata"
# Группа, по которой скрипт узнаёт учётки ИИ-агентов (Claude и др. через MCP):
# по ней уведомление о входе пишет «вход ИИ-агента», а не обычный вход.
AGENT_GROUP="rh-agents"
# apt с версии 2.0 умеет сам ждать освобождения блокировки dpkg. Без этого на
# свежем сервере установщик встречался с первым после загрузки
# unattended-upgrades, падал на первой же команде — и за ним рушилось всё,
# что зависит от пакетов: нода, сертификат, fail2ban, docker.
# confdef/confold: если файл настроек пакета менялся (sshd_config, например),
# dpkg не спрашивает «чей оставить», а оставляет наш. Без этого обновление
# без терминала падало на вопросе, на который некому ответить.
APT_WAIT=(-o DPkg::Lock::Timeout=600
          -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
# Пакеты из apt — один список на установку и на отчёт о версиях
APT_PACKAGES="sudo curl wget unzip git tmux cron ufw fail2ban python3-systemd socat jq certbot python3-certbot-nginx nginx dnsutils chrony iproute2 iperf3 btop ncdu"
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
