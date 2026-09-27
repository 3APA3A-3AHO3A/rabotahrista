# ##########################################################################
#  ПРОВЕРКИ ПЕРЕД СТАРТОМ И УСТОЙЧИВОСТЬ К ОБРЫВУ СВЯЗИ
#
#  Два разных урока, оба с живых нод.
#
#  Первый: на только что созданном сервере cloud-init ещё дорабатывает и держит
#  apt первым автообновлением. Установщик падал на первой же команде, а за ним
#  сыпалось всё, что зависит от пакетов. Лечится ожиданием, а не спешкой.
#
#  Второй: установка идёт минуты, а ssh рвётся. Если процесс висит на терминале,
#  обрыв уносит установку на середине — пакеты доставлены, нода нет, sshd уже
#  перезапущен на новом порту. Поэтому работаем внутри tmux: сессия переживает
#  обрыв, и к ней можно вернуться.
# ##########################################################################

RH_SESSION="rabotahrista"
RH_LOCK="/run/rabotahrista.lock"


# Ждём чужой apt. Молча ждать нельзя: человек должен понимать, почему пауза.
rh_wait_apt() {
    local max="${1:-600}" waited=0
    rh_apt_busy || return 0
    ui_spin_start "Ждём чужой apt (автообновление сервера)"
    while rh_apt_busy && [[ "$waited" -lt "$max" ]]; do
        ui_step_status "Ждём чужой apt — $(apt_busy_who | head -1 | cut -c1-40)"
        sleep 3
        waited=$(( waited + 3 ))
    done
    if rh_apt_busy; then
        ui_spin_stop 1
        ui_info "apt занят уже $(ui_mmss "$waited") — дальше пойдём с ожиданием блокировки"
        return 1
    fi
    ui_spin_stop 0
    return 0
}

# cloud-init на облачных образах сам ставит обновления при первой загрузке.
# Дождаться его — самый честный способ не драться с ним за dpkg.
rh_wait_cloud_init() {
    command -v cloud-init >/dev/null 2>&1 || return 0
    cloud-init status 2>/dev/null | grep -q 'status: done' && return 0
    ui_spin_start "Ждём cloud-init (первичная настройка сервера)"
    timeout 420 cloud-init status --wait >/dev/null 2>&1 || true
    ui_spin_stop 0
    return 0
}

# Проверки, после которых понятно, можно ли вообще начинать.
# Только читает: ничего не ставит и не правит.
rh_preflight() {
    local rc=0 v
    ui_section "Проверка сервера"

    if ! command -v apt-get >/dev/null 2>&1; then
        ui_err "нет apt-get — скрипт рассчитан на Debian/Ubuntu"
        return 1
    fi
    ui_ok "система: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") | ядро $(uname -r)"

    # Диск. Docker с образом ноды и пакеты — это единицы гигабайт.
    v=$(df -BM --output=avail / 2>/dev/null | tail -1 | tr -cd '0-9')
    v="${v:-0}"
    if [[ "$v" -lt 2048 ]]; then
        ui_err "на / свободно ${v} МБ — этого не хватит даже на пакеты"
        rc=1
    elif [[ "$v" -lt 5120 ]]; then
        ui_warn "на / свободно ${v} МБ — впритык, образ ноды и логи могут упереться"
    else
        ui_ok "на / свободно ${v} МБ"
    fi

    v=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    v="${v:-0}"
    if [[ "$v" -lt 700 ]]; then
        ui_warn "памяти ${v} МБ — мало, но swap 2 ГБ скрипт создаст сам"
    else
        ui_ok "памяти ${v} МБ"
    fi

    if getent hosts archive.ubuntu.com >/dev/null 2>&1 \
       || getent hosts deb.debian.org >/dev/null 2>&1; then
        ui_ok "DNS и сеть отвечают"
    else
        ui_err "не резолвятся репозитории — без сети ставить нечего"
        rc=1
    fi

    if command -v sshd >/dev/null 2>&1; then
        ui_ok "sshd на месте"
    else
        ui_warn "sshd не найден — харденинг SSH будет нечего настраивать"
    fi

    # Съехавшие часы — это провал выпуска сертификата с невнятной ошибкой
    v=$(date +%Y)
    if [[ "$v" -lt 2024 ]]; then
        ui_warn "часы показывают $v год — Let's Encrypt откажет, поправьте время"
    fi

    rh_wait_cloud_init
    rh_wait_apt 600 || true

    if [[ "$rc" -ne 0 ]]; then
        ui_note ""
        ui_err "Сервер к установке не готов — смотрите строки выше."
        return 1
    fi
    return 0
}

