# ##########################################################################
#  ПОЛНАЯ УСТАНОВКА
#  Порядок шагов при установке с нуля
# ##########################################################################

# ##########################################################################
#  ПОЛНАЯ УСТАНОВКА
# ##########################################################################
full_install() {
    echo -e "\n========== ПОЛНАЯ УСТАНОВКА =========="
    if [[ -n "$STATE_LOADED" && -z "$NONINTERACTIVE" ]]; then
        echo "Найдены данные прошлой установки: ${SUBDOMAIN}.${DOMAIN}, панель ${PANEL_IP}, учётка ${ADMIN_USER}, порт SSH ${SSH_PORT}"
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
    ask_domain; ask_panel_ip; ask_subdomain; ask_secret; ask_cf

    echo -e "\n--- SSH ---"
    ask_ssh_params
    echo "Итого: учётка «$ADMIN_USER», порт SSH $SSH_PORT. Вход под root и вход по паролю будут отключены."

    if [[ -z "$NONINTERACTIVE" ]]; then
        ask_ssh_key

        echo -e "\n--- Доп. компоненты ---"
        [[ -z "$INSTALL_WARP" ]]      && read -ep "Установить Cloudflare WARP? [y/N]: " INSTALL_WARP
        [[ -z "$INSTALL_SPEEDTEST" ]] && read -ep "Установить Speedtest CLI? [y/N]: " INSTALL_SPEEDTEST

        echo -e "\n--- Telegram-уведомления ---"
        [[ -z "$SETUP_TG" && -z "$TG_BOT_TOKEN" ]] && read -ep "Настроить Telegram-уведомления? [y/N]: " SETUP_TG
        [[ "$SETUP_TG" =~ ^[Yy]$ || -n "$TG_BOT_TOKEN" ]] && ask_telegram
    fi
    [[ "$SETUP_TG" =~ ^[Yy]$ || -n "$TG_BOT_TOKEN" ]] && TG_ON=1 || TG_ON=""

    save_state   # запомнить ответы для будущих обновлений
    FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"
    echo -e "\nСтавлю ноду для $FULL_DOMAIN. Тяжёлый вывод — в $SETUP_LOG\n"; sleep 2

    # --- выполнение (каждый шаг пишет результат в сводку) ---
    do_step "Swap" comp_swap
    do_step "Пакеты и обновление системы" comp_packages
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
        echo "Отчёт выше сохранён в $REPORT_FILE (в нём же пароль учётки)."
        echo "Отключение IPv6 (GRUB) применится только после перезагрузки."
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
