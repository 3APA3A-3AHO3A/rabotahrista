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
        # Существующей учётке пароль молча не меняем — только если явно попросили
        if [[ "$ADMIN_PASS_SOURCE" == "manual" && -n "$ADMIN_PASS" ]]; then
            local yn="y"
            [[ -z "$NONINTERACTIVE" ]] && read -ep "  Пользователь $ADMIN_USER уже есть. Сменить ему пароль на введённый? [y/N]: " yn
            if [[ "$yn" =~ ^[Yy]$ ]]; then
                echo "$ADMIN_USER:$ADMIN_PASS" | chpasswd
                echo "  Пароль изменён."
            else
                ADMIN_PASS=""; ADMIN_PASS_SOURCE="kept"
                echo "  Пароль оставлен прежним."
            fi
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
    cat > /etc/ssh/sshd_config.d/01-hardening.conf <<EOF
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM yes
EOF
    chmod 644 /etc/ssh/sshd_config.d/01-hardening.conf
    # Облачные образы включают вход по паролю своими дроп-инами. Наш файл сортируется
    # первым и всё равно выигрывает, но глушим и их — на случай нестандартных имён.
    sed -i 's/^PasswordAuthentication/#PasswordAuthentication/' \
        /etc/ssh/sshd_config.d/*cloudimg*.conf /etc/ssh/sshd_config.d/*cloud-init*.conf 2>/dev/null || true

    sshd -t || {
        echo "  [СБОЙ] sshd -t не прошёл — убираю свой файл, SSH не трогаю"
        rm -f /etc/ssh/sshd_config.d/01-hardening.conf
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
        if sshd_listens_on "$SSH_PORT"; then ok=1; break; fi
        sleep 1
    done

    if [[ -n "$ok" ]] && ssh_daemon_active; then
        SSH_HARDENED=1; SSH_PENDING_REBOOT=""
        echo "  Проверено: sshd слушает порт $SSH_PORT прямо сейчас. Текущая сессия не разорвётся."
        return 0
    fi

    # Демон не работает вообще — это авария, откатываемся немедленно
    if ! ssh_daemon_active; then
        echo "  [СБОЙ] служба sshd не запущена после перезапуска. Откатываю харденинг."
        rm -f /etc/ssh/sshd_config.d/01-hardening.conf
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
    rm -f /etc/ssh/sshd_config.d/01-hardening.conf
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
        ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp comment 'API panel'
        ufw --force enable
    } >>"$SETUP_LOG" 2>&1
}

comp_fail2ban() {
    echo ">>> Настройка fail2ban..."
    # python3-systemd нужен для backend=systemd ниже; без него джейл sshd молча не стартует
    apt-get install -y fail2ban python3-systemd >>"$SETUP_LOG" 2>&1 || true
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
        if fail2ban-client status sshd >>"$SETUP_LOG" 2>&1; then
            return 0
        fi
        sleep 2
    done
    echo "  [СБОЙ] джейл sshd в fail2ban не поднялся за 30 сек (см. $SETUP_LOG)"
    return 1
}
