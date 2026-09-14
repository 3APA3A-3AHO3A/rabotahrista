#!/bin/bash
# ##########################################################################
#  ДИАГНОСТИКА НОДЫ rabotahrista
#
#  Скрипт НИЧЕГО НЕ МЕНЯЕТ. Только читает и рассказывает, что нашёл.
#  Это сознательное ограничение: его безопасно запускать на живой ноде
#  в любой момент, он не трогает ни конфиги, ни сервисы, ни фаервол.
#
#      bash <(curl -fsSL .../check.sh)           быстрая проверка
#      bash <(curl -fsSL .../check.sh) --deep    + тест продления сертификата
# ##########################################################################

set -uo pipefail

NOTIFY_ENV="/etc/rabotahrista/notify.env"
INSTALL_STATE="/etc/rabotahrista/install.conf"
COMPOSE="/opt/remnanode/docker-compose.yml"
DEEP=""
[[ "${1:-}" == "--deep" ]] && DEEP=1

if locale -a 2>/dev/null | grep -qix 'C\.UTF-*8'; then export LC_ALL=C.UTF-8; fi
[[ "$EUID" -ne 0 ]] && { echo "Запустите под root: sudo bash ..."; exit 1; }

PROBLEMS=0
WARNINGS=0
FIXES=()

ok()   { printf '  \033[32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m[ ?? ]\033[0m %s\n' "$*"; WARNINGS=$((WARNINGS+1)); }
bad()  { printf '  \033[31m[ !! ]\033[0m %s\n' "$*"; PROBLEMS=$((PROBLEMS+1)); }
info() { printf '         %s\n' "$*"; }
sect() { printf '\n\033[1m── %s\033[0m\n' "$*"; }
fix()  { FIXES+=("$*"); }

# Порты, на которых сейчас слушает SSH (при socket-активации слушателем будет systemd)
sshd_ports() {
    ss -H -ltnp 2>/dev/null | grep -E 'users:\(\("(sshd|systemd)"' \
        | awk '{print $4}' | sed 's/.*://' | sort -un
}
listening() { ss -H -ltn 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -un; }
has_port()  { grep -qx "$1" <<< "$(listening)"; }
perm_of()   { stat -c '%a' "$1" 2>/dev/null || echo "?"; }
# grep -c при нуле совпадений печатает "0" И возвращает ненулевой код.
# Из-за этого "|| echo 0" дописывал второй ноль, получалось "0\n0",
# и арифметическое сравнение падало с syntax error.
num()       { local v; v=$(printf '%s' "${1:-}" | head -1 | tr -cd '0-9'); echo "${v:-0}"; }

printf '\033[1m==========================================\n'
printf '  ДИАГНОСТИКА НОДЫ  —  %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
printf '==========================================\033[0m\n'

# --------------------------------------------------------------------------
sect "Система"
# --------------------------------------------------------------------------
info "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") | ядро $(uname -r)"
info "хост $(hostname) | uptime $(uptime -p 2>/dev/null || echo '?')"
EXT_IP=$(curl -fs --max-time 8 https://api.ipify.org 2>/dev/null || echo "")
info "внешний IP: ${EXT_IP:-не определился}"

if [[ -f "$INSTALL_STATE" ]]; then
    ok "install.conf найден — нода ставилась этим скриптом"
    # shellcheck disable=SC1090
    source "$INSTALL_STATE" 2>/dev/null || true
else
    warn "нет $INSTALL_STATE — нода ставилась вручную или очень старой версией"
    info "повторный запуск setup.sh не подставит прошлые ответы, а предложит дефолты"
fi
NODE_PORT="${NODE_PORT:-2222}"

if [[ -z "$(swapon --show 2>/dev/null)" ]]; then
    warn "swap не подключён"
    fix "swap: меню setup.sh, пункт 7"
else
    ok "swap: $(swapon --show=SIZE --noheadings 2>/dev/null | tr -d ' \n')"
fi

# --------------------------------------------------------------------------
sect "SSH"
# --------------------------------------------------------------------------
if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null; then
    ok "sshd_config читает каталог sshd_config.d"
else
    if [[ -f /etc/ssh/sshd_config.d/01-hardening.conf ]]; then
        bad "файл харденинга есть, но sshd_config его НЕ ЧИТАЕТ — настройки не применены"
        fix "SSH: добавить 'Include /etc/ssh/sshd_config.d/*.conf' первой строкой в /etc/ssh/sshd_config"
    else
        info "sshd_config.d не подключён, но и файла харденинга нет"
    fi
fi

CFG_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
LIVE_PORTS=$(sshd_ports | tr '\n' ' ')
info "порт в конфиге: ${CFG_PORT:-?} | слушает сейчас: ${LIVE_PORTS:-никто}"
if [[ -n "$CFG_PORT" ]] && grep -qx "$CFG_PORT" <<< "$(sshd_ports)"; then
    ok "sshd слушает тот порт, что указан в конфиге"
elif [[ -n "$LIVE_PORTS" ]]; then
    warn "порт из конфига не совпадает с рабочим — настройки применятся после перезагрузки"
else
    bad "sshd не слушает вообще ничего"
fi

ROOTLOGIN=$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2}')
PASSAUTH=$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')
if [[ -z "$ROOTLOGIN$PASSAUTH" ]]; then
    warn "не удалось прочитать настройки sshd (sshd -T) — sshd не установлен?"
