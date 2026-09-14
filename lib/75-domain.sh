# ##########################################################################
#  СМЕНА ДОМЕНА НОДЫ
#  Перевод работающей ноды на другой субдомен без переустановки
# ##########################################################################

# Раньше это был отдельный changedomain.sh со своей копией логики выпуска
# сертификата и своим шаблоном nginx. Копия успела разойтись с оригиналом:
# там остался certbot --nginx (который запускался до создания конфига и потому
# не находил нужный server_name) и проверка DNS по совпадению IP, не работающая
# за прокси Cloudflare. Здесь используются те же функции, что и при установке.

comp_change_domain() {
    local old_domain="${FULL_DOMAIN:-}"
    if [[ -z "$old_domain" && -n "${SUBDOMAIN:-}" && -n "${DOMAIN:-}" ]]; then
        old_domain="${SUBDOMAIN}.${DOMAIN}"
    fi
    echo ">>> Смена домена ноды"
    echo "  Текущий домен: ${old_domain:-неизвестен}"

    if [[ -z "$NONINTERACTIVE" ]]; then
        echo "  Заведите A-запись нового субдомена ДО продолжения."
        DOMAIN=""; SUBDOMAIN=""
    fi
    ask_domain
    ask_subdomain
    FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"

    if [[ "$FULL_DOMAIN" == "$old_domain" ]]; then
        echo "  Новый домен совпадает со старым — менять нечего."
        return 0
    fi
    echo "  Переводим ноду: ${old_domain:-?}  ->  $FULL_DOMAIN"

    get_server_ip || true

    # --- сертификат для нового домена ---
    if [[ -d "/etc/letsencrypt/live/$FULL_DOMAIN" ]]; then
        echo "  Сертификат для $FULL_DOMAIN уже есть, выпускать не нужно."
    else
        acme_serve_start || return 1
        if ! acme_reachable; then
            echo "  [ВНИМАНИЕ] ACME-проверка не дошла до сервера."
            echo "    Проверьте A-запись $FULL_DOMAIN и что порт 80 открыт."
            if [[ -z "$NONINTERACTIVE" ]]; then
                read -ep "  Пробовать выпустить сертификат всё равно? [y/N]: " TRY || TRY=""
                if [[ ! "$TRY" =~ ^[Yy]$ ]]; then
                    acme_serve_stop
                    echo "  [СБОЙ] Смена домена отменена, ничего не изменено."
                    return 1
                fi
            fi
        fi
        if ! certbot certonly --webroot -w /var/lib/letsencrypt -d "$FULL_DOMAIN" \
                --register-unsafely-without-email --agree-tos --non-interactive \
                --keep-until-expiring >>"$SETUP_LOG" 2>&1; then
            acme_serve_stop
            echo "  [СБОЙ] Certbot не выпустил сертификат для $FULL_DOMAIN (см. $SETUP_LOG)"
            echo "         Нода осталась на прежнем домене, ничего не сломано."
            return 1
        fi
        acme_serve_stop
    fi

    # --- конфиг nginx (тот же шаблон, что при установке) ---
    if ! write_nginx_site "$FULL_DOMAIN"; then
        echo "  [СБОЙ] nginx не принял конфиг нового домена."
        if [[ -n "$old_domain" && -f "/etc/nginx/sites-available/$old_domain" ]]; then
            echo "  Возвращаю прежний домен, чтобы нода не осталась без веба..."
            write_nginx_site "$old_domain" || echo "  [СБОЙ] и прежний конфиг не поднялся — смотрите $SETUP_LOG"
            FULL_DOMAIN="$old_domain"
            SUBDOMAIN="${old_domain%%.*}"; DOMAIN="${old_domain#*.}"
        fi
        return 1
    fi

    # --- сохранённые ответы: иначе следующий запуск setup.sh вернёт старый домен ---
    save_state
    echo "  Новый домен записан в $INSTALL_STATE"

    # --- метка ноды в уведомлениях, если она была равна старому домену ---
    if [[ -f "$NOTIFY_ENV" ]] && grep -q "NODE_LABEL=\"$old_domain\"" "$NOTIFY_ENV" 2>/dev/null; then
        sed -i "s|NODE_LABEL=\"$old_domain\"|NODE_LABEL=\"$FULL_DOMAIN\"|" "$NOTIFY_ENV"
        echo "  Имя ноды в уведомлениях обновлено на $FULL_DOMAIN"
    fi

    # --- старый сертификат: удаляем только с явного согласия ---
    if [[ -n "$old_domain" && -d "/etc/letsencrypt/live/$old_domain" && -z "$NONINTERACTIVE" ]]; then
        echo
        echo "  Остался сертификат старого домена $old_domain."
        echo "  Его можно удалить, но если планируете вернуться — оставьте."
        read -ep "  Удалить сертификат $old_domain? [y/N]: " DELCERT || DELCERT=""
        if [[ "$DELCERT" =~ ^[Yy]$ ]]; then
            certbot delete --cert-name "$old_domain" --non-interactive >>"$SETUP_LOG" 2>&1 \
                && echo "  Сертификат $old_domain удалён." \
                || echo "  [ВНИМАНИЕ] Удалить сертификат не удалось (см. $SETUP_LOG)"
        else
            echo "  Сертификат $old_domain оставлен."
        fi
    fi
    if [[ -n "$old_domain" && -f "/etc/nginx/sites-available/$old_domain" && -z "$NONINTERACTIVE" ]]; then
        read -ep "  Удалить старый конфиг nginx /etc/nginx/sites-available/$old_domain? [y/N]: " DELCONF || DELCONF=""
        if [[ "$DELCONF" =~ ^[Yy]$ ]]; then
            rm -f "/etc/nginx/sites-available/$old_domain"
            echo "  Старый конфиг удалён."
        else
            echo "  Старый конфиг оставлен (он отключён и ни на что не влияет)."
        fi
    fi

    notify_telegram "🌐 Нода переведена на домен <code>${FULL_DOMAIN}</code> (была <code>${old_domain:-?}</code>)"

    echo
    echo "  =========================================="
    echo "  Нода переведена на $FULL_DOMAIN"
    echo "  =========================================="
    echo "  ОСТАЛОСЬ СДЕЛАТЬ ВРУЧНУЮ: поменять адрес ноды в панели Remnawave."
    echo "  Пока этого нет, панель продолжит ходить на старый адрес."
    return 0
}
