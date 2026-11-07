# ##########################################################################
#  БЕЗОПАСНОСТЬ
#  Пользователь, харденинг SSH, фаервол, fail2ban
# ##########################################################################

# ##########################################################################
#  КОМПОНЕНТЫ  (тяжёлый вывод уходит в $SETUP_LOG, на экране — только шаги)
# ##########################################################################
comp_user() {
    if [[ -z "$SSH_PUBLIC_KEY" && -n "$NONINTERACTIVE" ]]; then
        echo "  [СБОЙ] SSH_PUBLIC_KEY не задан в конфиге"; return 1
    fi
    ask_ssh_params
    ask_ssh_key
    echo ">>> Пользователь $ADMIN_USER..."
    if ! id "$ADMIN_USER" &>/dev/null; then
        adduser --disabled-password --gecos "" "$ADMIN_USER"
        if [[ -z "$ADMIN_PASS" ]]; then
            ADMIN_PASS=$(openssl rand -base64 18); ADMIN_PASS_SOURCE="generated"
        fi
        echo "$ADMIN_USER:$ADMIN_PASS" | chpasswd
        [[ "$ADMIN_PASS_SOURCE" == "generated" ]] && \
            echo "!!! ПАРОЛЬ $ADMIN_USER@$(hostname): $ADMIN_PASS  (повторю в итоговом отчёте)"
    else
        # Согласие на смену пароля уже получено в ask_admin_password
        if [[ "$ADMIN_PASS_SOURCE" == "manual" && -n "$ADMIN_PASS" ]]; then
            echo "$ADMIN_USER:$ADMIN_PASS" | chpasswd
            echo "  Пароль пользователя $ADMIN_USER изменён."
        else
            ADMIN_PASS=""; ADMIN_PASS_SOURCE="kept"
            echo "  Пользователь $ADMIN_USER уже существует — пароль не трогаю."
        fi
    fi
    usermod -aG sudo "$ADMIN_USER"

    echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$ADMIN_USER"
    chmod 440 "/etc/sudoers.d/90-$ADMIN_USER"
    if ! visudo -c >/dev/null 2>>"$SETUP_LOG"; then
        # Битый sudoers.d ломает sudo целиком, а следом comp_ssh закроет вход под root
        echo "  [СБОЙ] sudoers не проходит проверку — убираю свой файл"
        rm -f "/etc/sudoers.d/90-$ADMIN_USER"
        return 1
    fi

    local H; H=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
    install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$H/.ssh"
    touch "$H/.ssh/authorized_keys"
    grep -qxF "$SSH_PUBLIC_KEY" "$H/.ssh/authorized_keys" || echo "$SSH_PUBLIC_KEY" >> "$H/.ssh/authorized_keys"
    chmod 600 "$H/.ssh/authorized_keys"
    chown -R "$ADMIN_USER:$ADMIN_USER" "$H/.ssh"
    # Дополнительные ключи. Кривой пропускаем с предупреждением, а не роняем
    # установку: вход уже обеспечен основным ключом.
    [[ -n "${SSH_EXTRA_KEYS:-}" ]] && { add_keys_to_user "$ADMIN_USER" "$SSH_EXTRA_KEYS" || true; }

    [[ -s "$H/.ssh/authorized_keys" ]] || { echo "  [СБОЙ] authorized_keys пуст"; return 1; }
    echo "Пользователь готов."
}

# Порты, на которых СЕЙЧАС слушает именно sshd (а не кто попало).
# ss -ltnp показывает процесс; при socket-активации слушателем выступает systemd,
# поэтому его тоже засчитываем — иначе решим, что SSH мёртв, и зря откатимся.
current_sshd_ports() {
    ss -H -ltnp 2>/dev/null \
        | grep -E 'users:\(\("(sshd|systemd)"' \
        | awk '{print $4}' | sed 's/.*://' | sort -un
    return 0
}

sshd_listens_on() {
    grep -qx "$1" <<< "$(current_sshd_ports)"
}

ssh_daemon_active() {
    systemctl is-active --quiet ssh 2>/dev/null && return 0
    systemctl is-active --quiet sshd 2>/dev/null && return 0
    systemctl is-active --quiet ssh.socket 2>/dev/null && return 0
    return 1
}

