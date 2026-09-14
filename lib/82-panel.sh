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
