# ##########################################################################
#  НОДА
#  Docker и контейнер Remnanode
# ##########################################################################

# Точное совпадение порта. Раньше было grep ":$NODE_PORT" — подстрока,
# из-за неё слушатель на 22220 засчитывался за 2222 и нода считалась живой.
port_is_listening() {
    ss -H -ltn 2>/dev/null | awk '{print $4}' | sed 's/.*://' | grep -qx "$1"
}

# Без группы docker обычный пользователь получает "permission denied" на
# /var/run/docker.sock и вынужден писать sudo перед каждой командой. Прав это
# не добавляет: у админ-учётки и так sudo без пароля — только удобство.
# Вынесено отдельно, потому что на старых нодах Docker уже стоит, и раньше
# comp_docker в этом случае выходил сразу, не дойдя до usermod.
docker_group_member() {
    if [[ -z "${ADMIN_USER:-}" ]] || ! id "$ADMIN_USER" &>/dev/null; then
        return 0
    fi
    if ! getent group docker >/dev/null 2>&1; then
        echo "  Группы docker нет — пропускаю."
        return 0
    fi
    if id -nG "$ADMIN_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        echo "  $ADMIN_USER уже в группе docker."
        return 0
    fi
    usermod -aG docker "$ADMIN_USER"
    echo "  $ADMIN_USER добавлен в группу docker — подхватится в НОВОЙ сессии SSH."
    return 0
}

# Каталог ноды: 750 и группа docker. Заходить в него и смотреть geo-базы могут
# админ-учётка и агент (оба в группе docker), а сам docker-compose.yml с
# SECRET_KEY остаётся 600 — секрет защищён на уровне файла. Раньше каталог был
# 700, и даже своя учётка упиралась в Permission denied. Прав это не добавляет:
# участник группы docker и так фактически root. Владельца не трогаем — если вы
# сделали владельцем себя, так и останется.
node_dir_perms() {
    [[ -d /opt/remnanode ]] || return 0
    getent group docker >/dev/null 2>&1 && chgrp docker /opt/remnanode
    chmod 750 /opt/remnanode
    [[ -f /opt/remnanode/docker-compose.yml ]] && chmod 600 /opt/remnanode/docker-compose.yml
    return 0
}

comp_docker() {
    echo ">>> Установка Docker..."
    if command -v docker >/dev/null 2>&1; then
        echo "  Docker уже установлен."
    else
        ui_step_status "Docker: ставлю с get.docker.com"
        curl -fsSL https://get.docker.com | sh >>"$SETUP_LOG" 2>&1 || true
    fi
    # Проверяем фактом. Скрипт get.docker.com ставит пакеты через apt и при
    # занятой блокировке возвращает успех, ничего не установив: шаг светился
    # зелёным, а следом «docker: command not found» и нода не разворачивалась.
    if ! command -v docker >/dev/null 2>&1; then
        echo "  [СБОЙ] docker не установился (см. $SETUP_LOG)"
        return 1
    fi
    systemctl enable --now docker >>"$SETUP_LOG" 2>&1 || true
    if ! docker info >/dev/null 2>&1; then
        echo "  [СБОЙ] docker установлен, но демон не отвечает (см. $SETUP_LOG)"
        return 1
    fi
    docker_group_member
    local a
    for a in $(getent group "$AGENT_GROUP" 2>/dev/null | cut -d: -f4 | tr ',' ' '); do
        id -nG "$a" | tr ' ' '\n' | grep -qx docker || usermod -aG docker "$a"
    done
    return 0
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
    validate_node_version
    echo ">>> Разворачивание Remnanode..."
    mkdir -p /opt/remnanode
    cat <<EOF > /opt/remnanode/docker-compose.yml
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:$REMNANODE_VERSION
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
    # Свои geo-базы подключаем, только если они уже скачаны: том на
    # несуществующий файл docker создал бы каталогом, и Xray не стартовал бы.
    if geodata_present; then
        cat <<EOF >> /opt/remnanode/docker-compose.yml
    volumes:
      - $GEODATA_DIR/geoip.dat:/usr/local/share/xray/geoip.dat:ro
      - $GEODATA_DIR/geosite.dat:/usr/local/share/xray/geosite.dat:ro
EOF
        echo "  Подключены geo-базы из $GEODATA_DIR"
    fi
    node_dir_perms   # compose — 600 (внутри SECRET_KEY), каталог — 750 с группой docker
    if ! ( cd /opt/remnanode && docker compose up -d ) >>"$SETUP_LOG" 2>&1; then
        echo "  [СБОЙ] docker compose up не отработал (см. $SETUP_LOG)"
        node_status
        return 1
    fi
    echo "  Ожидание запуска ноды (порт $NODE_PORT, до 30 сек)..."
    local i up=""
    for i in $(seq 1 30); do
        ui_step_status "Нода: жду порт $NODE_PORT ($i/30)"
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
        # Обновляется ровно тот тег, что записан в compose: закреплённая версия
        # так и останется, сменить её — пункт «Нода (передеплой)»
        grep -m1 -E '^[[:space:]]*image:' /opt/remnanode/docker-compose.yml | sed 's/^[[:space:]]*/  Образ: /' 
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