# sshd применяет ПЕРВОЕ встреченное значение директивы. Если выше строки
# Include в основном sshd_config уже стоит PermitRootLogin yes (так делают
# образы некоторых хостеров), наш файл харденинга лежит ниже и проигрывает:
# порт меняется, а root и пароли остаются открытыми. Такие строки гасим.
ssh_neutralize_conflicts() {
    local inc_line conflicts n
    inc_line=$(grep -nE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' \
               /etc/ssh/sshd_config 2>/dev/null | head -1 | cut -d: -f1)
    [[ -z "$inc_line" ]] && return 0
    conflicts=$(awk -v n="$inc_line" \
        'NR<n && /^[[:space:]]*(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)[[:space:]]/ {print NR}' \
        /etc/ssh/sshd_config 2>/dev/null)
    if [[ -n "$conflicts" ]]; then
        cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
        for n in $conflicts; do
            sed -i "${n}s|^|# отключено харденингом rabotahrista: |" /etc/ssh/sshd_config
        done
        echo "  Выше Include нашлись строки, перебивавшие харденинг — закомментированы (строки: $(echo $conflicts | tr '\n' ' '))"
    fi

    # Дроп-ины читаются по алфавиту, и тот же принцип «первое значение
    # побеждает» действует между ними. Наш файл называется 01-hardening.conf,
    # значит всё, что сортируется раньше (00-*.conf и подобное), перебивает его.
    local f base
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [[ -e "$f" ]] || continue
        base=$(basename "$f")
        [[ "$base" < "$(basename "$SSH_HARDEN_FILE")" ]] || continue
        grep -qE '^[[:space:]]*(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)[[:space:]]' "$f" || continue
        cp -a "$f" "$f.bak.$(date +%Y%m%d%H%M%S)"
        sed -i -E 's|^([[:space:]]*(PermitRootLogin\|PasswordAuthentication\|KbdInteractiveAuthentication\|ChallengeResponseAuthentication)[[:space:]])|# отключено харденингом rabotahrista: \1|' "$f"
        echo "  $base читается раньше нашего файла и перебивал харденинг — строки закомментированы"
    done
    return 0
}

comp_ssh() {
    ask_ssh_params
    echo ">>> Харденинг SSH: порт $SSH_PORT, root закрыт..."
    local H; H=$(getent passwd "$ADMIN_USER" 2>/dev/null | cut -d: -f6)
    if [[ -z "$H" || ! -s "$H/.ssh/authorized_keys" ]]; then
        echo "  [СБОЙ] У $ADMIN_USER нет SSH-ключа — харденинг отменён, иначе потеряете доступ."
        return 1
    fi
    # Без этой строки основной sshd_config вообще не читает каталог sshd_config.d:
    # наш файл лёг бы «в стол», sshd -t прошёл бы, а порт и root остались бы прежними.
    if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
        echo "  В sshd_config нет Include для sshd_config.d — добавляю первой строкой (бэкап рядом)."
        cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
        sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
    fi

    mkdir -p /etc/ssh/sshd_config.d
    cat > "$SSH_HARDEN_FILE" <<EOF
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM yes
# Ноде не нужен проброс графики; 3 попытки и 30 секунд на вход — меньше
# простора для перебора и висящих неавторизованных соединений
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
EOF
    chmod 644 "$SSH_HARDEN_FILE"
    # Облачные образы включают вход по паролю своими дроп-инами. Наш файл сортируется
    # первым и всё равно выигрывает, но глушим и их — на случай нестандартных имён.
    sed -i 's/^PasswordAuthentication/#PasswordAuthentication/' \
        /etc/ssh/sshd_config.d/*cloudimg*.conf /etc/ssh/sshd_config.d/*cloud-init*.conf 2>/dev/null || true

    ssh_neutralize_conflicts

    sshd_rundir
    sshd -t || {
        echo "  [СБОЙ] sshd -t не прошёл — убираю свой файл, SSH не трогаю"
        rm -f "$SSH_HARDEN_FILE"
        return 1
    }

    # Какой порт sshd возьмёт из конфига при следующем старте (читает файлы, не демон)
    local want_port
    want_port=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)

    # Socket-активация (Ubuntu 22.10+): порт держит systemd через ssh.socket,
    # sshd его вообще не открывает, и строка Port в конфиге игнорируется.
    if systemctl cat ssh.socket >/dev/null 2>&1; then
        systemctl disable --now ssh.socket >>"$SETUP_LOG" 2>&1 || true
    fi
    systemctl enable ssh >>"$SETUP_LOG" 2>&1 || systemctl enable sshd >>"$SETUP_LOG" 2>&1 || true
    # Именно restart: "enable --now" НЕ перезапускает уже запущенный демон,
    # поэтому старый порт продолжал жить до перезагрузки.
    systemctl restart ssh >>"$SETUP_LOG" 2>&1 || systemctl restart sshd >>"$SETUP_LOG" 2>&1 || true

    # Проверяем фактом, а не надеждой. Важно: «порт кем-то занят» — это НЕ успех.
    # Если на порту сидит чужой сервис, а sshd не поднялся, старый доступ уже закрыт.
    local i ok=""
    for i in $(seq 1 10); do
        ui_step_status "SSH: жду порт $SSH_PORT ($i/10)"
        if sshd_listens_on "$SSH_PORT"; then ok=1; break; fi
        sleep 1
    done

    if [[ -n "$ok" ]] && ssh_daemon_active; then
        # Порт мог быть таким и до нас — это ничего не доказывает. Проверяем
        # то, ради чего всё затевалось: закрыты ли root и вход по паролю.
        local eff_root eff_pass
        eff_root=$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2}')
        eff_pass=$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')
        if [[ "$eff_root" != "no" || "$eff_pass" != "no" ]]; then
            echo "  [СБОЙ] порт применился, но харденинг — нет: root=$eff_root, пароли=$eff_pass"
            echo "         кто задаёт эти значения:"
            grep -rniE '^[[:space:]]*(PermitRootLogin|PasswordAuthentication)' \
                /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | head -5 | sed 's/^/           /'
            SSH_HARDENED=""
            return 1
        fi
        SSH_HARDENED=1; SSH_PENDING_REBOOT=""
        echo "  Проверено: sshd слушает порт $SSH_PORT, root и вход по паролю закрыты."
        return 0
    fi

    # Демон не работает вообще — это авария, откатываемся немедленно
    if ! ssh_daemon_active; then
        echo "  [СБОЙ] служба sshd не запущена после перезапуска. Откатываю харденинг."
        rm -f "$SSH_HARDEN_FILE"
        systemctl restart ssh >>"$SETUP_LOG" 2>&1 || systemctl restart sshd >>"$SETUP_LOG" 2>&1 || true
        SSH_HARDENED=""; SSH_PENDING_REBOOT=""
        return 1
    fi

    if [[ "$want_port" == "$SSH_PORT" ]] && [[ -n "$(current_sshd_ports)" ]]; then
        # Конфиг принят, но демон не перебиндился. Не откатываем — применится на ребуте,
        # а UFW ниже оставит открытым и старый порт, чтобы не потерять доступ.
        SSH_HARDENED=1; SSH_PENDING_REBOOT=1
        echo "  [ВНИМАНИЕ] sshd принял конфиг (sshd -T показывает порт $SSH_PORT), но пока слушает старый порт."
        echo "             Новый порт заработает после перезагрузки. Старый порт останется открыт в UFW."
        return 0
    fi

    echo "  [СБОЙ] sshd не видит порт $SSH_PORT в своём конфиге (sshd -T показывает '${want_port:-?}')."
    echo "         Значит файл харденинга не читается. Откатываю, чтобы не потерять доступ."
    rm -f "$SSH_HARDEN_FILE"
    systemctl restart ssh >>"$SETUP_LOG" 2>&1 || systemctl restart sshd >>"$SETUP_LOG" 2>&1 || true
    SSH_HARDENED=""; SSH_PENDING_REBOOT=""
    return 1
}

comp_ufw() {
    ask_panel_ip
    echo ">>> Настройка UFW..."
    # Открываем целевой порт + все, на которых SSH может быть прямо сейчас.
    # Иначе при отложенном применении порта фаервол запер бы нас снаружи.
    local ssh_ports p
    ssh_ports="$SSH_PORT"                                       # куда переезжаем
    for p in $(sshd -T 2>/dev/null | awk '/^port /{print $2}'); do ssh_ports+=" $p"; done
    for p in $(current_sshd_ports); do ssh_ports+=" $p"; done   # где sshd сидит прямо сейчас
    ssh_ports=$(printf '%s\n' $ssh_ports | sort -un)
    UFW_SSH_PORTS=""
    for p in $ssh_ports; do UFW_SSH_PORTS+="${UFW_SSH_PORTS:+, }$p/tcp"; done
    echo "  SSH-порты в правилах: $UFW_SSH_PORTS"

    # IPV6=no означает, что ufw вообще не трогает ip6tables: политика остаётся
    # ACCEPT и все порты открыты миру по IPv6. Отключаем фильтрацию, только если
    # стека IPv6 уже нет в ядре — иначе пусть ufw его фильтрует.
    if [[ -d /proc/sys/net/ipv6 ]]; then
        sed -i 's/^IPV6=no/IPV6=yes/' /etc/default/ufw
        echo "  IPv6 ещё активен — фаервол будет фильтровать и его."
    else
        sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw
    fi
    sed -i 's|net/ipv4/icmp_echo_ignore_all=0|net/ipv4/icmp_echo_ignore_all=1|' /etc/ufw/sysctl.conf
    {
        ufw --force reset
        ufw default deny incoming
        ufw default allow outgoing
        for p in $ssh_ports; do ufw limit "$p/tcp" comment 'SSH Rate Limit'; done
        ufw allow 80/tcp comment 'HTTP'
        ufw allow 443/tcp comment 'HTTPS'
        ufw allow 443/udp comment 'QUIC / Hysteria2'
        ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp comment 'API panel'
        ufw --force enable
    } >>"$SETUP_LOG" 2>&1
}

comp_fail2ban() {
    echo ">>> Настройка fail2ban..."
    # python3-systemd нужен для backend=systemd ниже; без него джейл sshd молча не стартует
    apt-get "${APT_WAIT[@]}" install -y fail2ban python3-systemd >>"$SETUP_LOG" 2>&1 || true
    cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled  = true
backend  = systemd
port     = $SSH_PORT
maxretry = 4
bantime  = 24h

[recidive]
enabled  = true
bantime  = 1w
findtime = 1d
maxretry = 5
EOF
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >>"$SETUP_LOG" 2>&1
    # С backend=systemd fail2ban при старте вычитывает журнал за findtime/bantime,
    # на сервере с большим журналом это заметно дольше двух секунд.
    local i
    for i in $(seq 1 15); do
        ui_step_status "fail2ban: жду джейл sshd ($i/15)"
        if fail2ban-client status sshd >>"$SETUP_LOG" 2>&1; then
            return 0
        fi
        sleep 2
    done
    echo "  [СБОЙ] джейл sshd в fail2ban не поднялся за 30 сек (см. $SETUP_LOG)"
    return 1
}

# Добавляет в authorized_keys учётки ключи из многострочной переменной: по
# одному на строку, пустые и закомментированные строки пропускаются, кривые —
# с предупреждением. Возвращает 0, если в файле есть хотя бы один ключ.
add_keys_to_user() {
    local user="$1" keys="$2" H k
    H=$(getent passwd "$user" | cut -d: -f6)
    [[ -n "$H" ]] || return 1
    install -d -m 700 -o "$user" -g "$user" "$H/.ssh"
    touch "$H/.ssh/authorized_keys"
    while IFS= read -r k; do
        k=$(echo "$k" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [[ -z "$k" || "$k" == \#* ]] && continue
        if ssh_key_valid "$k"; then
            grep -qxF "$k" "$H/.ssh/authorized_keys" || echo "$k" >> "$H/.ssh/authorized_keys"
        else
            echo "  [!] Строка не похожа на SSH-ключ, пропущена: ${k:0:40}..."
        fi
    done <<< "$keys"
    chmod 600 "$H/.ssh/authorized_keys"
    chown -R "$user:$user" "$H/.ssh"
    [[ -s "$H/.ssh/authorized_keys" ]] && return 0
    return 1
}

# Учётка ИИ-агента. Без пароля (вход только по ключу), sudo без пароля — агент
# ставит и чинит то же, что и человек. Узнаётся по группе $AGENT_GROUP: по ней
# уведомление о входе пишет «ИИ-агент», а не обычный вход. Файл sudoers назван
# 91-agent-*, а не 90-*: по 90-* установщик находит админ-учётку человека.
comp_agent() {
    validate_agent_params
    if [[ -z "${AGENT_SSH_KEYS:-}" ]]; then
        echo "  Ключ агента не задан (AGENT_SSH_KEYS) — учётку не создаю."
        return 0
    fi
    echo ">>> Учётка ИИ-агента $AGENT_USER..."
    getent group "$AGENT_GROUP" >/dev/null 2>&1 || groupadd "$AGENT_GROUP"
    if ! id "$AGENT_USER" &>/dev/null; then
        adduser --disabled-password --gecos "AI agent (rabotahrista)" "$AGENT_USER" >>"$SETUP_LOG" 2>&1
    fi
    usermod -aG "$AGENT_GROUP" "$AGENT_USER"
    getent group docker >/dev/null 2>&1 && usermod -aG docker "$AGENT_USER"

    local sf="/etc/sudoers.d/91-agent-$AGENT_USER"
    echo "$AGENT_USER ALL=(ALL) NOPASSWD:ALL" > "$sf"
    chmod 440 "$sf"
    if ! visudo -c >/dev/null 2>>"$SETUP_LOG"; then
        echo "  [СБОЙ] sudoers не проходит проверку — убираю файл агента"
        rm -f "$sf"
        return 1
    fi
    if ! add_keys_to_user "$AGENT_USER" "$AGENT_SSH_KEYS"; then
        echo "  [СБОЙ] у $AGENT_USER не оказалось ни одного рабочего ключа"
        return 1
    fi
    echo "  Готово: вход ssh -p $SSH_PORT $AGENT_USER@сервер, sudo без пароля."
    return 0
}

# Ключи сервера, доставшиеся от образа хостера.
#
# Пример с живого сервера: ключи RSA и DSA были подписаны root@ns31561980 —
# именем машины, на которой собирали образ. Значит, у всех серверов из этого
# образа они одинаковые, и любой такой сервер может выдать себя за ваш.
# Признак — имя хоста в подписи ключа не совпадает с именем этого сервера.
# Делается один раз за жизнь сервера (метка в /etc/rabotahrista): иначе после
# смены hostname ключи перевыпускались бы при каждом запуске.
comp_hostkeys() {
    local marker="/etc/rabotahrista/hostkeys.done" f c bad="" stamp hn
    if [[ -f "$marker" ]]; then
        echo "  Ключи сервера уже проверялись — не трогаю."
        return 0
    fi
    mkdir -p "$(dirname "$marker")"
    hn=$(hostname)
    for f in /etc/ssh/ssh_host_*_key.pub; do
        [[ -e "$f" ]] || continue
        c=$(awk '{print $3}' "$f"); c="${c#*@}"
        [[ -z "$c" || "$c" == "$hn" || "$c" == "${hn%%.*}" ]] && continue
        bad+=" $(basename "$f" .pub)(${c})"
    done
    if [[ -z "$bad" ]]; then
        echo "  Ключи сервера выпущены на этом сервере — менять не нужно."
        touch "$marker"
        return 0
    fi
    echo ">>> Ключи сервера достались от образа хостера:$bad"
    echo "    У всех серверов из этого образа они одинаковые — выпускаю свои."
    stamp=$(date +%Y%m%d%H%M%S)
    mkdir -p "$RH_BACKUP_DIR/ssh-hostkeys.$stamp"
    cp -a /etc/ssh/ssh_host_* "$RH_BACKUP_DIR/ssh-hostkeys.$stamp/"
    chmod 700 "$RH_BACKUP_DIR/ssh-hostkeys.$stamp"
    rm -f /etc/ssh/ssh_host_*
    ssh-keygen -A >>"$SETUP_LOG" 2>&1 || true
    if [[ ! -s /etc/ssh/ssh_host_ed25519_key ]]; then
        echo "  [СБОЙ] новые ключи не создались — возвращаю прежние"
        cp -a "$RH_BACKUP_DIR/ssh-hostkeys.$stamp/"ssh_host_* /etc/ssh/
        return 1
    fi
    touch "$marker"
    # Уже открытые сессии не рвутся; новые подключения видят новые ключи
    systemctl try-restart ssh >>"$SETUP_LOG" 2>&1 || true
    echo "  Готово, прежние ключи — в $RH_BACKUP_DIR/ssh-hostkeys.$stamp"
    echo "  Новые отпечатки (при первом входе ssh спросит подтверждение):"
    for f in /etc/ssh/ssh_host_*_key.pub; do
        ssh-keygen -lf "$f" 2>/dev/null | awk '{print "    " $2 "  " $NF}'
    done
    return 0
}

# Отпечаток ключа сервера ED25519 — тот, что ssh покажет при первом входе
hostkey_fingerprint() {
    ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $2}'
    return 0
}

# Готовый профиль для ssh-mcp (config.toml) — входить агентом, а если учётки
# агента нет, то админ-учёткой. Хост — IP, а не домен: за оранжевым облаком
# Cloudflare домен ведёт на Cloudflare, и SSH по нему не пройдёт.
ssh_mcp_profile() {
    local user="$ADMIN_USER" fp name
    if [[ -n "${AGENT_USER:-}" ]] && id "$AGENT_USER" &>/dev/null \
       && id -nG "$AGENT_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$AGENT_GROUP"; then
        user="$AGENT_USER"
    fi
    fp=$(hostkey_fingerprint)
    name="${SUBDOMAIN:-$(hostname -s)}"
    cat <<EOF
[[profiles]]
name = "$name"
host = "${SERVER_IP:-IP_СЕРВЕРА}"
port = $SSH_PORT
user = "$user"
auth = "key"
keyRef = 'C:\Users\ВАШ_ПОЛЬЗОВАТЕЛЬ\.ssh\КЛЮЧ_АГЕНТА'
role = "admin"
approvalPolicy = "auto"
trustedHostKey = "${fp:-неизвестен}"
EOF
    return 0
}
