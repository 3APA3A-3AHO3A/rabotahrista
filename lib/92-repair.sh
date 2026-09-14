# ##########################################################################
#  ПОЧИНКА УЖЕ НАСТРОЕННОЙ НОДЫ
#  Один проход без вопросов: sudo bash setup.sh --repair
# ##########################################################################

# Зачем отдельный режим. При обходе парка нод находки повторяются: права на
# файлы с секретами, отсутствие ACME-пути в конфиге nginx, сломанные служебные
# скрипты. Ходить по меню на каждой ноде и вводить домен с токеном руками —
# долго и есть риск опечататься на рабочем сервере.
#
# Режим ничего не переустанавливает: не трогает ufw, не пересоздаёт контейнер,
# не перезагружает сервер. Все ответы берутся с самой ноды.

repair_perms() {
    local rc=0 f
    if [[ -d /opt/remnanode ]]; then
        chmod 700 /opt/remnanode || rc=1
        [[ -f /opt/remnanode/docker-compose.yml ]] && { chmod 600 /opt/remnanode/docker-compose.yml || rc=1; }
    fi
    for f in "$SETUP_LOG" "$INSTALL_STATE" "$NOTIFY_ENV" "$PANEL_ENV" "$REPORT_FILE"; do
        [[ -f "$f" ]] && { chmod 600 "$f" || rc=1; }
    done
    echo "  Права приведены к 600 (каталог ноды — 700)."
    return $rc
}

# Проверка, что служебные скрипты действительно годные: файл без первой строки
# исполняется через /bin/sh, где нет [[ ]], и молча не работает.
repair_verify() {
    local f bad=""
    for f in /usr/local/bin/rh-notify.sh /usr/local/bin/rh-ssh-login.sh \
             /usr/local/bin/rh-node-watch.sh /usr/local/bin/rh-node-health.sh \
             /usr/local/bin/rh-panel-watch.sh; do
        [[ -f "$f" ]] || continue
        head -1 "$f" | grep -q '^#!' || bad+=" $(basename "$f")"
    done
    if [[ -n "$bad" ]]; then
        echo "  [СБОЙ] без первой строки (#!/bin/bash):$bad"
        return 1
    fi
    echo "  Служебные скрипты на месте и начинаются с #!/bin/bash."
    return 0
}

run_repair() {
    echo
    echo "=========================================="
    echo "  ПОЧИНКА УЖЕ НАСТРОЕННОЙ НОДЫ"
    echo "=========================================="
    echo "  Фаервол, контейнер и пакеты не трогаются, перезагрузки не будет."
    echo

    FULL_DOMAIN=""
    [[ -n "${SUBDOMAIN:-}" && -n "${DOMAIN:-}" ]] && FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"
    echo "  Нода:     ${FULL_DOMAIN:-не определена}"
    echo "  Панель:   ${PANEL_IP:-не определена}"
    echo "  Учётка:   ${ADMIN_USER:-?} | порт SSH: ${SSH_PORT:-?}"
    echo "  Telegram: $([[ -n "${TG_BOT_TOKEN:-}" ]] && echo "настроен" || echo "не настроен")"
    echo

    do_step "Права на файлы с секретами" repair_perms

    if [[ -n "$FULL_DOMAIN" ]]; then
        do_step "Конфиг nginx (путь для ACME)" comp_web
    else
        skip_step "Конфиг nginx — домен не определён, почините через меню (пункт 4)"
    fi

    if [[ -f "$NOTIFY_ENV" ]]; then
        do_step "Скрипты уведомлений и юниты" comp_telegram
    else
        skip_step "Уведомления — Telegram на этой ноде не настроен (пункт 11)"
    fi

    if [[ -f "$PANEL_ENV" ]]; then
        do_step "Сторож панели" comp_panel_watch
    else
        skip_step "Сторож панели — нода не дежурная"
    fi

    do_step "Проверка служебных скриптов" repair_verify

    save_state || true

    echo
    echo "=========================================="
    echo "  ИТОГ ПОЧИНКИ"
    echo "=========================================="
    printf '%s\n' "${SUMMARY[@]}"
    echo "=========================================="
    echo
    echo "Ответы ноды сохранены в $INSTALL_STATE"
    echo "Проверьте результат:  sudo bash /tmp/check.sh"
    echo "Продление сертификата: sudo certbot renew --dry-run"
    return 0
}
