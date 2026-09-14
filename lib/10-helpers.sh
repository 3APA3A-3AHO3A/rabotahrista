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
