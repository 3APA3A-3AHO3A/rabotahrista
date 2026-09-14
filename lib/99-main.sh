# ##########################################################################
#  ТОЧКА ВХОДА
#  Три режима: только загрузка функций (тесты), неинтерактивный, меню
# ##########################################################################

# Режим «только функции»: используется tests/, чтобы вызывать функции по одной
# без запуска установки. Работает и при source, и при обычном запуске.
if [[ -n "${RH_LIB_ONLY:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi

# Конфиг-файл первым аргументом — неинтерактивная установка
if [[ -n "$1" && -f "$1" ]]; then
    echo "Загружаю конфигурацию из файла: $1"
    # shellcheck disable=SC1090
    source "$1"
    NONINTERACTIVE=1
    validate_ssh_params
fi

if [[ -n "$NONINTERACTIVE" ]] || { [[ -n "$DOMAIN" ]] && [[ -n "$SUBDOMAIN" ]] && [[ -n "$REMNA_SECRET" ]]; }; then
    NONINTERACTIVE=1
    full_install
else
    # Интерактив: подхватить сохранённые данные прошлой установки как значения по умолчанию
    if [[ -f "$INSTALL_STATE" ]]; then
        # shellcheck disable=SC1090
        source "$INSTALL_STATE"
        STATE_LOADED=1
    else
        # Нода поставлена до появления install.conf — вычитываем настройки
        # прямо с сервера, чтобы не заставлять вводить их по памяти
        detect_existing_setup
        if [[ -n "$DOMAIN$PANEL_IP$REMNA_SECRET" ]]; then
            echo "Файла с ответами нет, но нода уже настроена — подставляю найденное:"
            [[ -n "$SUBDOMAIN$DOMAIN" ]] && echo "  домен:    ${SUBDOMAIN}.${DOMAIN}"
            [[ -n "$PANEL_IP" ]]         && echo "  панель:   $PANEL_IP"
            [[ -n "$REMNA_SECRET" ]]     && echo "  секрет:   найден в docker-compose.yml"
            [[ -n "$TG_BOT_TOKEN" ]]     && echo "  Telegram: настройки найдены"
            echo "  Проверьте значения в вопросах ниже."
            STATE_LOADED=1
        fi
    fi
    validate_ssh_params
    main_menu
fi