else
    [[ "$ROOTLOGIN" == "no" ]] && ok "вход под root запрещён" \
        || { bad "вход под root разрешён ($ROOTLOGIN)"; fix "SSH: меню setup.sh, пункт 8"; }
    [[ "$PASSAUTH" == "no" ]] && ok "вход по паролю запрещён" \
        || { bad "вход по паролю разрешён ($PASSAUTH)"; fix "SSH: меню setup.sh, пункт 8"; }
fi

if [[ -n "${ADMIN_USER:-}" ]] && id "$ADMIN_USER" &>/dev/null; then
    AH=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
    KEYS=$(num "$(grep -cvE '^[[:space:]]*(#|$)' "$AH/.ssh/authorized_keys" 2>/dev/null)")
    [[ "$KEYS" -gt 0 ]] && ok "у $ADMIN_USER ключей: $KEYS" || bad "у $ADMIN_USER нет ни одного SSH-ключа"
fi

# --------------------------------------------------------------------------
sect "Фаервол"
# --------------------------------------------------------------------------
if ufw status 2>/dev/null | head -1 | grep -q 'active'; then
    ok "ufw включён"
    for p in $(sshd_ports); do
        ufw status 2>/dev/null | grep -qE "(^| )$p/tcp" \
            && ok "SSH-порт $p открыт в ufw" \
            || { bad "SSH-порт $p НЕ открыт в ufw — после разрыва сессии не зайти"; fix "ufw: ufw limit $p/tcp"; }
    done
    if ufw status 2>/dev/null | grep -q "$NODE_PORT"; then
        ok "порт ноды $NODE_PORT есть в правилах"
    else
        bad "порт ноды $NODE_PORT не открыт — панель не достучится"
        fix "ufw: ufw allow from <IP панели> to any port $NODE_PORT proto tcp"
    fi
    IPV6_SET=$(grep -E '^IPV6=' /etc/default/ufw 2>/dev/null | cut -d= -f2)
    if [[ -d /proc/sys/net/ipv6 ]]; then
        if [[ "$IPV6_SET" == "yes" ]]; then
            ok "IPv6 живой и фильтруется фаерволом"
        else
            bad "IPv6 активен, но ufw его НЕ фильтрует (IPV6=$IPV6_SET) — все порты открыты по IPv6"
            fix "IPv6: поставить IPV6=yes в /etc/default/ufw и ufw reload, либо отключить IPv6 в GRUB"
        fi
    else
        ok "IPv6 отключён в ядре — фильтровать нечего"
    fi
else
    bad "ufw выключен"
    fix "ufw: меню setup.sh, пункт 5"
fi

if systemctl is-active --quiet fail2ban 2>/dev/null; then
    if fail2ban-client status sshd >/dev/null 2>&1; then
        BANNED=$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned/{print $2}' | tr -d ' ')
        ok "fail2ban работает, джейл sshd активен (забанено сейчас: ${BANNED:-0})"
    else
        bad "fail2ban запущен, но джейл sshd НЕ поднялся — брутфорс никто не блокирует"
        dpkg -l python3-systemd 2>/dev/null | grep -q '^ii' \
            || fix "fail2ban: apt-get install -y python3-systemd && systemctl restart fail2ban"
    fi
else
    bad "fail2ban не запущен"
    fix "fail2ban: меню setup.sh, пункт 12"
fi

