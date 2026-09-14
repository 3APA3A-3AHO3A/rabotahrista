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
        validate_ssh_params
    fi
    main_menu
fi
