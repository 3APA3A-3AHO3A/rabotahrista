# ##########################################################################
#  GEO-БАЗЫ
#  geoip.dat и geosite.dat от Loyalsoldier для Xray внутри ноды и их
#  ежедневное обновление через cron
# ##########################################################################

# Встроенные в образ ноды базы обновляются только вместе с образом. Свежие базы
# Loyalsoldier выходят каждый день; в них то, по чему маршрутизирует ядро
# (category-ru, geoip ru и т.д.). Поэтому качаем их сами и подключаем томами.

geodata_present() {
    [[ -s "$GEODATA_DIR/geoip.dat" && -s "$GEODATA_DIR/geosite.dat" ]] && return 0
    return 1
}

geodata_mounted() {
    grep -q "$GEODATA_DIR/geosite.dat" /opt/remnanode/docker-compose.yml 2>/dev/null
}

# Скрипт обновления. Он же качает базы при установке — один код на оба случая.
# Логика: сверяем sha256 с опубликованной суммой; одинаковые — ничего не
# делаем; новые — качаем во временный файл рядом, проверяем сумму и только
# потом подменяем. Битая или недокачанная база в ноду не попадёт.
geodata_write_updater() {
    cat <<SCRIPT > "$GEODATA_BIN"
#!/bin/bash
# Обновление geo-баз ноды (rabotahrista). Запускается cron раз в сутки.
#   --no-restart  только скачать, ноду не перезапускать (нужно при установке)
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
DIR="$GEODATA_DIR"
URL="$GEODATA_URL"
LOG=/var/log/rh-geodata.log
NO_RESTART=""; [[ "\${1:-}" == "--no-restart" ]] && NO_RESTART=1
log(){ echo "\$(date '+%F %T') \$*" >> "\$LOG"; }
mkdir -p "\$DIR"
changed="" failed=""
for f in geoip.dat geosite.dat; do
    want=\$(curl -fsSL --max-time 30 "\$URL/\$f.sha256sum" 2>/dev/null | awk '{print \$1}' | head -1)
    if [[ ! "\$want" =~ ^[0-9a-f]{64}\$ ]]; then
        log "\$f: не получил контрольную сумму — пропускаю"; failed+=" \$f"; continue
    fi
    have=\$(sha256sum "\$DIR/\$f" 2>/dev/null | awk '{print \$1}')
    [[ "\$have" == "\$want" ]] && continue
    tmp="\$DIR/.\$f.new"
    if ! curl -fsSL --max-time 300 "\$URL/\$f" -o "\$tmp"; then
        log "\$f: скачивание не удалось"; rm -f "\$tmp"; failed+=" \$f"; continue
    fi
    if [[ "\$(sha256sum "\$tmp" | awk '{print \$1}')" != "\$want" ]]; then
        log "\$f: сумма не совпала — файл битый, оставляю прежний"; rm -f "\$tmp"; failed+=" \$f"; continue
    fi
    chmod 644 "\$tmp"
    mv -f "\$tmp" "\$DIR/\$f"
    log "\$f: обновлён"
    changed+=" \$f"
done
# Ноду перезапускаем, только если базы реально поменялись и подключены в неё.
# Перед перезапуском — метка «плановый», чтобы вотчер не кричал «нода упала».
if [[ -n "\$changed" && -z "\$NO_RESTART" ]] \\
   && grep -q "\$DIR/geosite.dat" /opt/remnanode/docker-compose.yml 2>/dev/null; then
    touch /run/rh-node-planned
    if docker restart remnanode >/dev/null 2>&1; then
        log "нода перезапущена:\$changed"
        [[ -x /usr/local/bin/rh-notify.sh ]] && RH_SILENT=1 /usr/local/bin/rh-notify.sh "🗺 Geo-базы обновлены:\$changed — нода перезапущена"
    else
        log "перезапуск ноды не удался"
        [[ -x /usr/local/bin/rh-notify.sh ]] && /usr/local/bin/rh-notify.sh "⚠️ Geo-базы обновлены:\$changed, но перезапустить ноду не удалось"
    fi
fi
[[ -n "\$failed" ]] && exit 1
exit 0
SCRIPT
    chmod 755 "$GEODATA_BIN"
    return 0
}

comp_geodata() {
    echo ">>> Geo-базы Loyalsoldier..."
    mkdir -p "$GEODATA_DIR"
    geodata_write_updater
    if ! "$GEODATA_BIN" --no-restart; then
        echo "  [СБОЙ] не удалось скачать базы (см. /var/log/rh-geodata.log)"
        tail -3 /var/log/rh-geodata.log 2>/dev/null | sed 's/^/    /'
        geodata_present || return 1
        echo "  Прежние базы на месте — продолжаю с ними."
    fi
    geodata_present || { echo "  [СБОЙ] баз нет после скачивания"; return 1; }
    echo "  Базы на месте: $(du -ch "$GEODATA_DIR"/*.dat | tail -1 | cut -f1)"

    # Минута — своя для каждой ноды, чтобы ноды не ломились на GitHub разом.
    # Время ночное по UTC: перезапуск ноды рвёт соединения на пару секунд.
    if [[ ! -f "$GEODATA_CRON" ]]; then
        printf '# rabotahrista: ежедневная проверка geo-баз ноды\n%d 3 * * * root %s >/dev/null 2>&1\n' \
            $(( RANDOM % 60 )) "$GEODATA_BIN" > "$GEODATA_CRON"
        chmod 644 "$GEODATA_CRON"
    fi
    echo "  Ежедневная проверка: $(grep -v '^#' "$GEODATA_CRON" | awk '{printf "%02d:%02d UTC", $2, $1}')"

    # Нода уже стоит, а тома в compose нет — передеплоим её с томами.
    # В полной установке не нужно: следующим шагом нода и так передеплоится.
    if [[ -z "${RH_FULL_INSTALL:-}" && -f /opt/remnanode/docker-compose.yml ]] && ! geodata_mounted; then
        echo "  Подключаю базы к уже установленной ноде..."
        comp_node || return 1
    fi
    return 0
}
