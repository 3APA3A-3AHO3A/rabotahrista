# ##########################################################################
#  ПОЛНАЯ УСТАНОВКА
#  Порядок шагов при установке с нуля
# ##########################################################################

# ##########################################################################
#  ПОЛНАЯ УСТАНОВКА
# ##########################################################################
full_install() {
    ui_title "Установка ноды Remnawave" "вопросы сейчас, потом работа без участия"
    # Проверки до вопросов: незачем тратить время человека, если сервер не готов
    if ! rh_preflight; then
        return 1
    fi
    RH_T0=$SECONDS
    if [[ -n "$STATE_LOADED" && -z "$NONINTERACTIVE" ]]; then
        ui_section "Найдены ответы прошлой установки"
        ui_kv "домен" "${SUBDOMAIN}.${DOMAIN}"
        ui_kv "панель" "${PANEL_IP}"
        ui_kv "учётка и порт" "${ADMIN_USER}, ${SSH_PORT}"
        read -ep "Обновить с этими данными (без повторного ввода)? [Y/n]: " USE_SAVED || USE_SAVED=""
        if [[ "$USE_SAVED" =~ ^[Nn]$ ]]; then
            DOMAIN=""; SUBDOMAIN=""; PANEL_IP=""; REMNA_SECRET=""
            SETUP_CF=""; CF_API_TOKEN=""; CF_PROXY_CHOICE=""
            SETUP_SSH=""; SSH_PUBLIC_KEY=""; INSTALL_WARP=""; INSTALL_SPEEDTEST=""
            SSH_PORT="8422"; ADMIN_USER="admin"
            SETUP_TG=""; TG_BOT_TOKEN=""; TG_CHAT_ID=""; TG_TOPIC_ID=""
        fi
    fi
    # --- сбор всех ответов заранее ---
    ui_section "Нода и панель"
    ask_domain; ask_panel_ip; ask_subdomain; ask_secret; ask_cf

    ui_section "Доступ по SSH"
    ask_ssh_params
    ui_info "учётка «$ADMIN_USER», порт $SSH_PORT; вход под root и по паролю будут закрыты"

    if [[ -z "$NONINTERACTIVE" ]]; then
        ask_ssh_key

        ui_section "Дополнительно"
        [[ -z "$INSTALL_WARP" ]]      && read -ep "Установить Cloudflare WARP? [y/N]: " INSTALL_WARP
        [[ -z "$INSTALL_SPEEDTEST" ]] && read -ep "Установить Speedtest CLI? [y/N]: " INSTALL_SPEEDTEST

        ui_section "Telegram-уведомления"
        [[ -z "$SETUP_TG" && -z "$TG_BOT_TOKEN" ]] && read -ep "Настроить Telegram-уведомления? [y/N]: " SETUP_TG
        [[ "$SETUP_TG" =~ ^[Yy]$ || -n "$TG_BOT_TOKEN" ]] && ask_telegram
    fi
    [[ "$SETUP_TG" =~ ^[Yy]$ || -n "$TG_BOT_TOKEN" ]] && TG_ON=1 || TG_ON=""

    save_state   # запомнить ответы для будущих обновлений
    FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"
    ui_title "Ставлю ноду $FULL_DOMAIN" "вопросов больше не будет · подробный лог: $SETUP_LOG"
    sleep 1

    # --- выполнение (каждый шаг пишет результат в сводку) ---
    do_step "Swap" comp_swap
    # Пакеты — фундамент. Без них не встанут ни нода, ни сертификат, ни fail2ban,
    # ни docker, и человек получает шесть сбоев по одной причине плюс отчёт,
    # в котором половина строк врёт. Останавливаемся здесь: SSH ещё не тронут,
    # сервер в том же состоянии, что и до запуска.
    if ! do_step_required "Пакеты и обновление системы" comp_packages; then
        echo
        echo "=========================================="
        echo "  УСТАНОВКА ОСТАНОВЛЕНА"
        echo "=========================================="
        echo "  Пакеты не установились. Продолжать нечем: без них не будет ни ноды,"
        echo "  ни сертификата, ни fail2ban."
        echo
        echo "  Чаще всего apt занят автообновлением после первой загрузки сервера."
        echo "  Посмотреть, кто держит:"
        echo "    pgrep -a 'apt-get|unattended-upgr|dpkg'"
        echo "  Притормозить на время установки:"
        echo "    systemctl stop unattended-upgrades apt-daily.timer apt-daily-upgrade.timer"
        echo
        echo "  Затем запустите установку заново. Ничего не сломано: доступ по SSH"
        echo "  не менялся, сервер в том же состоянии, что и до запуска."
        echo "  Полный лог: $SETUP_LOG"
        echo "=========================================="
        return 1
    fi
    do_step "Пользователь $ADMIN_USER" comp_user
    do_step "Харденинг SSH" comp_ssh
    do_step "fail2ban" comp_fail2ban
    do_step "Автообновления безопасности" comp_autoupdates
    do_step "Отключение IPv6 (GRUB)" comp_ipv6
    do_step "UFW-фаервол" comp_ufw
    do_step "Sysctl-тюнинг" comp_sysctl
    do_step "Docker" comp_docker
    do_step "Защита диска (лог-ротация)" comp_disk
    [[ "$INSTALL_SPEEDTEST" =~ ^[Yy]$ ]] && do_step "Speedtest CLI" comp_speedtest || skip_step "Speedtest CLI"
    [[ "$INSTALL_WARP" =~ ^[Yy]$ ]] && do_step "Cloudflare WARP" comp_warp || skip_step "Cloudflare WARP"
    do_step "Нода Remnanode" comp_node
    do_step "Веб (заглушка+сертификат+nginx)" comp_web
    [[ -n "$TG_ON" ]] && do_step "Telegram-уведомления" comp_telegram || skip_step "Telegram-уведомления"
    if [[ -n "$TG_ON" && "$PANEL_WATCH" =~ ^[Yy]$ ]]; then
        do_step "Сторож панели" comp_panel_watch
    else
        skip_step "Сторож панели (нода не дежурная)"
    fi

    notify_telegram "🚀 Нода <code>${FULL_DOMAIN}</code> установлена ($(date '+%H:%M:%S %Z'))"

    print_summary

    if [[ -z "$NONINTERACTIVE" ]]; then
        echo
        ui_info "отчёт сохранён в $REPORT_FILE, там же пароль учётки"
        ui_info "отключение IPv6 применится только после перезагрузки"
        read -ep "Доустановить/переустановить что-то в меню перед ребутом? [y/N]: " ADDC || ADDC=""
        [[ "$ADDC" =~ ^[Yy]$ ]] && components_menu
        read -ep "Перезагрузить сервер сейчас? [Y/n]: " RB || RB=""
        if [[ "$RB" =~ ^[Nn]$ ]]; then
            echo "Ок. Позже перезагрузи вручную (нужно для IPv6): reboot"
            return
        fi
    fi
    echo "Перезагрузка через 10 секунд (Ctrl+C — отменить)..."
    sleep 10
    reboot
}
