# ##########################################################################
#  ХЕЛПЕРЫ
#  Сводка шагов и печать итогового отчёта
# ##########################################################################

# Запуск шага.
#
# На экране — одна живая строка: кадр спиннера, что делается, сколько идёт.
# Весь вывод шага уходит в $SETUP_LOG: смотреть, как apt перечисляет двести
# пакетов, никому не нужно, а при сбое причина всё равно печатается сразу,
# последними строками — потому что итоговый отчёт очищает экран, и искать её
# потом в логе было бы лишним шагом.
#
# Шаг выполняется в ТЕКУЩЕЙ оболочке, в фоне только анимация. Через конвейер
# (`"$@" | tee`) шаг ушёл бы в подоболочку, и выставленные им переменные —
# пароль учётки, домен, признак применённого харденинга — не дошли бы до отчёта.
rh_step_exec() {
    local label="$1"; shift
    local out rc=0
    out=$(mktemp)
    { echo; echo "=== ШАГ: $label — $(date '+%H:%M:%S') ==="; } >>"$SETUP_LOG" 2>/dev/null || true
    ui_spin_start "$label"
    # stdin от /dev/null: если какой-то шаг всё же задаст вопрос, read получит
    # конец ввода и шаг упадёт с понятной ошибкой. Иначе вопрос ушёл бы в лог,
    # а на экране крутился бы спиннер — установка «висела» бы без объяснений.
    "$@" >"$out" 2>&1 </dev/null || rc=$?
    ui_spin_stop "$rc"
    cat "$out" >>"$SETUP_LOG" 2>/dev/null || true
    if [[ "$rc" -ne 0 ]]; then
        grep -v '^[[:space:]]*$' "$out" 2>/dev/null | tail -12 \
            | sed "s/^/   ${C_DIM}/; s/\$/${C_R}/"
        SUMMARY+=("[СБОЙ]    $label  (см. $SETUP_LOG)")
    else
        SUMMARY+=("[ OK ]    $label")
    fi
    rm -f "$out"
    return "$rc"
}

# do_step "Метка" функция...  — обычный шаг: сбой не роняет установку
do_step() {
    rh_step_exec "$@" || true
    return 0
}

# Шаг, без которого остальное бессмысленно: установка на нём останавливается,
# а не плодит ещё шесть сбоев по одной и той же причине.
do_step_required() {
    rh_step_exec "$@"
}

skip_step() { SUMMARY+=("[проп.]   $1"); }

# Строка отчёта ровной колонкой. Длина метки считается в символах, а не в
# байтах: при кириллице иначе колонки разъезжаются.
row() { ui_kv "$@"; }

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