# ##########################################################################
#  Один запуск на сервер и жизнь после обрыва ssh
# ##########################################################################

# Второй установщик на том же сервере — это два apt, два перезапуска sshd и
# гонка за одни и те же файлы. Пускаем ровно один.
rh_take_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    # Фигурные скобки обязательны. «exec 9>файл 2>/dev/null» без них значит не
    # «открой файл, скрыв ошибку», а «отправь stderr всего скрипта в никуда
    # навсегда» — и пропадают все приглашения read (bash пишет их в stderr) и
    # аварийные сообщения. Так и было, проверено.
    { exec 9>"$RH_LOCK"; } 2>/dev/null || return 0
    if ! flock -n 9; then
        echo
        echo "  На этом сервере уже работает другой запуск установщика."
        echo "  Если он идёт в отключённой сессии — подключитесь к ней:"
        echo "      sudo tmux attach -t $RH_SESSION"
        echo "  Если это остаток от оборвавшегося запуска — проверьте: pgrep -a setup.sh"
        echo
        exit 1
    fi
    return 0
}

rh_in_multiplexer() {
    [[ -n "${TMUX:-}" || -n "${STY:-}" ]] && return 0
    return 1
}

# Перезапуск себя внутри tmux. Вопросы при этом работают как обычно — это
# тот же терминал, просто пережимающий обрыв связи.
rh_session_guard() {
    [[ -n "${RH_LIB_ONLY:-}" || -n "${RH_NO_TMUX:-}" ]] && return 0
    [[ -t 0 && -t 1 ]] || return 0
    rh_in_multiplexer && return 0
    # На «тупом» терминале tmux не запустится, а exec уже заменил бы процесс —
    # и установка не началась бы вовсе. Лучше без tmux, чем никак.
    [[ -n "${TERM:-}" && "${TERM:-}" != "dumb" ]] || return 0

    if ! command -v tmux >/dev/null 2>&1; then
        # Короткий таймаут: ждать десять минут ради tmux бессмысленно,
        # без него установка тоже пройдёт — просто менее живучей.
        ui_info "ставлю tmux, чтобы установка пережила обрыв ssh (до минуты)..."
        apt-get -o DPkg::Lock::Timeout=30 install -y tmux >/dev/null 2>&1 \
            || { apt-get -o DPkg::Lock::Timeout=30 update -qq >/dev/null 2>&1 \
                 && apt-get -o DPkg::Lock::Timeout=30 install -y tmux >/dev/null 2>&1; } \
            || true
    fi
    if ! command -v tmux >/dev/null 2>&1; then
        ui_warn "tmux поставить не удалось — установка не переживёт обрыв ssh"
        ui_info "не закрывайте окно до конца установки"
        return 0
    fi

    local cmd a
    cmd="bash $(printf '%q' "$0")"
    for a in "$@"; do cmd+=" $(printf '%q' "$a")"; done
    # После выхода скрипта окно не закрываем: иначе итоговый отчёт с паролем
    # учётки мелькнёт и исчезнет вместе с сессией.
    cmd+='; printf "\n  Готово. Enter — закрыть окно. "; read -r _'

    ui_title "Работаю внутри tmux" "если ssh оборвётся: sudo tmux attach -t $RH_SESSION"
    sleep 2
    exec tmux new-session -A -s "$RH_SESSION" "$cmd"
}
