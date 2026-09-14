# ##########################################################################
#  НОДА
#  Docker и контейнер Remnanode
# ##########################################################################

# Точное совпадение порта. Раньше было grep ":$NODE_PORT" — подстрока,
# из-за неё слушатель на 22220 засчитывался за 2222 и нода считалась живой.
port_is_listening() {
    ss -H -ltn 2>/dev/null | awk '{print $4}' | sed 's/.*://' | grep -qx "$1"
}

comp_docker() {
    echo ">>> Установка Docker..."
    if command -v docker >/dev/null 2>&1; then
        echo "  Docker уже установлен."
        return 0
    fi
    curl -fsSL https://get.docker.com | sh >>"$SETUP_LOG" 2>&1
}

node_status() {
    echo "----- Статус ноды -----"
    docker inspect -f 'Контейнер: {{.State.Status}} (running={{.State.Running}}, restarts={{.RestartCount}}, oom={{.State.OOMKilled}})' remnanode 2>/dev/null || echo "Контейнер remnanode не найден."
    if port_is_listening "$NODE_PORT"; then
        echo "Порт $NODE_PORT (API, к нему подключается панель): СЛУШАЕТ — связь с панелью возможна"
    else
        echo "Порт $NODE_PORT (API, к нему подключается панель): НЕ слушает — панель НЕ подключится к ноде"
    fi
    echo "----- Последние 30 строк логов -----"
    docker logs --tail=30 remnanode 2>&1 || echo "Логи недоступны."
}

comp_node() {
    ask_secret
    echo ">>> Разворачивание Remnanode..."
    mkdir -p /opt/remnanode
    chmod 700 /opt/remnanode
    cat <<EOF > /opt/remnanode/docker-compose.yml
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=$NODE_PORT
      - SECRET_KEY="${REMNA_SECRET}"
EOF
    chmod 600 /opt/remnanode/docker-compose.yml   # внутри SECRET_KEY ноды
    if ! ( cd /opt/remnanode && docker compose up -d ) >>"$SETUP_LOG" 2>&1; then
        echo "  [СБОЙ] docker compose up не отработал (см. $SETUP_LOG)"
        node_status
        return 1
    fi
    echo "  Ожидание запуска ноды (порт $NODE_PORT, до 30 сек)..."
    local i up=""
    for i in $(seq 1 30); do
        if port_is_listening "$NODE_PORT"; then up=1; break; fi
        sleep 1
    done
    node_status
    if [[ -z "$up" ]]; then
        echo "  [СБОЙ] нода не начала слушать порт $NODE_PORT — панель её не увидит"
        return 1
    fi
    return 0
}

comp_node_update() {
    echo ">>> Обновление ноды Remnanode..."
    if [[ -f /opt/remnanode/docker-compose.yml ]]; then
        if ! ( cd /opt/remnanode && docker compose pull && docker compose up -d ) >>"$SETUP_LOG" 2>&1; then
            echo "  [СБОЙ] обновление не прошло (см. $SETUP_LOG)"
            node_status
            notify_telegram "❌ Нода <code>$(hostname)</code>: обновление НЕ удалось ($(date '+%H:%M:%S'))"
            return 1
        fi
        node_status
        notify_telegram "⬆️ Нода <code>$(hostname)</code> обновлена ($(date '+%H:%M:%S'))"
    else
        echo "  Нода не установлена (/opt/remnanode/docker-compose.yml не найден)."
        return 1
    fi
}