# Финальный отчёт.
#
# Экран чистим ТОЛЬКО когда всё прошло: при сбоях на нём остались объяснения
# упавших шагов, и стирать их — значит отправить человека искать причину в логе
# ради того, чтобы отчёт выглядел опрятнее.
print_summary() {
    local out node_state fails elapsed
    node_state=$(docker inspect -f '{{.State.Status}} (перезапусков {{.RestartCount}})' remnanode 2>/dev/null | head -1 | tr -d '\r\n')
    [[ -z "$node_state" ]] && node_state="контейнер не найден"
    fails=$(ui_fail_count "${SUMMARY[@]}")
    elapsed=$(ui_mmss $(( SECONDS - ${RH_T0:-0} )))

    if [[ "$fails" -eq 0 && -t 1 ]]; then clear || true; fi

    if [[ "$fails" -eq 0 ]]; then
        ui_title "Нода ${FULL_DOMAIN:-$(hostname)} готова" \
                 "заняло $elapsed · $(date '+%Y-%m-%d %H:%M %Z')"
    else
        ui_title "Установка закончилась с ошибками: $fails" \
                 "заняло $elapsed · подробности выше и в $SETUP_LOG"
    fi

    ui_section "Доступ по SSH"
    ui_kv "команда входа" "ssh -p $SSH_PORT $ADMIN_USER@${FULL_DOMAIN:-${SERVER_IP:-$(hostname)}}"
    ui_kv "учётка" "$ADMIN_USER (sudo без пароля)"
    case "$ADMIN_PASS_SOURCE" in
        manual) ui_kv "пароль учётки" "задан вами вручную (в отчёт не пишу)" ;;
        kept)   ui_kv "пароль учётки" "не менялся — пользователь уже существовал" ;;
        *)      ui_kv "пароль учётки" "${ADMIN_PASS:-—}"
                ui_info "нужен только для аварийной консоли хостера" ;;
    esac
    ui_kv "root и пароли" "вход запрещён"
    if [[ -n "$SSH_PENDING_REBOOT" ]]; then
        ui_warn "порт $SSH_PORT заработает только после перезагрузки"
        ui_info "до неё заходите по старому порту — он открыт в UFW"
    elif [[ -z "$SSH_HARDENED" ]]; then
        ui_err "харденинг SSH не применился — смотрите шаги ниже"
    fi

    ui_section "Нода"
    ui_kv "домен" "${FULL_DOMAIN:-—}"
    ui_kv "IP сервера" "${SERVER_IP:-—}"
    ui_kv "контейнер" "$node_state"
    ui_kv "порт для панели" "$NODE_PORT (только с ${PANEL_IP:-—})"

    ui_section "Фаервол"
    ui_kv "открыто" "${UFW_SSH_PORTS:-$SSH_PORT/tcp} (SSH, rate limit), 80, 443"
    ui_kv "" "$NODE_PORT/tcp только с ${PANEL_IP:-—}"

    ui_section "Шаги"
    ui_summary "${SUMMARY[@]}"

    ui_section "Где что лежит"
    ui_kv "этот отчёт" "$REPORT_FILE"
    ui_kv "полный лог" "$SETUP_LOG"
    ui_kv "ответы установки" "$INSTALL_STATE"
    ui_kv "compose ноды" "/opt/remnanode/docker-compose.yml"
    [[ -f "$NOTIFY_ENV" ]] && ui_kv "telegram" "$NOTIFY_ENV"
    ui_rule

    # В файл — то же самое, но без цвета и с версиями пакетов: его читают
    # глазами через неделю, когда экрана уже нет.
    out=$(
        echo "=== ОТЧЁТ ОБ УСТАНОВКЕ — $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
        echo "Заняло: $elapsed, сбоев: $fails"
        echo
        echo "Вход:            ssh -p $SSH_PORT $ADMIN_USER@${FULL_DOMAIN:-${SERVER_IP:-$(hostname)}}"
        echo "Учётка:          $ADMIN_USER (sudo без пароля)"
        case "$ADMIN_PASS_SOURCE" in
            manual) echo "Пароль учётки:   задан вами вручную" ;;
            kept)   echo "Пароль учётки:   не менялся" ;;
            *)      echo "Пароль учётки:   ${ADMIN_PASS:-—}" ;;
        esac
        echo "Домен:           ${FULL_DOMAIN:-—}"
        echo "IP сервера:      ${SERVER_IP:-—}"
        echo "Порт панели:     $NODE_PORT (только с ${PANEL_IP:-—})"
        echo "UFW:             ${UFW_SSH_PORTS:-$SSH_PORT/tcp}, 80/tcp, 443/tcp"
        echo
        echo "--- ШАГИ ---"
        printf '%s\n' "${SUMMARY[@]}"
        echo
        echo "--- ПАКЕТЫ И ВЕРСИИ ---"
        collect_versions
    )
    printf '%s\n' "$out" > "$REPORT_FILE" 2>/dev/null || true
    chmod 600 "$REPORT_FILE" 2>/dev/null || true
    { echo; printf '%s\n' "$out"; } >> "$SETUP_LOG" 2>&1 || true
    return 0
}
