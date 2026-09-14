# ##########################################################################
#  ТОЧКА ВХОДА
#  Три режима: только загрузка функций (тесты), неинтерактивный, меню
# ##########################################################################

# Режим «только функции»: используется tests/, чтобы вызывать функции по одной
# без запуска установки. Работает и при source, и при обычном запуске.
if [[ -n "${RH_LIB_ONLY:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi

# Диагностика без меню: тот же код, что в пункте 3. Ничего не меняет.
if [[ "${1:-}" == "--check" ]]; then
    if [[ -f "$INSTALL_STATE" ]]; then
        # shellcheck disable=SC1090
        source "$INSTALL_STATE"
    fi
    # Через "if": rh_check штатно возвращает 1, когда нашла проблемы, и без
    # этого set -e с ERR-трапом напечатали бы поверх отчёта аварийную простыню.
    if ( rh_check "${2:-}" ); then exit 0; else exit 1; fi
fi

# Починка уже настроенной ноды: без вопросов, без переустановки
if [[ "${1:-}" == "--repair" ]]; then
    NONINTERACTIVE=1
    if [[ -f "$INSTALL_STATE" ]]; then
        # shellcheck disable=SC1090
        source "$INSTALL_STATE"
    fi
    detect_existing_setup
    validate_ssh_params
    run_repair
    exit 0
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
    fi
    # Дополняем тем, что можно вычитать с самого сервера. Вызывается всегда:
    # install.conf может существовать, но быть неполным — например, создан
    # ранней версией или после точечной правки через меню.
    detect_existing_setup
    if [[ -z "$STATE_LOADED" && -n "${DOMAIN:-}${PANEL_IP:-}${REMNA_SECRET:-}${TG_BOT_TOKEN:-}" ]]; then
        echo "Файла с ответами нет, но нода настроена — вычитал с сервера:"
        [[ -n "${SUBDOMAIN:-}${DOMAIN:-}" ]] && echo "  домен:    ${SUBDOMAIN}.${DOMAIN}"
        [[ -n "${PANEL_IP:-}" ]]             && echo "  панель:   $PANEL_IP"
        [[ -n "${REMNA_SECRET:-}" ]]         && echo "  секрет:   найден в docker-compose.yml"
        [[ -n "${TG_BOT_TOKEN:-}" ]]         && echo "  Telegram: токен и chat_id найдены"
        echo "  Значения подставлены в вопросы — проверьте их там."
        STATE_LOADED=1
    fi
    validate_ssh_params
    main_menu
fi
