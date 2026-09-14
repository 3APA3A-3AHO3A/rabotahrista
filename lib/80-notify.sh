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
[[ "$PAM_TYPE" != "open_session" ]] && exit 0
/usr/local/bin/rh-notify.sh "🔐 <b>SSH-вход</b>
Пользователь: <code>${PAM_USER}</code>
Откуда IP: <code>${PAM_RHOST}</code>
Время: $(date '+%Y-%m-%d %H:%M:%S %Z')" &
exit 0
SCRIPT
    chmod 755 /usr/local/bin/rh-ssh-login.sh
    grep -q "rh-ssh-login.sh" /etc/pam.d/sshd || \
        echo "session optional pam_exec.so seteuid /usr/local/bin/rh-ssh-login.sh" >> /etc/pam.d/sshd

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
        --data-urlencode "text=✅ Уведомления настроены (SSH-входы, загрузка, падение/подъём ноды)" 2>/dev/null || true)
    if grep -q '"ok":true' <<< "$resp"; then
        echo "  Тестовое сообщение доставлено в Telegram."
        return 0
    fi
    echo "  [СБОЙ] Telegram не принял сообщение. Ответ API:"
    echo "    $(head -c 300 <<< "${resp:-пустой ответ}")"
    echo "    Проверьте BOT_TOKEN, CHAT_ID и что бот добавлен в группу."
    return 1
}
