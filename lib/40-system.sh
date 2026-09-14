# ##########################################################################
#  СИСТЕМА
#  Базовая подготовка: swap, пакеты, ядро, диск, автообновления
# ##########################################################################

comp_swap() {
    if [ -n "$(swapon --show)" ]; then
        echo ">>> Swap уже есть, пропускаем."
        return 0
    fi
    echo ">>> Создание Swap 2GB..."
    # Раньше команды шли через ';' и запись в fstab добавлялась даже при провале —
    # получался мёртвый swapfile.swap на каждой загрузке и зелёный шаг в сводке.
    if ! fallocate -l 2G /swapfile >>"$SETUP_LOG" 2>&1; then
        rm -f /swapfile
        if ! dd if=/dev/zero of=/swapfile bs=1M count=2048 >>"$SETUP_LOG" 2>&1; then
            echo "  [СБОЙ] не удалось создать /swapfile (нет места или ФС не поддерживает)"
            rm -f /swapfile; return 1
        fi
    fi
    chmod 600 /swapfile
    if ! mkswap /swapfile >>"$SETUP_LOG" 2>&1 || ! swapon /swapfile >>"$SETUP_LOG" 2>&1; then
        echo "  [СБОЙ] mkswap/swapon не отработали (см. $SETUP_LOG)"
        rm -f /swapfile; return 1
    fi
    # В fstab пишем только после того, как swap реально включился
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    return 0
}

comp_packages() {
    echo ">>> Обновление системы и установка пакетов (в фоне, лог: $SETUP_LOG)..."
    local rc=0
    {
        apt-get clean
        apt-get update
        apt-get -y upgrade
        apt-get -y dist-upgrade
        apt-get -y autoremove --purge
        apt-get -y install $APT_PACKAGES
    } >>"$SETUP_LOG" 2>&1 || rc=$?
    systemctl enable --now chrony >/dev/null 2>&1 || systemctl enable --now chronyd >/dev/null 2>&1 || true
    if [[ $rc -ne 0 ]]; then
        echo "  [СБОЙ] apt завершился с ошибкой (см. $SETUP_LOG)."
        echo "         Без пакетов следующие шаги тоже посыплются — разберитесь с apt и повторите."
        return 1
    fi
    # Проверяем не «apt отработал», а что ключевое реально на месте
    # Проверяем по ИМЕНИ КОМАНДЫ, а оно не всегда совпадает с именем пакета:
    # у fail2ban исполняемый файл называется fail2ban-client.
    local miss=""
    for pkg in nginx certbot ufw fail2ban-client jq; do
        command -v "$pkg" >/dev/null 2>&1 || miss+=" $pkg"
    done
    if [[ -n "$miss" ]]; then
        echo "  [СБОЙ] после установки не найдены:$miss"
        return 1
    fi
    return 0
}

comp_sysctl() {
    echo ">>> Тюнинг ядра (sysctl)..."
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    modprobe tcp_bbr || true
    cat <<EOF > /etc/sysctl.d/99-vpn-tune.conf
fs.file-max=1048576

net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# Меньше уводим в swap
vm.swappiness=10

# Отключаем icmp ping
net.ipv4.icmp_echo_ignore_all=1

# Диапазон исходящих портов
net.ipv4.ip_local_port_range = 1024 65535

# FIN-WAIT-2
net.ipv4.tcp_fin_timeout = 15

# TCP Keepalive
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
EOF
    # Ключи ipv6 существуют, только пока стек ipv6 в ядре жив. После ipv6.disable=1
    # из GRUB их нет, и sysctl --system падает с ошибкой на пустом месте.
    if [[ -d /proc/sys/net/ipv6 ]]; then
        cat <<EOF >> /etc/sysctl.d/99-vpn-tune.conf

# Отключаем ipv6
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF
    else
        echo -e "\n# ipv6 уже отключён в ядре (ipv6.disable=1 в GRUB) — ключи sysctl не нужны" \
            >> /etc/sysctl.d/99-vpn-tune.conf
    fi
    sysctl --system >>"$SETUP_LOG" 2>&1
}

comp_ipv6() {
    echo ">>> Отключение IPv6 в GRUB..."
    if ! grep -q "ipv6.disable=1" /etc/default/grub; then
        sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="ipv6.disable=1 /' /etc/default/grub
        update-grub >>"$SETUP_LOG" 2>&1
    fi
}

comp_disk() {
    echo ">>> Защита диска: ротация логов Docker + journald..."
    mkdir -p /etc/docker
    if [[ -f /etc/docker/daemon.json ]]; then
        # Чужой daemon.json не перезаписываем: там могут быть data-root, dns,
        # registry-mirrors. Только аккуратно домешиваем настройки логов через jq.
        if ! command -v jq >/dev/null 2>&1; then
            echo "  [СБОЙ] /etc/docker/daemon.json уже есть, а jq нет — не рискую его перезаписывать"
            return 1
        fi
        tmp=$(mktemp)
        if jq '. + {"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' /etc/docker/daemon.json > "$tmp" 2>/dev/null; then
            mv "$tmp" /etc/docker/daemon.json
        else
            rm -f "$tmp"
            echo "  [СБОЙ] /etc/docker/daemon.json не разбирается как JSON — не трогаю его"
            return 1
        fi
    else
        cat <<'EOF' > /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
    fi
    systemctl restart docker >>"$SETUP_LOG" 2>&1 || true
    mkdir -p /etc/systemd/journald.conf.d
    cat <<'EOF' > /etc/systemd/journald.conf.d/size.conf
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
EOF
    systemctl restart systemd-journald >>"$SETUP_LOG" 2>&1 || true
}

comp_autoupdates() {
    echo ">>> Автообновления безопасности..."
    apt-get install -y unattended-upgrades >>"$SETUP_LOG" 2>&1 || true
    cat <<'EOF' > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    cat <<'EOF' > /etc/apt/apt.conf.d/52unattended-upgrades-local
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
    systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
    if ! command -v unattended-upgrade >/dev/null 2>&1; then
        echo "  [СБОЙ] unattended-upgrades не установлен — автообновлений безопасности не будет"
        return 1
    fi
    return 0
}

comp_os_update() {
    echo ">>> Полное обновление системы (apt). Вывод — на экран."
    if apt-get clean && apt-get update && apt-get -y upgrade && apt-get -y dist-upgrade && apt-get -y autoremove --purge; then
        echo "  Обновление завершено успешно."
        notify_telegram "🧰 ОС обновлена, ухожу в перезагрузку ($(date '+%H:%M:%S'))"
        echo "  Перезагрузка через 5 секунд (Ctrl+C — отменить)..."
        sleep 5
        reboot
    else
        echo "  [СБОЙ] apt-обновление завершилось с ошибкой — перезагрузка отменена."
        return 1
    fi
}
