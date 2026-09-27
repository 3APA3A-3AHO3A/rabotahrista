# ##########################################################################
#  СПИННЕР
#
#  Отдельным модулем от остального оформления по одной причине: он создаёт
#  временный файл для живой подписи, а из lib/05-ui.sh собирается ещё и
#  check.sh, который обязан не писать на диск вообще ничего. Тест это проверяет,
#  и правильный ответ на его замечание — разделить модули, а не ослабить тест.
# ##########################################################################

RH_SPIN_PID=""
RH_SPIN_LABEL=""
RH_SPIN_T0=0
# Метка живёт в файле, а не в переменной: анимация крутится в подоболочке и
# изменения переменных родителя не видит. Через файл шаг может рассказывать,
# что он делает прямо сейчас, — иначе двухминутная проверка выглядит зависанием.
RH_SPIN_FILE=""

ui_mmss() { printf '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); return 0; }

ui_spin_start() {
    RH_SPIN_LABEL="$1"
    RH_SPIN_T0=$SECONDS
    RH_SPIN_FILE=$(mktemp 2>/dev/null || echo "")
    [[ -n "$RH_SPIN_FILE" ]] && printf '%s' "$1" > "$RH_SPIN_FILE"
    if [[ -z "$RH_TTY" ]]; then
        printf '  %s  %s\n' "$S_DOT" "$1"
        return 0
    fi
    (
        local i=0 el lbl="$RH_SPIN_LABEL"
        while :; do
            el=$(( SECONDS - RH_SPIN_T0 ))
            [[ -n "$RH_SPIN_FILE" ]] && lbl=$(cat "$RH_SPIN_FILE" 2>/dev/null || printf '%s' "$lbl")
            printf '\r\033[K  %s%s%s  %s %s%5s%s' \
                "$C_ACC" "${RH_FRAMES[i % ${#RH_FRAMES[@]}]}" "$C_R" \
                "$(ui_fit "$lbl" 42)" "$C_DIM" "$(ui_mmss "$el")" "$C_R"
            i=$(( i + 1 ))
            sleep 0.12
        done
    ) &
    RH_SPIN_PID=$!
    return 0
}

# Шаг рассказывает, чем занят сейчас. Без спиннера — тихо, чтобы не сорить
# в лог и не мешать подробному выводу в меню.
ui_step_status() {
    [[ -n "$RH_SPIN_FILE" ]] && printf '%s' "$1" > "$RH_SPIN_FILE" 2>/dev/null
    return 0
}

# ui_spin_stop <код> — снимает анимацию и печатает итог той же строкой
ui_spin_stop() {
    local rc="${1:-0}" el mark col
    el=$(( SECONDS - RH_SPIN_T0 ))
    if [[ -n "$RH_SPIN_PID" ]]; then
        kill "$RH_SPIN_PID" 2>/dev/null || true
        wait "$RH_SPIN_PID" 2>/dev/null || true
        RH_SPIN_PID=""
    fi
    [[ -n "$RH_SPIN_FILE" ]] && { rm -f "$RH_SPIN_FILE"; RH_SPIN_FILE=""; }
    if [[ "$rc" -eq 0 ]]; then mark="$S_OK"; col="$C_OK"; else mark="$S_ERR"; col="$C_ERR"; fi
    if [[ -n "$RH_TTY" ]]; then
        printf '\r\033[K  %s%s%s  %s %s%5s%s\n' \
            "$col" "$mark" "$C_R" "$(ui_fit "$RH_SPIN_LABEL" 42)" "$C_DIM" "$(ui_mmss "$el")" "$C_R"
    else
        printf '  %s  %s  (%s)\n' "$mark" "$RH_SPIN_LABEL" "$(ui_mmss "$el")"
    fi
    return 0
}
