#!/bin/bash
# Прогон всех проверок, которые можно сделать без сервера.
# Запуск:  bash tests/run-tests.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
FAILED=0
PASSED=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASSED=$((PASSED+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILED=$((FAILED+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Тестовый SSH-ключ. Проверка ключа в скрипте настоящая (через ssh-keygen),
# поэтому строка-пустышка не годится: с ней тесты проходили только там, где
# ssh-keygen не установлен, и падали на любой машине, где он есть.
TESTKEY=""
if command -v ssh-keygen >/dev/null 2>&1; then
    _kf=$(mktemp -u)
    ssh-keygen -q -t ed25519 -N "" -f "$_kf" <<< y >/dev/null 2>&1
    TESTKEY=$(cat "$_kf.pub" 2>/dev/null || true)
    rm -f "$_kf" "$_kf.pub"
fi
# Без ssh-keygen проверка ключа пропускается, поэтому годится любая непустая строка
TESTKEY="${TESTKEY:-ssh-ed25519 AAAAtest test@no-keygen}"

# --------------------------------------------------------------------------
head_ "1. Синтаксис"
# --------------------------------------------------------------------------
for f in lib/*.sh check.sh changedomain.sh; do
    if bash -n "$f" 2>/dev/null; then ok "bash -n $f"; else bad "bash -n $f"; bash -n "$f"; fi
done

# --------------------------------------------------------------------------
head_ "2. Сборка"
# --------------------------------------------------------------------------
if python3 build.py >/dev/null 2>&1; then ok "build.py отработал"; else bad "build.py упал"; fi
if bash -n setup.sh 2>/dev/null; then ok "bash -n setup.sh"; else bad "bash -n setup.sh"; bash -n setup.sh; fi
if python3 build.py --check >/dev/null 2>&1; then ok "setup.sh совпадает с lib/"; else bad "setup.sh устарел"; fi
if head -1 setup.sh | grep -q '^#!/bin/bash'; then ok "shebang на первой строке"; else bad "нет shebang"; fi
if grep -qU $'\r' setup.sh; then bad "в setup.sh есть CRLF — на сервере сломается"; else ok "переводы строк LF"; fi

# --------------------------------------------------------------------------
head_ "3. Статическая проверка кодов возврата"
# --------------------------------------------------------------------------
if python3 tests/check_returns.py; then ok "ни одна функция не заканчивается голым условием"
else bad "есть функции, которые молча убьют скрипт"; fi

# --------------------------------------------------------------------------
head_ "4. Функции реально возвращают 0, когда спрашивать нечего"
# --------------------------------------------------------------------------
# Это тот самый сценарий повторной установки: все ответы уже сохранены,
# ни один вопрос не задаётся, и функция не должна вернуть ненулевой код.
RH_TEST_OUT=$(mktemp)
RH_LIB_ONLY=1 bash -c '
    set -e
    source "'"$ROOT"'/setup.sh"
    # всё заполнено — ни один read не должен сработать
    DOMAIN="example.com"; SUBDOMAIN="node-1"; PANEL_IP="1.2.3.4"
    REMNA_SECRET="secret"; SSH_PUBLIC_KEY="'"$TESTKEY"'"
    ADMIN_USER="deploy"; SSH_PORT="45123"; ADMIN_PASS="pass"
    SETUP_CF="n"; CF_API_TOKEN=""; CF_PROXY_CHOICE="n"
    TG_BOT_TOKEN="123:ABC"; TG_CHAT_ID="-100123"; TG_TOPIC_ID="7"
    NONINTERACTIVE=1
    for fn in ask_domain ask_subdomain ask_panel_ip ask_secret ask_ssh_key \
              validate_ssh_params ask_ssh_params ask_cf ask_telegram skip_step; do
        if ! "$fn" "проверка" >/dev/null 2>&1; then
            echo "НЕНУЛЕВОЙ КОД: $fn"
        fi
    done
    row "метка" "значение" >/dev/null || echo "НЕНУЛЕВОЙ КОД: row"
' > "$RH_TEST_OUT" 2>&1
RC=$?
if [[ $RC -ne 0 ]]; then
    bad "загрузка функций упала (код $RC)"; sed 's/^/      /' "$RH_TEST_OUT"
elif grep -q "НЕНУЛЕВОЙ КОД" "$RH_TEST_OUT"; then
    bad "функции возвращают ненулевой код при заполненных ответах"
    sed 's/^/      /' "$RH_TEST_OUT"
else
    ok "все опросные функции возвращают 0"
fi
rm -f "$RH_TEST_OUT"

# --------------------------------------------------------------------------
head_ "5. Проверка ввода"
# --------------------------------------------------------------------------
VAL=$(RH_LIB_ONLY=1 bash -c '
    source "'"$ROOT"'/setup.sh"
    NONINTERACTIVE=1
    ADMIN_USER="root"; SSH_PORT="99999"; validate_ssh_params >/dev/null 2>&1
    echo "$ADMIN_USER:$SSH_PORT"
')
if [[ "$VAL" == "admin:8422" ]]; then ok "мусор в ADMIN_USER/SSH_PORT откатывается на дефолты"
else bad "validate_ssh_params вернула '$VAL', ожидалось 'admin:8422'"; fi

# --------------------------------------------------------------------------
head_ "6. Нет хардкода портов в обход переменных"
# --------------------------------------------------------------------------
# Числа портов должны встречаться только там, где переменные объявляются.
# Иначе при смене порта половина скрипта продолжит смотреть на старый.
HARDCODED=$(grep -n '2222\|6000' lib/*.sh \
            | grep -v '^lib/00-header.sh' \
            | grep -v 'NODE_PORT\|WARP_PORT' \
            | grep -v ':[0-9]*:[[:space:]]*#' || true)
if [[ -n "$HARDCODED" ]]; then
    bad "порты зашиты мимо переменных:"
    echo "$HARDCODED" | sed 's/^/      /'
else
    ok "порты ноды и WARP везде через переменные"
fi

# --------------------------------------------------------------------------
head_ "7. Повторная установка доходит до конца (регрессия)"
# --------------------------------------------------------------------------
# Сценарий, который ломался: все ответы уже сохранены с прошлого раза,
# Telegram настроен, скрипт не задаёт ни одного вопроса — и обрывался молча
# сразу после "--- Telegram-уведомления ---", не дойдя до установки.
E2E=$(mktemp)
# Важно: режим именно ИНТЕРАКТИВНЫЙ (NONINTERACTIVE пустой) — в неинтерактивном
# блок с вызовом ask_telegram пропускается, и баг не воспроизводится.
# На stdin три Enter (учётка/пароль/порт) и два "n" в конце.
printf '\n\n\n\n\n\nn\nn\nn\n' | RH_LIB_ONLY=1 bash -c '
    set -e
    source "'"$ROOT"'/setup.sh"
    DOMAIN="example.com"; SUBDOMAIN="node-1"; PANEL_IP="1.2.3.4"
    REMNA_SECRET="secret"; SSH_PUBLIC_KEY="'"$TESTKEY"'"
    ADMIN_USER="deploy"; SSH_PORT="45123"
    INSTALL_WARP="n"; INSTALL_SPEEDTEST="n"
    SETUP_CF="n"; CF_PROXY_CHOICE="n"
    SETUP_TG="y"; TG_BOT_TOKEN="123:ABC"; TG_CHAT_ID="-100123"; TG_TOPIC_ID="7"
    INSTALL_STATE=$(mktemp); SETUP_LOG=$(mktemp); REPORT_FILE=$(mktemp)
    for f in comp_swap comp_packages comp_user comp_ssh comp_fail2ban comp_autoupdates \
             comp_ipv6 comp_ufw comp_sysctl comp_docker comp_disk comp_speedtest \
             comp_warp comp_node comp_web comp_telegram notify_telegram reboot \
             components_menu; do
        eval "$f(){ return 0; }"
    done
    full_install >/dev/null
    echo "ДОШЛИ ДО КОНЦА"
' > "$E2E" 2>&1
if grep -q "ДОШЛИ ДО КОНЦА" "$E2E"; then
    ok "повторная установка с заполненным Telegram не обрывается"
else
    bad "повторная установка обрывается (тот самый баг):"
    tail -15 "$E2E" | sed 's/^/      /'
fi
rm -f "$E2E"

# --------------------------------------------------------------------------
head_ "8. Авария внутри функции объясняется, а не проходит молча"
# --------------------------------------------------------------------------
# Без "set -E" ERR-трап не наследуется функциями: скрипт просто исчезал,
# не написав ни строки о том, что и где сломалось.
TRAP_OUT=$(RH_LIB_ONLY=1 bash -c '
    source "'"$ROOT"'/setup.sh"
    SETUP_LOG=/tmp/rh-test.log
    broken() { ls /definitely-no-such-path-here; }
    broken
' 2>&1 || true)
if grep -q "ОШИБКА — установка прервана" <<< "$TRAP_OUT" \
   && grep -q "в функции:    broken()" <<< "$TRAP_OUT"; then
    ok "падение внутри функции печатает команду и имя функции"
else
    bad "трап не объясняет падение внутри функции:"
    sed 's/^/      /' <<< "$TRAP_OUT"
fi

# --------------------------------------------------------------------------
head_ "9. Меню переживает падение компонента"
# --------------------------------------------------------------------------
# ERR-трап срабатывает даже при set +e, поэтому раньше любая ненулевая команда
# внутри comp_* убивала весь установщик прямо из меню. menu_step вызывает
# компонент через "if" — там подавлены и set -e, и трап.
MENU=$(RH_LIB_ONLY=1 bash -c '
    source "'"$ROOT"'/setup.sh"
    SETUP_LOG=/tmp/rh-test.log
    broken_component() { false; }
    menu_step "тестовый компонент" broken_component
    echo "МЕНЮ ВЫЖИЛО"
' 2>&1 || true)
if grep -q "МЕНЮ ВЫЖИЛО" <<< "$MENU"; then
    ok "падение компонента не убивает меню"
else
    bad "падение компонента обрывает установщик:"; sed 's/^/      /' <<< "$MENU"
fi

# --------------------------------------------------------------------------
head_ "10. Сохранённые ответы не выполняются как команды"
# --------------------------------------------------------------------------
# install.conf читается через source от root. Значение вида a$(команда) раньше
# выполнялось при следующем запуске, а пароль с $ молча портился.
# Значения передаём через окружение в одинарных кавычках, иначе подстановка
# сработает ещё в самом тесте и мы проверим не то.
INJ=$(RH_LIB_ONLY=1 \
      TESTSECRET='a$(id -u)b' \
      TESTPROXY='socks5h://user:pa$$word@host:1080' \
      bash -c '
    source "'"$ROOT"'/setup.sh"
    INSTALL_STATE=$(mktemp)
    DOMAIN="example.com"; SUBDOMAIN="n1"; PANEL_IP="1.2.3.4"
    REMNA_SECRET="$TESTSECRET"
    TG_PROXY="$TESTPROXY"
    save_state
    ( source "$INSTALL_STATE"; echo "SECRET=$REMNA_SECRET"; echo "PROXY=$TG_PROXY" )
    rm -f "$INSTALL_STATE"
' 2>&1 || true)
if grep -q 'SECRET=a$(id -u)b' <<< "$INJ" && grep -q 'PROXY=socks5h://user:pa$$word@host:1080' <<< "$INJ"; then
    ok "значения сохраняются дословно, подстановка команд не срабатывает"
else
    bad "сохранённые значения портятся или выполняются:"; sed 's/^/      /' <<< "$INJ"
fi

# --------------------------------------------------------------------------
head_ "11. Порт сверяется точно, а не по подстроке"
# --------------------------------------------------------------------------
PORTCHK=$(RH_LIB_ONLY=1 bash -c '
    source "'"$ROOT"'/setup.sh"
    ss() { printf "LISTEN 0 128 0.0.0.0:22220 0.0.0.0:*\n"; }
    if port_is_listening 2222; then echo "ЛОЖНОЕ СРАБАТЫВАНИЕ"; else echo "ТОЧНО"; fi
    ss() { printf "LISTEN 0 128 0.0.0.0:2222 0.0.0.0:*\n"; }
    if port_is_listening 2222; then echo "НАШЁЛ"; else echo "НЕ НАШЁЛ"; fi
' 2>&1 || true)
if grep -q "ТОЧНО" <<< "$PORTCHK" && grep -q "НАШЁЛ" <<< "$PORTCHK"; then
    ok "22220 не засчитывается за 2222"
else
    bad "проверка порта работает по подстроке:"; sed 's/^/      /' <<< "$PORTCHK"
fi

# --------------------------------------------------------------------------
head_ "12. Битый SSH-ключ отбраковывается"
# --------------------------------------------------------------------------
# Раньше проверкой было «строка непустая»: обрезанный при копировании ключ
# проходил, скрипт отключал пароли и запирал сервер.
if ! command -v ssh-keygen >/dev/null 2>&1; then
    printf '  — ssh-keygen не установлен, пропускаю\n'
else
    GOODKEY="$TESTKEY"
    KEYCHK=$(RH_LIB_ONLY=1 bash -c '
        source "'"$ROOT"'/setup.sh"
        ssh_key_valid "ssh-ed25519 AAAAOBREZANNYY" && echo "ПЛОХОЙ ПРИНЯТ" || echo "плохой отклонён"
        ssh_key_valid "" && echo "ПУСТОЙ ПРИНЯТ" || echo "пустой отклонён"
        ssh_key_valid "'"$GOODKEY"'" && echo "хороший принят" || echo "ХОРОШИЙ ОТКЛОНЁН"
    ' 2>&1 || true)
    if grep -q "плохой отклонён" <<< "$KEYCHK" && grep -q "пустой отклонён" <<< "$KEYCHK" \
       && grep -q "хороший принят" <<< "$KEYCHK"; then
        ok "проверка SSH-ключа отличает настоящий от мусора"
    else
        bad "проверка SSH-ключа работает неверно:"; sed 's/^/      /' <<< "$KEYCHK"
    fi
fi

# --------------------------------------------------------------------------
head_ "13. Диагностика ничего не меняет"
# --------------------------------------------------------------------------
# check.sh запускают на живых нодах в рабочее время. Любая изменяющая команда
# внутри него превращает безобидную проверку в незапланированную правку.
if python3 tests/check_readonly.py; then ok "check.sh только читает"
else bad "в check.sh просочились изменяющие команды"; fi

# --------------------------------------------------------------------------
head_ "14. Сторож панели: сценарии"
# --------------------------------------------------------------------------
# Генерируем сторожа во временный каталог и прогоняем на данных, снятых
# с живой ноды: панель держит постоянные ESTABLISHED-соединения с портом ноды.
PW=$(mktemp -d)
cat > "$PW/ss" <<'STUB'
#!/bin/bash
[[ "$FAKE_CONNS" == "0" ]] && exit 0
cat <<'ROWS'
ESTAB 0 0 132.243.174.42:2222 143.246.198.52:58454
ESTAB 0 0 132.243.174.42:2222 143.246.198.52:60724
ESTAB 0 0 132.243.174.42:2222 143.246.198.52:41992
ROWS
STUB
cat > "$PW/timeout" <<'STUB'
#!/bin/bash
[[ "$FAKE_PROBE" == "ok" ]] && exit 0 || exit 1
STUB
cat > "$PW/notify" <<'STUB'
#!/bin/bash
echo "TELEGRAM: $1" >> "$PW_OUT"
STUB
chmod +x "$PW/ss" "$PW/timeout" "$PW/notify"

RH_LIB_ONLY=1 bash -c '
    source "'"$ROOT"'/setup.sh"
    PANEL_ENV="'"$PW"'/panel.env"
    PANEL_WATCH_BIN="'"$PW"'/watch.sh"
    NOTIFY_BIN="'"$PW"'/notify"
    NOTIFY_ENV="'"$PW"'/notify.env"; : > "$NOTIFY_ENV"
    SETUP_LOG=/dev/null
    PANEL_IP="143.246.198.52"; NODE_PORT="2222"; PANEL_PROBE_PORT="443"
    NONINTERACTIVE=1
    systemctl(){ :; }; chmod(){ :; }; ss(){ :; }
    comp_panel_watch >/dev/null 2>&1
' 2>/dev/null

if [[ ! -s "$PW/watch.sh" ]]; then
    bad "сторож панели не сгенерировался"
else
    bash -n "$PW/watch.sh" 2>/dev/null && ok "сгенерированный сторож синтаксически корректен" \
                                       || bad "сгенерированный сторож не парсится"
    run_watch() {  # $1=соединения $2=проба; печатает, что ушло в Telegram
        PW_OUT="$PW/out"; : > "$PW_OUT"
        PATH="$PW:$PATH" PW_OUT="$PW_OUT" RH_STATE_DIR="$PW" FAKE_CONNS="$1" FAKE_PROBE="$2" \
            bash "$PW/watch.sh" >/dev/null 2>&1
        cat "$PW_OUT"
    }
    rm -f "$PW"/rh-panel-fails "$PW"/rh-panel-down
    R1=$(run_watch 3 ok)                       # всё хорошо
    R2=$(run_watch 0 fail)$(run_watch 0 fail)  # два провала — ещё молчим
    R3=$(run_watch 0 fail)                     # третий — тревога
    R4=$(run_watch 0 fail)                     # повтора быть не должно
    R5=$(run_watch 3 ok)                       # восстановление
    rm -f "$PW"/rh-panel-fails "$PW"/rh-panel-down

    [[ -z "$R1" ]] && ok "панель на связи — сообщений нет" || bad "лишнее сообщение при живой панели: $R1"
    [[ -z "$R2" ]] && ok "два провала подряд — ещё не паникуем" || bad "паника раньше порога: $R2"
    grep -q "ПАНЕЛЬ НЕ НА СВЯЗИ" <<< "$R3" && ok "третий провал — тревога ушла" || bad "тревога не пришла: $R3"
    [[ -z "$R4" ]] && ok "повторных тревог нет" || bad "спамит повторами: $R4"
    grep -q "снова на связи" <<< "$R5" && ok "восстановление отмечено" || bad "нет сообщения о восстановлении: $R5"

    # Панель отвечает, но к ноде не подключается — это отдельный диагноз
    rm -f "$PW"/rh-panel-fails "$PW"/rh-panel-down
    run_watch 0 ok >/dev/null; run_watch 0 ok >/dev/null
    R6=$(run_watch 0 ok)
    rm -f "$PW"/rh-panel-fails "$PW"/rh-panel-down
    grep -q "не подключается" <<< "$R6" && ok "случай «сервер жив, но нода не подключена» различается" \
        || bad "неверный диагноз: $R6"
fi
rm -rf "$PW"

# --------------------------------------------------------------------------
head_ "15. Шаблон nginx существует в одном экземпляре"
# --------------------------------------------------------------------------
# Смена домена раньше имела свою копию шаблона, и копия разошлась с оригиналом.
# Теперь и установка, и смена домена зовут write_nginx_site.
TPL=$(grep -c 'ssl_certificate ' lib/*.sh changedomain.sh 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')
if [[ "$TPL" -eq 1 ]]; then
    ok "шаблон nginx описан один раз"
else
    bad "шаблон nginx встречается $TPL раз — копии разойдутся"
    grep -n 'ssl_certificate ' lib/*.sh changedomain.sh 2>/dev/null | sed 's/^/      /'
fi
# Упоминание в комментарии не считается — ищем именно вызов
NGXCB=$(grep -n 'certbot --nginx' lib/*.sh changedomain.sh 2>/dev/null \
        | grep -v ':[0-9]*:[[:space:]]*#' || true)
if [[ -n "$NGXCB" ]]; then
    bad "где-то остался вызов certbot --nginx (он требует готовый server_name и падает)"
    echo "$NGXCB" | sed 's/^/      /'
else
    ok "выпуск сертификата везде через webroot"
fi

# --------------------------------------------------------------------------
head_ "16. shellcheck (если установлен)"
# --------------------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -s bash -S warning -e SC1090,SC1091,SC2034 setup.sh check.sh changedomain.sh; then
        ok "shellcheck без замечаний"
    else
        bad "shellcheck нашёл проблемы"
    fi
else
    printf '  — shellcheck не установлен, пропускаю\n'
fi

# --------------------------------------------------------------------------
printf '\n=========================================\n'
printf '  Пройдено: %s   Провалено: %s\n' "$PASSED" "$FAILED"
printf '=========================================\n'
[[ $FAILED -eq 0 ]]
