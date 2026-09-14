# ##########################################################################
#  ДИАГНОСТИКА НОДЫ
#
#  Функция rh_check НИЧЕГО НЕ МЕНЯЕТ — только читает и рассказывает, что нашла.
#  Это сознательное ограничение, и оно проверяется тестом, а не обещанием:
#  диагностику запускают на живой ноде посреди рабочего дня.
#
#  Живёт здесь, а не в отдельном файле, чтобы на сервер приезжал ОДИН скрипт:
#  меню -> «Диагностика», и всё. Из этого же модуля сборщик делает
#  самостоятельный check.sh для тех, кому нужна только проверка.
# ##########################################################################

rhc_ok()   { printf '  \033[32m[ ok ]\033[0m %s\n' "$*"; }
rhc_warn() { printf '  \033[33m[ ?? ]\033[0m %s\n' "$*"; rhc_warnings=$((rhc_warnings+1)); }
rhc_bad()  { printf '  \033[31m[ !! ]\033[0m %s\n' "$*"; rhc_problems=$((rhc_problems+1)); }
rhc_info() { printf '         %s\n' "$*"; }
rhc_sect() { printf '\n\033[1m── %s\033[0m\n' "$*"; }
rhc_fix()  { rhc_fixes+=("$*"); }

# Порты, на которых сейчас слушает SSH. При socket-активации слушателем
# выступает systemd, поэтому его тоже засчитываем.
rhc_ports()     { ss -H -ltnp 2>/dev/null | grep -E 'users:\(\("(sshd|systemd)"' \
                  | awk '{print $4}' | sed 's/.*://' | sort -un; return 0; }
rhc_listening() { ss -H -ltn 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -un; return 0; }
rhc_hasport()   { grep -qx "$1" <<< "$(rhc_listening)"; }
rhc_perm()      { stat -c '%a' "$1" 2>/dev/null || echo "?"; }
# grep -c при нуле совпадений печатает "0" И возвращает ненулевой код.
# Из-за этого "|| echo 0" дописывал второй ноль, получалось "0\n0",
# и арифметическое сравнение падало с syntax error.
rhc_num()       { local v; v=$(printf '%s' "${1:-}" | head -1 | tr -cd '0-9'); echo "${v:-0}"; }