# --------------------------------------------------------------------------
sect "Нода"
# --------------------------------------------------------------------------
if [[ -f "$COMPOSE" ]]; then
    P=$(perm_of "$COMPOSE")
    [[ "$P" == "600" ]] && ok "docker-compose.yml с правами 600" \
        || { bad "docker-compose.yml с правами $P — SECRET_KEY ноды читает любой пользователь"; fix "права: chmod 600 $COMPOSE && chmod 700 /opt/remnanode"; }
else
    bad "нет $COMPOSE — нода не развёрнута"
fi

if command -v docker >/dev/null 2>&1; then
    STATE=$(docker inspect -f '{{.State.Status}}' remnanode 2>/dev/null | head -1 | tr -d '\n')
    [[ -z "$STATE" ]] && STATE="контейнера нет"
    RESTARTS=$(docker inspect -f '{{.RestartCount}}' remnanode 2>/dev/null || echo "?")
    IMG=$(docker inspect -f '{{.Config.Image}}' remnanode 2>/dev/null || echo "?")
    if [[ "$STATE" == "running" ]]; then
        ok "контейнер remnanode: running (перезапусков: $RESTARTS, образ $IMG)"
        [[ "${RESTARTS:-0}" -gt 5 ]] && warn "много перезапусков — смотри docker logs remnanode"
    else
        bad "контейнер remnanode: $STATE"
        fix "нода: cd /opt/remnanode && docker compose up -d"
    fi
    has_port "$NODE_PORT" && ok "порт $NODE_PORT слушает — панель сможет подключиться" \
        || bad "порт $NODE_PORT не слушает — панель ноду не увидит"
else
    bad "docker не установлен"
fi

