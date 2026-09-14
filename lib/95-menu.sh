# ##########################################################################
#  МЕНЮ
#  Главное меню и меню компонентов
# ##########################################################################

# ##########################################################################
#  МЕНЮ
# ##########################################################################
# Запуск компонента из меню.
# Обязательно через "if", а не напрямую: ERR-трап срабатывает даже при set +e,
# и любая ненулевая команда внутри comp_* убивала бы весь установщик.
# Внутри условия и set -e, и ERR-трап подавлены для всего поддерева вызова.
menu_step() {
    local label="$1"; shift
    if "$@"; then
        echo -e "\n[Готово] $label"
    else
        echo -e "\n[СБОЙ] $label — подробности в $SETUP_LOG"
    fi
    return 0
}

# Пункт 8 делает два шага подряд — оборачиваем, чтобы тоже шло через menu_step
comp_user_and_ssh() { comp_user && comp_ssh; }

components_menu() {
    while true; do
        echo -e "\n===== Компоненты (доустановить / переустановить) ====="
        echo " 1) Cloudflare WARP        2) Docker          3) Нода (передеплой)"
        echo " 4) Веб (заглушка+серт)    5) UFW             6) Sysctl-тюнинг"
        echo " 7) Swap                   8) Юзер + SSH-харденинг   9) Speedtest"
        echo "10) IPv6 off (GRUB)"
        echo "--- Безопасность / обслуживание ---"
        echo "11) Telegram-уведомления  12) fail2ban       13) Автообновления"
        echo "21) Сторож панели вкл.    22) Сторож панели выкл."
        echo "23) Сменить домен ноды"
        echo "14) Защита диска          15) Обновить ноду  16) Статус ноды"
        echo "20) Обновить систему (apt upgrade + перезагрузка)"
        echo "--- Диагностика ---"
        echo "17) bench.sh   18) ipregion   19) проверка блокировок (censorcheck)"
        echo " 0) Назад"
        read -ep "Выбор: " c
        case "$c" in
             1) menu_step "Cloudflare WARP"      comp_warp ;;
             2) menu_step "Docker"               comp_docker ;;
             3) menu_step "Нода (передеплой)"    comp_node ;;
             4) menu_step "Веб (заглушка+серт)"  comp_web ;;
             5) menu_step "UFW"                  comp_ufw ;;
             6) menu_step "Sysctl-тюнинг"        comp_sysctl ;;
             7) menu_step "Swap"                 comp_swap ;;
             8) menu_step "Юзер + SSH-харденинг" comp_user_and_ssh ;;
             9) menu_step "Speedtest"            comp_speedtest ;;
            10) menu_step "IPv6 off (GRUB)"      comp_ipv6 ;;
            11) menu_step "Telegram-уведомления" comp_telegram ;;
            12) menu_step "fail2ban"             comp_fail2ban ;;
            13) menu_step "Автообновления"       comp_autoupdates ;;
            14) menu_step "Защита диска"         comp_disk ;;
            15) menu_step "Обновление ноды"      comp_node_update ;;
            16) menu_step "Статус ноды"          node_status ;;
            17) menu_step "bench.sh"             run_bench ;;
            18) menu_step "ipregion"             run_geo ;;
            19) menu_step "censorcheck"          run_censor ;;
            20) menu_step "Обновление системы"   comp_os_update ;;
            21) menu_step "Сторож панели"        comp_panel_watch ;;
            22) menu_step "Отключение сторожа"   comp_panel_watch_off ;;
            23) menu_step "Смена домена ноды"     comp_change_domain ;;
             0) return ;;
             *) echo "Нет такого пункта." ;;
        esac
    done
}

main_menu() {
    while true; do
        echo -e "\n=========================================="
        echo "  Установщик ноды rabotahrista"
        echo "=========================================="
        echo " 1) Полная установка"
        echo " 2) Доустановить/переустановить компонент"
        echo " 0) Выход"
        read -ep "Выбор: " m
        case "$m" in
            1) full_install ;;
            2) components_menu ;;
            0) exit 0 ;;
            *) echo "Нет такого пункта." ;;
        esac
    done
}
