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

# ##########################################################################
#  ПЛАН
#  Сначала показываем, что именно будет сделано, и только потом делаем.
#  Пункт меню — это одна кнопка; человек имеет право знать, что за ней.
# ##########################################################################

# Каждый шаг — строка "функция|метка|что именно меняет"
repair_add()  { REPAIR_PLAN+=("$1|$2|$3"); }
repair_note() { REPAIR_SKIPS+=("$1"); }

repair_build_plan() {
    REPAIR_PLAN=()
    REPAIR_SKIPS=()

    repair_add repair_perms "Права на файлы с секретами" \
        "chmod 600 на install.conf, notify.env, лог и отчёт; 700 на каталог ноды"

    if [[ -f "$SSH_HARDEN_FILE" ]]; then
        repair_add repair_ssh_hardening "Харденинг SSH" \
            "только если sshd -T показывает открытый root или вход по паролю: перезальёт $(basename "$SSH_HARDEN_FILE") и перезапустит sshd"
    else
        repair_note "Харденинг SSH — на этой ноде не применялся, первичный делается пунктом 2 -> 8"
    fi

    if getent group docker >/dev/null 2>&1 && [[ -n "${ADMIN_USER:-}" ]] && id "$ADMIN_USER" &>/dev/null; then
        repair_add docker_group_member "Группа docker у $ADMIN_USER" \
            "usermod -aG docker, если его там ещё нет (нужно, чтобы docker ps работал без sudo)"
    else
        repair_note "Группа docker — Docker не установлен или учётка не определена"
    fi

    if [[ -f "$NOTIFY_ENV" ]]; then
        repair_add comp_telegram "Скрипты уведомлений и юниты" \
            "перезапишет /usr/local/bin/rh-*.sh и systemd-юниты, перезапустит их и пришлёт тестовое сообщение"
    else
        repair_note "Уведомления — Telegram на этой ноде не настроен (пункт 2 -> 11)"
    fi

    if [[ -f "$PANEL_ENV" ]]; then
        repair_add comp_panel_watch "Сторож панели" \
            "перезапишет сторожа и его таймер"
    else
        repair_note "Сторож панели — нода не дежурная"
    fi

    repair_add repair_verify "Проверка служебных скриптов" \
        "ничего не меняет, только читает первую строку каждого скрипта"
    return 0
}

repair_print_plan() {
    local line fn label what n=0
    echo "  БУДЕТ СДЕЛАНО:"
    for line in "${REPAIR_PLAN[@]}"; do
        n=$((n+1))
        IFS='|' read -r fn label what <<< "$line"
        printf '   %d) %s\n' "$n" "$label"
        printf '      %s\n' "$what"
    done
    if [[ ${#REPAIR_SKIPS[@]} -gt 0 ]]; then
        echo
        echo "  ПРОПУЩУ:"
        printf '      %s\n' "${REPAIR_SKIPS[@]}"
    fi
    echo
    echo "  НЕ ТРОНУ: фаервол, контейнер ноды, пакеты, nginx. Перезагрузки не будет."
    echo
    return 0
}

# Выбор шагов по одному. Отдельной функцией, чтобы вопрос не оказался
# внутри шага установки — там ждать ввода нельзя.
repair_pick_steps() {
    local line fn label what ans kept=()
    echo
    for line in "${REPAIR_PLAN[@]}"; do
        IFS='|' read -r fn label what <<< "$line"
        read -ep "  $label — делать? [Y/n]: " ans || ans=""
        if [[ "$ans" =~ ^[Nn]$ ]]; then
            REPAIR_SKIPS+=("$label — отказались")
        else
            kept+=("$line")
        fi
    done
    REPAIR_PLAN=("${kept[@]}")
    return 0
}

run_repair() {
    SUMMARY=()
    echo
    echo "=========================================="
    echo "  ПОЧИНКА УЖЕ НАСТРОЕННОЙ НОДЫ"
    echo "=========================================="

    FULL_DOMAIN=""
    [[ -n "${SUBDOMAIN:-}" && -n "${DOMAIN:-}" ]] && FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"
    echo "  Нода:     ${FULL_DOMAIN:-не определена}"
    echo "  Панель:   ${PANEL_IP:-не определена}"
    echo "  Учётка:   ${ADMIN_USER:-?} | порт SSH: ${SSH_PORT:-?}"
    echo "  Telegram: $([[ -n "${TG_BOT_TOKEN:-}" ]] && echo "настроен" || echo "не настроен")"
    echo

    repair_build_plan
    repair_print_plan

    if [[ -z "$NONINTERACTIVE" ]]; then
        local ans
        read -ep "  Выполнить? [y — всё / s — выбрать по шагам / N — отмена]: " ans || ans=""
        case "$ans" in
            [Yy]) ;;
            [Ss]) repair_pick_steps ;;
            *)    echo "  Отменено. Ничего не изменено."; return 0 ;;
        esac
    fi

    if [[ ${#REPAIR_PLAN[@]} -eq 0 ]]; then
        echo "  Не выбрано ни одного шага. Ничего не изменено."
        return 0
    fi

    echo
    local line fn label what
    for line in "${REPAIR_PLAN[@]}"; do
        IFS='|' read -r fn label what <<< "$line"
        do_step "$label" "$fn"
    done

    local skipped
    for skipped in "${REPAIR_SKIPS[@]}"; do skip_step "$skipped"; done

    # nginx автоматическая починка НЕ ТРОГАЕТ: человек не видит, что именно
    # правится, а рядом с нодой может жить чужой сайт. Рекомендацию печатаем
    # только когда есть что рекомендовать — иначе это простыня на ровном месте.
    if [[ -n "${DOMAIN_AMBIGUOUS:-}" ]]; then
        echo "  На ноде несколько доменов: $DOMAIN_AMBIGUOUS"
        echo "  Какой из них принадлежит ноде — решать вам."
        skip_step "Конфиг nginx — доменов несколько, разбирайтесь вручную (пункт 2 -> 4)"
    elif [[ -z "$FULL_DOMAIN" ]]; then
        skip_step "Конфиг nginx — домен не определён"
    elif nginx_needs_attention "$FULL_DOMAIN"; then
        nginx_advise "$FULL_DOMAIN" || true
        skip_step "Конфиг nginx — только рекомендация, ничего не изменено"
    else
        skip_step "Конфиг nginx — в порядке, не трогаю"
    fi

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
