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

# Хостеры после ремонта сервера кладут свои дроп-ины в /etc/ssh/sshd_config.d/.
# Имена вида 00-*.conf сортируются раньше нашего 01-hardening.conf, а sshd
# берёт ПЕРВОЕ встреченное значение — и root с паролями снова открыты, хотя
# файл харденинга на месте и порт правильный. Проверяем фактом (sshd -T) и
# трогаем конфиг ТОЛЬКО если он действительно разъехался.
repair_ssh_hardening() {
    local eff_root eff_pass eff_port

    # Впервые харденинг не накатываем: он отключает вход по паролю и требует
    # проверенный SSH-ключ, а это разговор с человеком. Только восстанавливаем.
    if [[ ! -f "$SSH_HARDEN_FILE" ]]; then
        echo "  Харденинг на этой ноде не применялся — пропускаю."
        echo "  Первичная настройка спросит ключ: меню, пункт 2 -> 8."
        return 0
    fi

    eff_root=$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2}')
    eff_pass=$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')
    eff_port=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    if [[ -z "$eff_root$eff_pass" ]]; then
        echo "  [СБОЙ] sshd не отвечает на sshd -T — вслепую чинить SSH опасно."
        return 1
    fi

    if [[ "$eff_root" == "no" && "$eff_pass" == "no" ]] && sshd_listens_on "$SSH_PORT"; then
        echo "  Харденинг на месте: порт $SSH_PORT, root и вход по паролю закрыты. Не трогаю."
        return 0
    fi

    echo "  Харденинг разъехался: root=$eff_root, пароли=$eff_pass, порт в конфиге=${eff_port:-?}"
    echo "  Восстанавливаю на порт $SSH_PORT. Бэкапы конфигов останутся рядом,"
    echo "  при неудаче харденинг откатится, пока текущая сессия жива."
    comp_ssh
}

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
    echo "  SSH правится, только если харденинг фактически слетел."
    echo

    FULL_DOMAIN=""
    [[ -n "${SUBDOMAIN:-}" && -n "${DOMAIN:-}" ]] && FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"
    echo "  Нода:     ${FULL_DOMAIN:-не определена}"
    echo "  Панель:   ${PANEL_IP:-не определена}"
    echo "  Учётка:   ${ADMIN_USER:-?} | порт SSH: ${SSH_PORT:-?}"
    echo "  Telegram: $([[ -n "${TG_BOT_TOKEN:-}" ]] && echo "настроен" || echo "не настроен")"
    echo

    do_step "Права на файлы с секретами" repair_perms
    do_step "Харденинг SSH (root и пароли)" repair_ssh_hardening

    if [[ -n "$FULL_DOMAIN" ]]; then
        do_step "Конфиг nginx (путь для ACME)" comp_web
    else
        skip_step "Конфиг nginx — домен не определён, почините через меню (пункт 2 -> 4)"
    fi

    if [[ -f "$NOTIFY_ENV" ]]; then
        do_step "Скрипты уведомлений и юниты" comp_telegram
    else
        skip_step "Уведомления — Telegram на этой ноде не настроен (пункт 2 -> 11)"
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
    echo "Проверьте результат:   sudo bash /tmp/setup.sh --check"
    echo "Продление сертификата: sudo certbot renew --dry-run"
    return 0
}