# rh_check [--deep]   — вызывать ТОЛЬКО в подоболочке: ( rh_check )
rh_check() {
    # Диагностика перебирает десятки проверок, половина из которых штатно
    # возвращает ненулевой код. Внутри установщика это поймал бы ERR-трап.
    set +e
    trap - ERR

    local rhc_problems=0 rhc_warnings=0
    local rhc_fixes=()
    local rhc_deep="" rhc_compose="/opt/remnanode/docker-compose.yml"
    [[ "${1:-}" == "--deep" ]] && rhc_deep=1

    if [[ "$EUID" -ne 0 ]]; then
        echo "Нужны права root."
        return 1
    fi

    printf '\033[1m==========================================\n'
    printf '  ДИАГНОСТИКА НОДЫ  —  %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '==========================================\033[0m\n'

    # ----------------------------------------------------------------------
    rhc_sect "Система"
    # ----------------------------------------------------------------------
    rhc_info "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") | ядро $(uname -r)"
    rhc_info "хост $(hostname) | uptime $(uptime -p 2>/dev/null || echo '?')"
    rhc_info "внешний IP: $(curl -fs --max-time 8 https://api.ipify.org 2>/dev/null || echo 'не определился')"

    if [[ -f "$INSTALL_STATE" ]]; then
        rhc_ok "install.conf найден — нода ставилась этим скриптом"
        # shellcheck disable=SC1090
        source "$INSTALL_STATE" 2>/dev/null || true
    else
        # Не проблема: установщик умеет вычитывать настройки с самого сервера,
        # а файл создаётся при первой же правке через меню.
        rhc_info "нет $INSTALL_STATE — нода ставилась ранней версией"
        rhc_info "настройки будут вычитаны с сервера; файл появится после первой правки через меню"
    fi
    local rhc_np="${NODE_PORT:-2222}"

    if [[ -z "$(swapon --show 2>/dev/null)" ]]; then
        rhc_warn "swap не подключён"
        rhc_fix "swap: меню, пункт 2 -> 7"
    else
        rhc_ok "swap: $(swapon --show=SIZE --noheadings 2>/dev/null | tr -d ' \n')"
    fi

    # ----------------------------------------------------------------------
    rhc_sect "SSH"
    # ----------------------------------------------------------------------
    local rhc_inc rhc_hard="$SSH_HARDEN_FILE" rhc_conflict
    rhc_inc=$(grep -nE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' \
              /etc/ssh/sshd_config 2>/dev/null | head -1 | cut -d: -f1)

    if [[ -z "$rhc_inc" ]]; then
        if [[ -f "$rhc_hard" ]]; then
            rhc_bad "файл харденинга есть, но sshd_config его НЕ ЧИТАЕТ — настройки не применены"
            rhc_fix "SSH: меню, пункт 4 (починка) — вернёт Include и перезальёт харденинг"
        else
            rhc_info "sshd_config.d не подключён, и файла харденинга нет"
        fi
    else
        rhc_ok "sshd_config читает каталог sshd_config.d (строка $rhc_inc)"
        # sshd берёт ПЕРВОЕ встреченное значение. Если Include стоит не в начале,
        # директивы выше него побеждают — и харденинг применяется лишь частично.
        rhc_conflict=$(awk -v n="$rhc_inc" \
            'NR<n && /^[[:space:]]*(PermitRootLogin|PasswordAuthentication)[[:space:]]/ {print "    строка "NR": "$0}' \
            /etc/ssh/sshd_config 2>/dev/null)
        if [[ -n "$rhc_conflict" ]]; then
            rhc_bad "выше Include заданы настройки, которые перебивают харденинг:"
            echo "$rhc_conflict"
            rhc_info "sshd берёт первое встреченное значение, поэтому файл харденинга ниже игнорируется"
            rhc_fix "SSH: меню, пункт 4 (починка) — закомментирует эти строки"
        fi
    fi

    # Дроп-ины читаются по алфавиту, и между ними действует тот же принцип.
    # Хостеры кладут файлы вида 00-*.conf — они сортируются раньше нашего.
    local rhc_f rhc_base rhc_early=""
    for rhc_f in /etc/ssh/sshd_config.d/*.conf; do
        [[ -e "$rhc_f" ]] || continue
        rhc_base=$(basename "$rhc_f")
        [[ "$rhc_base" < "$(basename "$SSH_HARDEN_FILE")" ]] || continue
        grep -qE '^[[:space:]]*(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)[[:space:]]' \
             "$rhc_f" || continue
        rhc_early+=" $rhc_base"
    done
    if [[ -n "$rhc_early" ]]; then
        rhc_bad "чужие дроп-ины читаются раньше нашего и перебивают харденинг:$rhc_early"
        rhc_info "такое оставляет хостер после ремонта сервера — настройки возвращаются к своим"
        rhc_fix "SSH: меню, пункт 4 (починка) — закомментирует эти строки и перезапустит sshd"
    fi

    if [[ -f "$rhc_hard" ]]; then
        rhc_ok "файл харденинга на месте"
    else
        rhc_bad "нет $rhc_hard — харденинг SSH на этой ноде не применялся"
        rhc_fix "SSH: меню, пункт 2 -> 8 (первичный харденинг спросит ключ)"
    fi

    local rhc_cfgport rhc_live
    rhc_cfgport=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    rhc_live=$(rhc_ports | tr '\n' ' ')
    rhc_info "порт в конфиге: ${rhc_cfgport:-?} | слушает сейчас: ${rhc_live:-никто}"
    if [[ -n "$rhc_cfgport" ]] && grep -qx "$rhc_cfgport" <<< "$(rhc_ports)"; then
        rhc_ok "sshd слушает тот порт, что указан в конфиге"
    elif [[ -n "$rhc_live" ]]; then
        rhc_warn "порт из конфига не совпадает с рабочим — настройки применятся после перезагрузки"
    else
        rhc_bad "sshd не слушает вообще ничего"
    fi

    local rhc_root rhc_pass
    rhc_root=$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2}')
    rhc_pass=$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')
    if [[ -z "$rhc_root$rhc_pass" ]]; then
        rhc_warn "не удалось прочитать настройки sshd (sshd -T) — sshd не установлен?"
    else
        if [[ "$rhc_root" == "no" ]]; then
            rhc_ok "вход под root запрещён"
        else
            rhc_bad "вход под root разрешён ($rhc_root)"
            rhc_fix "SSH: меню, пункт 4 (починка)"
        fi
        if [[ "$rhc_pass" == "no" ]]; then
            rhc_ok "вход по паролю запрещён"
        else
            rhc_bad "вход по паролю разрешён ($rhc_pass)"
            rhc_fix "SSH: меню, пункт 4 (починка)"
        fi
    fi

    local rhc_home rhc_keys
    if [[ -n "${ADMIN_USER:-}" ]] && id "$ADMIN_USER" &>/dev/null; then
        rhc_home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
        rhc_keys=$(rhc_num "$(grep -cvE '^[[:space:]]*(#|$)' "$rhc_home/.ssh/authorized_keys" 2>/dev/null)")
        if [[ "$rhc_keys" -gt 0 ]]; then
            rhc_ok "у $ADMIN_USER ключей: $rhc_keys"
        else
            rhc_bad "у $ADMIN_USER нет ни одного SSH-ключа"
        fi
    fi

    # ----------------------------------------------------------------------
    rhc_sect "Фаервол"
    # ----------------------------------------------------------------------
    local rhc_p rhc_ipv6
    if ufw status 2>/dev/null | head -1 | grep -q 'active'; then
        rhc_ok "ufw включён"
        for rhc_p in $(rhc_ports); do
            if ufw status 2>/dev/null | grep -qE "(^| )$rhc_p/tcp"; then
                rhc_ok "SSH-порт $rhc_p открыт в ufw"
            else
                rhc_bad "SSH-порт $rhc_p НЕ открыт в ufw — после разрыва сессии не зайти"
                rhc_fix "ufw: ufw limit $rhc_p/tcp"
            fi
        done
        if ufw status 2>/dev/null | grep -q "$rhc_np"; then
            rhc_ok "порт ноды $rhc_np есть в правилах"
        else
            rhc_bad "порт ноды $rhc_np не открыт — панель не достучится"
            rhc_fix "ufw: меню, пункт 2 -> 5"
        fi
        rhc_ipv6=$(grep -E '^IPV6=' /etc/default/ufw 2>/dev/null | cut -d= -f2)
        if [[ -d /proc/sys/net/ipv6 ]]; then
            if [[ "$rhc_ipv6" == "yes" ]]; then
                rhc_ok "IPv6 живой и фильтруется фаерволом"
            else
                rhc_bad "IPv6 активен, но ufw его НЕ фильтрует (IPV6=$rhc_ipv6) — все порты открыты по IPv6"
                rhc_fix "IPv6: меню, пункт 2 -> 5 (перенастроит ufw) либо 10 (выключить IPv6 в GRUB)"
            fi
        else
            rhc_ok "IPv6 отключён в ядре — фильтровать нечего"
        fi
    else
        rhc_bad "ufw выключен"
        rhc_fix "ufw: меню, пункт 2 -> 5"
    fi

    local rhc_banned
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        if fail2ban-client status sshd >/dev/null 2>&1; then
            rhc_banned=$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned/{print $2}' | tr -d ' ')
            rhc_ok "fail2ban работает, джейл sshd активен (забанено сейчас: ${rhc_banned:-0})"
        else
            rhc_bad "fail2ban запущен, но джейл sshd НЕ поднялся — брутфорс никто не блокирует"
            dpkg -l python3-systemd 2>/dev/null | grep -q '^ii' \
                || rhc_fix "fail2ban: меню, пункт 2 -> 12 (доставит python3-systemd)"
        fi
    else
        rhc_bad "fail2ban не запущен"
        rhc_fix "fail2ban: меню, пункт 2 -> 12"
    fi

    # ----------------------------------------------------------------------
    rhc_sect "Нода"
    # ----------------------------------------------------------------------
    local rhc_perms rhc_state rhc_restarts rhc_img
    if [[ -f "$rhc_compose" ]]; then
        rhc_perms=$(rhc_perm "$rhc_compose")
        if [[ "$rhc_perms" == "600" ]]; then
            rhc_ok "docker-compose.yml с правами 600"
        else
            rhc_bad "docker-compose.yml с правами $rhc_perms — SECRET_KEY ноды читает любой пользователь"
            rhc_fix "права: меню, пункт 4 (починка)"
        fi
    else
        rhc_bad "нет $rhc_compose — нода не развёрнута"
    fi

    if command -v docker >/dev/null 2>&1; then
        rhc_state=$(docker inspect -f '{{.State.Status}}' remnanode 2>/dev/null | head -1 | tr -d '\n')
        [[ -z "$rhc_state" ]] && rhc_state="контейнера нет"
        rhc_restarts=$(docker inspect -f '{{.RestartCount}}' remnanode 2>/dev/null || echo "?")
        rhc_img=$(docker inspect -f '{{.Config.Image}}' remnanode 2>/dev/null || echo "?")
        if [[ "$rhc_state" == "running" ]]; then
            rhc_ok "контейнер remnanode: running (перезапусков: $rhc_restarts, образ $rhc_img)"
            [[ "${rhc_restarts:-0}" -gt 5 ]] && rhc_warn "много перезапусков — смотри docker logs remnanode"
        else
            rhc_bad "контейнер remnanode: $rhc_state"
            rhc_fix "нода: меню, пункт 2 -> 3 (передеплой)"
        fi
        if rhc_hasport "$rhc_np"; then
            rhc_ok "порт $rhc_np слушает — панель сможет подключиться"
        else
            rhc_bad "порт $rhc_np не слушает — панель ноду не увидит"
        fi
    else
        rhc_bad "docker не установлен"
    fi

    # ----------------------------------------------------------------------
    rhc_sect "Сертификат и nginx"
    # ----------------------------------------------------------------------
    local rhc_full rhc_certdir rhc_cn rhc_end rhc_days rhc_ngx rhc_auth rhc_enabled
    rhc_full="${SUBDOMAIN:-}${SUBDOMAIN:+.}${DOMAIN:-}"
    rhc_certdir=$(ls -d /etc/letsencrypt/live/*/ 2>/dev/null | head -1)
    if [[ -n "$rhc_certdir" ]]; then
        rhc_cn=$(basename "$rhc_certdir")
        rhc_end=$(openssl x509 -enddate -noout -in "$rhc_certdir/fullchain.pem" 2>/dev/null | cut -d= -f2)
        rhc_days=$(( ( $(date -d "$rhc_end" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
        if [[ "$rhc_days" -gt 25 ]]; then
            rhc_ok "сертификат $rhc_cn: осталось $rhc_days дн."
        elif [[ "$rhc_days" -gt 0 ]]; then
            rhc_bad "сертификат $rhc_cn истекает через $rhc_days дн. — продление не сработало"
        else
            rhc_bad "сертификат $rhc_cn ПРОСРОЧЕН"
        fi

        rhc_ngx="/etc/nginx/sites-available/${rhc_full:-$rhc_cn}"
        if [[ -f "$rhc_ngx" ]]; then
            if awk '/listen .*8443/,0' "$rhc_ngx" | grep -q 'acme-challenge'; then
                rhc_ok "в TLS-блоке nginx есть путь для ACME — продление по HTTPS пройдёт"
            else
                rhc_bad "в TLS-блоке nginx НЕТ пути для ACME"
                rhc_info "при «Always Use HTTPS» в Cloudflare продление тихо провалится через ~60 дней"
                rhc_fix "сертификат: меню, пункт 4 (починка) — перезапишет конфиг nginx правильно"
            fi
        fi
        rhc_auth=$(grep -h '^authenticator' /etc/letsencrypt/renewal/*.conf 2>/dev/null | head -1 | awk '{print $3}')
        rhc_info "способ продления: ${rhc_auth:-неизвестен}"
    else
        rhc_warn "сертификатов Let's Encrypt не найдено"
    fi

    if systemctl is-active --quiet nginx 2>/dev/null; then
        if nginx -t >/dev/null 2>&1; then
            rhc_ok "nginx работает, конфиг валиден"
        else
            rhc_bad "nginx работает, но конфиг невалиден (nginx -t)"
        fi
        rhc_enabled=$(ls /etc/nginx/sites-enabled/ 2>/dev/null | wc -l)
        [[ "$rhc_enabled" -gt 1 ]] && rhc_warn "в sites-enabled $rhc_enabled конфигов — возможен конфликт default_server"
    else
        rhc_bad "nginx не запущен"
    fi

    if [[ -n "$rhc_deep" ]] && command -v certbot >/dev/null 2>&1 && [[ -n "$rhc_certdir" ]]; then
        rhc_info "проверяю продление вживую (certbot --dry-run, до минуты)..."
        if certbot renew --dry-run >/dev/null 2>&1; then
            rhc_ok "тестовое продление прошло — сертификат продлится сам"
        else
            rhc_bad "тестовое продление ПРОВАЛИЛОСЬ — через 90 дней сертификат умрёт"
            rhc_info "подробности: certbot renew --dry-run"
        fi
    fi

    # ----------------------------------------------------------------------
    rhc_sect "Уведомления"
    # ----------------------------------------------------------------------
    local rhc_u rhc_pwip rhc_conns
    if [[ -f "$NOTIFY_ENV" ]]; then
        rhc_perms=$(rhc_perm "$NOTIFY_ENV")
        if [[ "$rhc_perms" == "600" ]]; then
            rhc_ok "notify.env с правами 600"
        else
            rhc_bad "notify.env с правами $rhc_perms — токен бота читает любой"
            rhc_fix "права: меню, пункт 4 (починка)"
        fi
        for rhc_u in rh-node-watch.service rh-node-health.timer; do
            if systemctl is-active --quiet "$rhc_u" 2>/dev/null; then
                rhc_ok "$rhc_u работает"
            else
                rhc_bad "$rhc_u не работает — о падении ноды не узнаете"
                rhc_fix "уведомления: меню, пункт 4 (починка)"
            fi
        done
        # Юнит уведомления о загрузке долго был сломан: systemd съедает %H/%M/%S
        if [[ -f /etc/systemd/system/rh-boot-notify.service ]]; then
            if grep -q '%[HMSZ]' /etc/systemd/system/rh-boot-notify.service \
               && ! grep -q '%%' /etc/systemd/system/rh-boot-notify.service; then
                rhc_bad "юнит rh-boot-notify сломан: неэкранированные %H/%M/%S — о загрузке сервера уведомлений НЕТ"
                rhc_fix "уведомления: меню, пункт 4 (починка) — перепишет юнит правильно"
            elif systemctl is-enabled --quiet rh-boot-notify.service 2>/dev/null; then
                rhc_ok "уведомление о загрузке сервера настроено"
            else
                rhc_warn "rh-boot-notify не включён в автозапуск"
            fi
        else
            rhc_warn "нет юнита уведомления о загрузке сервера"
        fi
        if grep -q 'rh-ssh-login.sh' /etc/pam.d/sshd 2>/dev/null; then
            rhc_ok "уведомление о входе по SSH подключено"
        else
            rhc_warn "уведомление о входе по SSH не подключено"
        fi
        if [[ -f "$PANEL_ENV" ]]; then
            rhc_pwip=$(grep -E '^PANEL_IP=' "$PANEL_ENV" 2>/dev/null | cut -d'"' -f2)
            if systemctl is-active --quiet rh-panel-watch.timer 2>/dev/null; then
                rhc_ok "эта нода дежурная: следит за связью с панелью $rhc_pwip"
            else
                rhc_bad "сторож панели настроен, но таймер не работает"
                rhc_fix "сторож панели: меню, пункт 2 -> 21"
            fi
        else
            rhc_info "эта нода за панелью не следит (сторож включается на одной дежурной, пункт 21)"
        fi
        rhc_conns=$(rhc_num "$(ss -H -tn state established "( sport = :$rhc_np )" 2>/dev/null | grep -c .)")
        if [[ "$rhc_conns" -gt 0 ]]; then
            rhc_ok "панель сейчас держит $rhc_conns соединений с нодой"
        else
            rhc_bad "панель НЕ подключена к этой ноде прямо сейчас"
        fi
    else
        rhc_warn "Telegram-уведомления не настроены — о падении ноды никто не сообщит"
        rhc_fix "уведомления: меню, пункт 2 -> 11"
    fi

    # ----------------------------------------------------------------------
    rhc_sect "Права на файлы с секретами"
    # ----------------------------------------------------------------------
    for rhc_f in "$INSTALL_STATE" "$SETUP_LOG" "$REPORT_FILE"; do
        [[ -f "$rhc_f" ]] || continue
        rhc_perms=$(rhc_perm "$rhc_f")
        if [[ "$rhc_perms" == "600" ]]; then
            rhc_ok "$(basename "$rhc_f"): $rhc_perms"
        else
            rhc_bad "$(basename "$rhc_f"): права $rhc_perms, внутри секреты"
            rhc_fix "права: меню, пункт 4 (починка)"
        fi
    done

    # ----------------------------------------------------------------------
    rhc_sect "Обновления"
    # ----------------------------------------------------------------------
    local rhc_sec
    if command -v unattended-upgrade >/dev/null 2>&1; then
        rhc_ok "автообновления безопасности установлены"
    else
        rhc_warn "unattended-upgrades не установлен"
        rhc_fix "автообновления: меню, пункт 2 -> 13"
    fi
    rhc_sec=$(rhc_num "$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst.*security')")
    if [[ "$rhc_sec" -gt 0 ]]; then
        rhc_warn "ждут установки обновлений безопасности: $rhc_sec"
    else
        rhc_ok "обновления безопасности установлены"
    fi

    # ----------------------------------------------------------------------
    printf '\n\033[1m==========================================\n'
    printf '  ИТОГ: проблем %s, предупреждений %s\n' "$rhc_problems" "$rhc_warnings"
    printf '==========================================\033[0m\n'
    if [[ ${#rhc_fixes[@]} -gt 0 ]]; then
        printf '\nЧто чинить (по убыванию важности):\n'
        printf '  • %s\n' "${rhc_fixes[@]}"
        printf '\nПолную установку заново запускать НЕ НУЖНО: она сбрасывает правила ufw,\n'
        printf 'пересоздаёт контейнер и уходит в перезагрузку. Лечите точечно.\n'
    fi

    [[ "$rhc_problems" -eq 0 ]] && return 0
    return 1
}
