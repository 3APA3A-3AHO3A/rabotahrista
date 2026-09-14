#!/bin/bash
# Смена домена ноды.
#
# Раньше здесь лежала своя копия логики выпуска сертификата и шаблона nginx.
# Копия успела разойтись с setup.sh: остался certbot --nginx, который
# запускался до создания конфига nginx и потому не находил нужный server_name,
# и проверка DNS по совпадению IP, не работающая за прокси Cloudflare.
#
# Теперь смена домена живёт в setup.sh (пункт 23 меню), а этот файл только
# вызывает её — чтобы старая ссылка продолжала работать.

set -eo pipefail
SETUP_URL="https://raw.githubusercontent.com/3APA3A-3AHO3A/rabotahrista/main/setup.sh"

if [ "$EUID" -ne 0 ]; then
    echo "Запустите под root: sudo bash ..."
    exit 1
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
if ! curl -fsSL "$SETUP_URL" -o "$TMP"; then
    echo "Не удалось скачать setup.sh — проверьте сеть." >&2
    exit 1
fi

# RH_LIB_ONLY=1 — загрузить функции и настройки, не запуская установку
RH_LIB_ONLY=1
# shellcheck disable=SC1090
source "$TMP"
RH_LIB_ONLY=""
NONINTERACTIVE=""

: > "$SETUP_LOG" 2>/dev/null || SETUP_LOG="/tmp/node-setup.log"
chmod 600 "$SETUP_LOG" 2>/dev/null || true

# Подхватываем домен и остальные ответы прошлой установки
if [[ -f "$INSTALL_STATE" ]]; then
    # shellcheck disable=SC1090
    source "$INSTALL_STATE"
fi

comp_change_domain