# --------------------------------------------------------------------------
sect "Сертификат и nginx"
# --------------------------------------------------------------------------
FULL_DOMAIN="${SUBDOMAIN:-}${SUBDOMAIN:+.}${DOMAIN:-}"
CERTDIR=$(ls -d /etc/letsencrypt/live/*/ 2>/dev/null | head -1)
if [[ -n "$CERTDIR" ]]; then
    CN=$(basename "$CERTDIR")
    END=$(openssl x509 -enddate -noout -in "$CERTDIR/fullchain.pem" 2>/dev/null | cut -d= -f2)
    DAYS=$(( ( $(date -d "$END" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
    if [[ "$DAYS" -gt 25 ]]; then ok "сертификат $CN: осталось $DAYS дн."
    elif [[ "$DAYS" -gt 0 ]]; then bad "сертификат $CN истекает через $DAYS дн. — продление не сработало"
    else bad "сертификат $CN ПРОСРОЧЕН"; fi

    NGX="/etc/nginx/sites-available/${FULL_DOMAIN:-$CN}"
    if [[ -f "$NGX" ]]; then
        if awk '/listen .*8443/,0' "$NGX" | grep -q 'acme-challenge'; then
            ok "в TLS-блоке nginx есть путь для ACME — продление по HTTPS пройдёт"
        else
            bad "в TLS-блоке nginx НЕТ пути для ACME"
            info "при «Always Use HTTPS» в Cloudflare продление тихо провалится через ~60 дней"
            fix "сертификат: меню setup.sh, пункт 4 (перезапишет конфиг nginx правильно)"
        fi
    fi
    AUTH=$(grep -h '^authenticator' /etc/letsencrypt/renewal/*.conf 2>/dev/null | head -1 | awk '{print $3}')
    info "способ продления: ${AUTH:-неизвестен}"
else
    warn "сертификатов Let's Encrypt не найдено"
fi

if systemctl is-active --quiet nginx 2>/dev/null; then
    nginx -t >/dev/null 2>&1 && ok "nginx работает, конфиг валиден" || bad "nginx работает, но конфиг невалиден (nginx -t)"
    ENABLED=$(ls /etc/nginx/sites-enabled/ 2>/dev/null | wc -l)
    [[ "$ENABLED" -gt 1 ]] && warn "в sites-enabled $ENABLED конфигов — возможен конфликт default_server"
else
    bad "nginx не запущен"
fi

if [[ -n "$DEEP" ]] && command -v certbot >/dev/null 2>&1 && [[ -n "$CERTDIR" ]]; then
    info "проверяю продление вживую (certbot --dry-run, до минуты)..."
    if certbot renew --dry-run >/dev/null 2>&1; then
        ok "тестовое продление прошло — сертификат продлится сам"
    else
        bad "тестовое продление ПРОВАЛИЛОСЬ — через 90 дней сертификат умрёт"
        info "подробности: certbot renew --dry-run"
    fi
fi

# --------------------------------------------------------------------------
sect "Уведомления"
# --------------------------------------------------------------------------
if [[ -f "$NOTIFY_ENV" ]]; then
    P=$(perm_of "$NOTIFY_ENV")
    [[ "$P" == "600" ]] && ok "notify.env с правами 600" || bad "notify.env с правами $P — токен бота читает любой"
    for u in rh-node-watch.service rh-node-health.timer; do
        systemctl is-active --quiet "$u" 2>/dev/null && ok "$u работает" \
            || { bad "$u не работает — о падении ноды не узнаете"; fix "уведомления: меню setup.sh, пункт 11"; }
    done
    # Юнит уведомления о загрузке долго был сломан: systemd съедает %H/%M/%S
    if [[ -f /etc/systemd/system/rh-boot-notify.service ]]; then
        if grep -q '%[HMSZ]' /etc/systemd/system/rh-boot-notify.service && ! grep -q '%%' /etc/systemd/system/rh-boot-notify.service; then
            bad "юнит rh-boot-notify сломан: неэкранированные %H/%M/%S — о загрузке сервера уведомлений НЕТ"
            fix "уведомления: меню setup.sh, пункт 11 (перепишет юнит правильно)"
        elif systemctl is-enabled --quiet rh-boot-notify.service 2>/dev/null; then
            ok "уведомление о загрузке сервера настроено"
        else
            warn "rh-boot-notify не включён в автозапуск"
        fi
    else
        warn "нет юнита уведомления о загрузке сервера"
    fi
    grep -q 'rh-ssh-login.sh' /etc/pam.d/sshd 2>/dev/null \
        && ok "уведомление о входе по SSH подключено" \
        || warn "уведомление о входе по SSH не подключено"
    if [[ -f /etc/rabotahrista/panel.env ]]; then
        # shellcheck disable=SC1091
        PW_IP=$(grep -E '^PANEL_IP=' /etc/rabotahrista/panel.env | cut -d'"' -f2)
        if systemctl is-active --quiet rh-panel-watch.timer 2>/dev/null; then
            ok "эта нода дежурная: следит за связью с панелью $PW_IP"
        else
            bad "сторож панели настроен, но таймер не работает"
            fix "сторож панели: меню setup.sh, пункт 21"
        fi
    else
        info "эта нода за панелью не следит (сторож включается на одной дежурной, пункт 21)"
    fi
    CONNS=$(num "$(ss -H -tn state established "( sport = :$NODE_PORT )" 2>/dev/null | grep -c .)")
    if [[ "$CONNS" -gt 0 ]]; then
        ok "панель сейчас держит $CONNS соединений с нодой"
    else
        bad "панель НЕ подключена к этой ноде прямо сейчас"
    fi
else
    warn "Telegram-уведомления не настроены — о падении ноды никто не сообщит"
    fix "уведомления: меню setup.sh, пункт 11"
fi

# --------------------------------------------------------------------------
sect "Права на файлы с секретами"
# --------------------------------------------------------------------------
for f in "$INSTALL_STATE" /var/log/node-setup.log /root/node-install-report.txt; do
    [[ -f "$f" ]] || continue
    P=$(perm_of "$f")
    [[ "$P" == "600" ]] && ok "$(basename "$f"): $P" \
        || { bad "$(basename "$f"): права $P, внутри секреты"; fix "права: chmod 600 $f"; }
done

# --------------------------------------------------------------------------
sect "Обновления"
# --------------------------------------------------------------------------
command -v unattended-upgrade >/dev/null 2>&1 && ok "автообновления безопасности установлены" \
    || { warn "unattended-upgrades не установлен"; fix "автообновления: меню setup.sh, пункт 13"; }
SEC=$(num "$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst.*security')")
[[ "$SEC" -gt 0 ]] && warn "ждут установки обновлений безопасности: $SEC" || ok "обновления безопасности установлены"

# --------------------------------------------------------------------------
printf '\n\033[1m==========================================\n'
printf '  ИТОГ: проблем %s, предупреждений %s\n' "$PROBLEMS" "$WARNINGS"
printf '==========================================\033[0m\n'
if [[ ${#FIXES[@]} -gt 0 ]]; then
    printf '\nЧто чинить (по убыванию важности):\n'
    printf '  • %s\n' "${FIXES[@]}"
    printf '\nПолную установку заново запускать НЕ НУЖНО: она сбрасывает правила ufw,\n'
    printf 'пересоздаёт контейнер и уходит в перезагрузку. Лечите точечно через меню.\n'
fi
[[ $PROBLEMS -eq 0 ]]
