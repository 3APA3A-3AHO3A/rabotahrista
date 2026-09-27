# ##########################################################################
#  ОФОРМЛЕНИЕ
#  Палитра, заголовки, строки-состояния и спиннер с таймером.
#
#  Зачем отдельный модуль: до него каждый шаг печатал ANSI-коды прямо в тексте,
#  и вывод выглядел по-разному в установке, диагностике и починке. Здесь один
#  набор примитивов на всё, и он сам решает, можно ли красить.
#
#  Красим только если вывод действительно в терминал. При перенаправлении в
#  файл или в конвейер (`| tee`, `> log`) escape-последовательности превратили
#  бы лог в мусор, поэтому там все C_* пустые, а спиннер печатает одну строку.
#  Уважается общепринятая переменная NO_COLOR.
# ##########################################################################

RH_TTY=""
[[ -t 1 ]] && RH_TTY=1

# UTF-8 нужен для рамок и кадров спиннера. Без него — ASCII, но всё читается.
RH_UTF=""
case "${LC_ALL:-}${LC_CTYPE:-}${LANG:-}" in *[Uu][Tt][Ff]*) RH_UTF=1 ;; esac

if [[ -n "$RH_TTY" && -z "${NO_COLOR:-}" && -z "${RH_NO_COLOR:-}" ]]; then
    # 256 цветов там, где они есть: приглушённые оттенки читаются лучше базовых
    if [[ "$(tput colors 2>/dev/null || echo 8)" -ge 256 ]]; then
        C_ACC=$'\033[38;5;80m'    # бирюзовый — акцент, заголовки, активный шаг
        C_OK=$'\033[38;5;78m'     # зелёный
        C_WARN=$'\033[38;5;179m'  # песочный
        C_ERR=$'\033[38;5;203m'   # коралловый
        C_DIM=$'\033[38;5;245m'   # серый — второстепенное
    else
        C_ACC=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'
        C_ERR=$'\033[31m'; C_DIM=$'\033[90m'
    fi
    C_B=$'\033[1m'; C_R=$'\033[0m'
else
    C_ACC=""; C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_B=""; C_R=""
fi

# Символы состояния и рамок
if [[ -n "$RH_UTF" ]]; then
    S_OK="✓"; S_ERR="✗"; S_WARN="!"; S_SKIP="–"; S_DOT="•"; S_H="─"
    RH_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
else
    S_OK="OK"; S_ERR="XX"; S_WARN="!!"; S_SKIP="--"; S_DOT="*"; S_H="-"
    RH_FRAMES=('|' '/' '-' '\')
fi

# Ширина: узкий терминал не растягиваем, широкий не распускаем до края
ui_width() {
    local w="${COLUMNS:-0}"
    [[ "$w" -lt 20 ]] && w=$(tput cols 2>/dev/null || echo 78)
    [[ "$w" -lt 52 ]] && w=52
    [[ "$w" -gt 76 ]] && w=76
    echo "$w"
}

# Подгонка строки под ширину колонки ПО СИМВОЛАМ.
# printf считает точность (%-42.42s) в байтах, а кириллица двухбайтовая —
# метка обрезалась по середине буквы и превращалась в «обновляю списо?».
ui_fit() {
    local s="$1" n="$2" pad
    if [[ "${#s}" -gt "$n" ]]; then
        s="${s:0:n-1}…"
    fi
    pad=$(( n - ${#s} ))
    printf '%s' "$s"
    (( pad > 0 )) && printf '%*s' "$pad" ''
    return 0
}

ui_rule() {
    local w; w=$(ui_width); local line=""
    while [[ "${#line}" -lt "$w" ]]; do line+="$S_H"; done
    printf '%s%s%s\n' "$C_DIM" "$line" "$C_R"
    return 0
}

# Шапка: заголовок между двумя линиями, с необязательным подзаголовком
ui_title() {
    echo
    ui_rule
    printf '%s%s  %s%s\n' "$C_B" "$C_ACC" "$1" "$C_R"
    [[ -n "${2:-}" ]] && printf '%s  %s%s\n' "$C_DIM" "$2" "$C_R"
    ui_rule
    return 0
}

ui_section() { printf '\n%s%s%s %s%s\n' "$C_B" "$C_ACC" "$S_DOT" "$1" "$C_R"; return 0; }

ui_ok()   { printf '  %s%s%s  %s\n' "$C_OK"   "$S_OK"   "$C_R" "$*"; return 0; }
ui_err()  { printf '  %s%s%s  %s\n' "$C_ERR"  "$S_ERR"  "$C_R" "$*"; return 0; }
ui_warn() { printf '  %s%s%s  %s\n' "$C_WARN" "$S_WARN" "$C_R" "$*"; return 0; }
ui_skip() { printf '  %s%s  %s%s\n' "$C_DIM"  "$S_SKIP" "$*" "$C_R"; return 0; }
ui_info() { printf '     %s%s%s\n' "$C_DIM" "$*" "$C_R"; return 0; }
ui_note() { printf '  %s\n' "$*"; return 0; }

# Ключ-значение ровной колонкой. Длина считается в символах, а не байтах —
# при кириллице иначе колонки разъезжаются.
ui_kv() {
    local key="$1"; shift
    local pad=$(( 22 - ${#key} )); (( pad < 1 )) && pad=1
    printf '  %s%s%s%*s%s\n' "$C_DIM" "$key" "$C_R" "$pad" "" "$*"
    return 0
}

# Печать сводки шагов. SUMMARY хранит текстовые метки «[ OK ]» / «[СБОЙ]» /
# «[проп.]» — они же уходят в файл отчёта, а на экран рисуем значками.
ui_summary() {
    local line rest
    for line in "$@"; do
        rest="${line#*]}"
        while [[ "$rest" == " "* ]]; do rest="${rest# }"; done
        case "$line" in
            '[ OK ]'*) printf '  %s%s%s  %s\n' "$C_OK"  "$S_OK"   "$C_R" "$rest" ;;
            '[СБОЙ]'*) printf '  %s%s%s  %s\n' "$C_ERR" "$S_ERR"  "$C_R" "$rest" ;;
            *)         printf '  %s%s  %s%s\n' "$C_DIM" "$S_SKIP" "$rest" "$C_R" ;;
        esac
    done
    return 0
}

# Сколько шагов упало
ui_fail_count() {
    local line n=0
    for line in "$@"; do
        [[ "$line" == '[СБОЙ]'* ]] && n=$(( n + 1 ))
    done
    echo "$n"
    return 0
}
