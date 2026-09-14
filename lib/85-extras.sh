# ##########################################################################
#  ДОПОЛНЕНИЯ
#  Необязательные компоненты и диагностика
# ##########################################################################

comp_warp() {
    echo ">>> Установка/переустановка Cloudflare WARP..."
    {
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/cloudflare-client.list

        apt-get update
        apt-get install -y cloudflare-warp

        warp-cli --accept-tos registration new || echo "y" | warp-cli registration new

        warp-cli --accept-tos mode proxy || warp-cli mode proxy
        warp-cli --accept-tos proxy port "$WARP_PORT" || warp-cli proxy port "$WARP_PORT"

        warp-cli --accept-tos connect || warp-cli connect
    } >>"$SETUP_LOG" 2>&1 || { echo "  Ошибка установки WARP (см. $SETUP_LOG)"; return 1; }
}

comp_speedtest() {
    echo ">>> Установка Speedtest CLI..."
    {
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
        if grep -q "noble" /etc/apt/sources.list.d/ookla_speedtest-cli.list 2>/dev/null; then
            sed -i 's/noble/jammy/g' /etc/apt/sources.list.d/ookla_speedtest-cli.list; apt-get update
        fi
        apt-get install -y speedtest
    } >>"$SETUP_LOG" 2>&1 || { echo "  Speedtest не установился (см. $SETUP_LOG)"; return 1; }
}

run_bench() { echo ">>> bench.sh..."; wget -qO- bench.sh | bash || true; }

run_geo()   { echo ">>> ipregion.sh..."; bash <(wget -qO- https://raw.githubusercontent.com/Davoyan/ipregion/main/ipregion.sh) || true; }

run_censor() { echo ">>> Проверка блокировок/DPI/DNS (censorcheck)..."; bash <(wget -qO- https://raw.githubusercontent.com/vernette/censorcheck/master/censorcheck.sh) || true; }
