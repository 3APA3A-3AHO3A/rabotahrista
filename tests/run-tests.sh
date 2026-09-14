#!/bin/bash
# Прогон всех проверок, которые можно сделать без сервера.
# Запуск:  bash tests/run-tests.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
FAILED=0
PASSED=0

# На Windows "python3" обычно существует как заглушка Microsoft Store:
# она ничего не запускает и возвращает ошибку. Поэтому мало найти команду в
# PATH — надо убедиться, что она реально работает.
# Такая же проверка есть в .githooks/pre-commit; менять надо оба места.
PY=""
for _cand in python3 python py; do
    if command -v "$_cand" >/dev/null 2>&1 && "$_cand" -c "import sys" >/dev/null 2>&1; then
        PY="$_cand"; break
    fi
done
if [[ -z "$PY" ]]; then
    printf '\033[31mНе найден работающий python\033[0m — он нужен для build.py и части тестов.\n'
    printf 'Пробовал: python3, python, py\n'
    exit 1
fi

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
# Порядок важен: сначала проверяем ЗАКОММИЧЕННЫЙ setup.sh и только потом
# пересобираем. Если собрать первым, проверка сравнит файл сам с собой и
# будет проходить всегда — именно так она и работала вхолостую.
if "$PY" build.py --check >/dev/null 2>&1; then
    ok "setup.sh и check.sh собраны из текущего lib/"
else
    bad "собранные файлы устарели — пересоберите (python build.py) и закоммитьте"
fi
if "$PY" build.py >/dev/null 2>&1; then ok "build.py отработал"; else bad "build.py упал"; fi
if bash -n setup.sh 2>/dev/null; then ok "bash -n setup.sh"; else bad "bash -n setup.sh"; bash -n setup.sh; fi
if head -1 setup.sh | grep -q '^#!/bin/bash'; then ok "shebang на первой строке"; else bad "нет shebang"; fi

# Модули генерируют на сервере служебные скрипты, и внутри heredoc'ов лежат
# их собственные shebang'и. Сборщик однажды вырезал их все разом — файлы
# получались без первой строки, исполнялись через /bin/sh (где нет [[ ]])
# и молча не работали. Считаем: сборка убирает ровно один shebang и добавляет
# свой, значит количество обязано совпадать.
LIBSHE=$(grep -c '^#!/bin/bash' lib/*.sh 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
SETSHE=$(grep -c '^#!/bin/bash' setup.sh 2>/dev/null || echo 0)
if [[ "$LIBSHE" -eq "$SETSHE" ]]; then
    ok "shebang'и генерируемых скриптов на месте ($SETSHE)"
else
    bad "сборка потеряла shebang'и: в lib/ $LIBSHE, в setup.sh $SETSHE"
fi
# И структурно: первая строка каждого генерируемого скрипта — shebang
NOSHE=$(awk '/cat <<.*> \/usr\/local\/bin\// { f=NR; getline; if ($0 !~ /^#!\//) print f": "$0 }' setup.sh)
if [[ -n "$NOSHE" ]]; then
    bad "генерируемый скрипт начинается не с shebang:"
    echo "$NOSHE" | sed 's/^/      /'
else
    ok "каждый генерируемый скрипт начинается с shebang"
fi
if grep -qU $'\r' setup.sh; then bad "в setup.sh есть CRLF — на сервере сломается"; else ok "переводы строк LF"; fi

# --------------------------------------------------------------------------
head_ "3. Статическая проверка кодов возврата"
# --------------------------------------------------------------------------
if "$PY" tests/check_returns.py; then ok "ни одна функция не заканчивается голым условием"
else bad "есть функции, которые молча убьют скрипт"; fi

# Установка обязана задать все вопросы заранее: человек отвечает и уходит.
# Один read внутри comp_* — и скрипт замирает посреди работ, ожидая ввода.
if "$PY" tests/check_no_prompts.py; then ok "шаги установки не задают вопросов"
else bad "шаг установки остановится и будет ждать ввода"; fi

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
if "$PY" tests/check_readonly.py; then ok "check.sh только читает"
else bad "в check.sh просочились изменяющие команды"; fi

# grep -c при нуле совпадений печатает "0" И возвращает ненулевой код, поэтому
# "|| echo 0" даёт "0\n0" и ломает арифметику уже во время работы скрипта.
BADCOUNT=$(grep -nE 'grep -c[^|]*\|\| *echo' check.sh lib/*.sh 2>/dev/null || true)
if [[ -n "$BADCOUNT" ]]; then
    bad "grep -c с '|| echo' — при нуле совпадений получится две строки:"
    echo "$BADCOUNT" | sed 's/^/      /'
else
    ok "счётчики grep -c не ломаются на нуле совпадений"
fi

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
head_ "16. Диагностика в меню и в check.sh — один и тот же код"
# --------------------------------------------------------------------------
# Смысл всей затеи: человек качает ОДИН скрипт и тыкает меню. Если бы
# диагностика жила в двух файлах, копии разошлись бы, и «проверил одним,
# починил другим» перестало бы работать.
BODY_A=$(awk '/^rh_check\(\) \{/,/^\}/' setup.sh | md5sum | cut -d' ' -f1)
BODY_B=$(awk '/^rh_check\(\) \{/,/^\}/' check.sh | md5sum | cut -d' ' -f1)
if [[ -n "$BODY_A" && "$BODY_A" == "$BODY_B" ]]; then
    ok "rh_check в setup.sh и check.sh совпадают байт в байт"
else
    bad "rh_check разъехался между setup.sh и check.sh (пересоберите: python build.py)"
fi

# --------------------------------------------------------------------------
head_ "17. Диагностика не ломает установщик"
# --------------------------------------------------------------------------
# rh_check снимает себе set -e и ERR-трап: без этого половина её проверок,
# штатно возвращающих ненулевой код, роняла бы установщик. Поэтому её
# ОБЯЗАНЫ звать в подоболочке — иначе она разоружит обработчик ошибок
# на весь оставшийся сеанс, и следующая настоящая авария пройдёт молча.
DIAG=$(RH_LIB_ONLY=1 bash -c '
    source "'"$ROOT"'/setup.sh"
    SETUP_LOG=/tmp/rh-test.log
    rh_check() { set +e; trap - ERR; echo "диагностика"; return 1; }
    menu_check >/dev/null 2>&1
    echo "МЕНЮ ВЫЖИЛО"
    broken() { ls /definitely-no-such-path-here; }
    broken
' 2>&1 || true)
if grep -q "МЕНЮ ВЫЖИЛО" <<< "$DIAG" && grep -q "ОШИБКА — установка прервана" <<< "$DIAG"; then
    ok "диагностика не роняет меню и не разоружает обработчик ошибок"
else
    bad "диагностика зовётся не в подоболочке:"; sed 's/^/      /' <<< "$DIAG"
fi

# --------------------------------------------------------------------------
head_ "18. Починка трогает SSH только когда харденинг слетел"
# --------------------------------------------------------------------------
# Хостер переписывает конфиг sshd своим дроп-ином, root и пароли снова
# открыты. Починка обязана это заметить и вернуть харденинг — но на здоровой
# ноде не перезапускать sshd впустую, а на ноде без харденинга не накатывать
# его молча (он отключает вход по паролю и требует проверенный ключ).
SSHREP=$(RH_LIB_ONLY=1 bash -c '
    source "'"$ROOT"'/setup.sh"
    TMPD=$(mktemp -d)
    SSH_HARDEN_FILE="$TMPD/01-hardening.conf"
    SSH_PORT=8422
    sshd_listens_on() { return 0; }
    comp_ssh() { echo "ЧИНИТ"; return 0; }

    echo "== без файла харденинга"
    sshd() { printf "port 22\npermitrootlogin yes\npasswordauthentication yes\n"; }
    repair_ssh_hardening

    echo "Port 8422" > "$SSH_HARDEN_FILE"
    echo "== харденинг на месте"
    sshd() { printf "port 8422\npermitrootlogin no\npasswordauthentication no\n"; }
    repair_ssh_hardening

    echo "== харденинг слетел"
    sshd() { printf "port 8422\npermitrootlogin yes\npasswordauthentication no\n"; }
    repair_ssh_hardening
    rm -rf "$TMPD"
' 2>&1 || true)
S1=$(sed -n '/== без файла/,/== харденинг на месте/p' <<< "$SSHREP")
S2=$(sed -n '/== харденинг на месте/,/== харденинг слетел/p' <<< "$SSHREP")
S3=$(sed -n '/== харденинг слетел/,$p' <<< "$SSHREP")
if grep -q "ЧИНИТ" <<< "$S1"; then
    bad "починка молча накатывает харденинг на ноду, где его не было:"; sed 's/^/      /' <<< "$SSHREP"
elif grep -q "ЧИНИТ" <<< "$S2"; then
    bad "починка дёргает sshd на здоровой ноде:"; sed 's/^/      /' <<< "$SSHREP"
elif ! grep -q "ЧИНИТ" <<< "$S3"; then
    bad "починка НЕ заметила, что харденинг слетел:"; sed 's/^/      /' <<< "$SSHREP"
else
    ok "SSH чинится ровно тогда, когда сломан"
fi

# Порт для восстановления берётся из НАШЕГО файла харденинга, а не из sshd -T:
# чужой дроп-ин, читающийся раньше, перебивает Port — и починка закрепила бы
# чужой порт вместо того, чтобы вернуть свой.
PORTSRC=$(RH_LIB_ONLY=1 bash -c '
    source "'"$ROOT"'/setup.sh"
    TMPD=$(mktemp -d)
    SSH_HARDEN_FILE="$TMPD/01-hardening.conf"; echo "Port 8422" > "$SSH_HARDEN_FILE"
    sshd() { printf "port 22\n"; }          # чужой дроп-ин перебил наш Port
    ufw() { :; }; find() { :; }; ls() { :; }
    detect_existing_setup >/dev/null 2>&1
    echo "SSH_PORT=$SSH_PORT"
    rm -rf "$TMPD"
' 2>&1 || true)
if grep -q "SSH_PORT=8422" <<< "$PORTSRC"; then
    ok "порт для восстановления берётся из файла харденинга, а не из чужого дроп-ина"
else
    bad "починка взяла чужой порт: $PORTSRC"
fi

# А на ноде, где харденинга никогда не было, файла нет — и чтение порта не
# должно ронять скрипт. Ровно так и было: awk без файла возвращает 2, set -e
# убивал установщик ещё до показа меню.
NOFILE=$(RH_LIB_ONLY=1 bash -c '
    source "'"$ROOT"'/setup.sh"
    SSH_HARDEN_FILE="/nonexistent/01-hardening.conf"
    sshd() { printf "port 2222\n"; }
    ufw() { :; }; find() { :; }; ls() { :; }
    detect_existing_setup >/dev/null 2>&1
    echo "ДОШЛИ: SSH_PORT=$SSH_PORT"
' 2>&1 || true)
if grep -q "ДОШЛИ: SSH_PORT=2222" <<< "$NOFILE"; then
    ok "без файла харденинга чтение порта не роняет установщик"
else
    bad "чтение порта падает, когда файла харденинга нет:"; sed 's/^/      /' <<< "$NOFILE"
fi

# --------------------------------------------------------------------------
head_ "19. Домен ноды не угадывается по алфавиту"
# --------------------------------------------------------------------------
# Настоящая авария: на ноде, кроме самой ноды, жил сайт gateway.example.com.
# Домен определялся как «первый сертификат по алфавиту» — и установщик решил,
# что нода это gateway. Дальше он переписал конфиг соседа своим шаблоном и снял
# с публикации настоящий конфиг ноды. Nginx на двух серверах чинили руками.
mk_tree() {                       # $1 — каталог; создаёт пустое дерево nginx/LE
    mkdir -p "$1/avail" "$1/enabled" "$1/le"
}
domain_of() {                     # $1 — каталог дерева; печатает, что определилось
    RH_LIB_ONLY=1 bash -c '
        source "'"$ROOT"'/setup.sh"
        NGINX_AVAIL="'"$1"'/avail"; NGINX_ENABLED="'"$1"'/enabled"; LE_LIVE="'"$1"'/le"
        DOMAIN=""; SUBDOMAIN=""
        ufw() { :; }; sshd() { :; }; find() { :; }
        detect_existing_setup >/dev/null 2>&1
        echo "DOMAIN=${SUBDOMAIN:-}${SUBDOMAIN:+.}${DOMAIN:-} AMBIG=${DOMAIN_AMBIGUOUS:-}"
    ' 2>&1 || true
}

T=$(mktemp -d); mk_tree "$T"
mkdir -p "$T/le/gateway.gugutamd.org" "$T/le/node-nl-1.gugutamd.org"
: > "$T/avail/node-nl-1.gugutamd.org"
ln -sf "$T/avail/node-nl-1.gugutamd.org" "$T/enabled/"
R=$(domain_of "$T")
if grep -q "DOMAIN=node-nl-1.gugutamd.org" <<< "$R"; then
    ok "при двух сертификатах домен берётся из включённого конфига, а не по алфавиту"
else
    bad "выбран не тот домен: $R"
fi

# Ничего не включено, сертификатов два — доказательств нет, гадать нельзя
rm -f "$T/enabled"/*
R=$(domain_of "$T")
if grep -q "DOMAIN= " <<< "$R " && grep -q "AMBIG=.*gateway.*node-nl-1" <<< "$R"; then
    ok "при неоднозначности домен не выбирается, а называются кандидаты"
else
    bad "установщик всё равно что-то выбрал: $R"
fi

# Обычная нода с одним сертификатом должна определяться как раньше
rm -rf "$T/le/gateway.gugutamd.org"
R=$(domain_of "$T")
if grep -q "DOMAIN=node-nl-1.gugutamd.org" <<< "$R"; then
    ok "с единственным сертификатом домен определяется как прежде"
else
    bad "обычный случай сломан: $R"
fi
rm -rf "$T"

# --------------------------------------------------------------------------
head_ "20. Скрипт не правит чужой nginx"
# --------------------------------------------------------------------------
# Вторая половина той же аварии: ради единственного default_server на 8443
# установщик УДАЛЯЛ из sites-enabled всё, где встречалось proxy_protocol.
# Под это попадал рабочий сайт, к ноде отношения не имеющий. Правило теперь
# простое: сам, без человека, конфиг пишется только там, где в nginx пусто.
FOREIGN_CONF='server {
    listen 127.0.0.1:8443 ssl http2 proxy_protocol default_server;
    server_name _;
    ssl_reject_handshake on;
}
server {
    listen 127.0.0.1:8443 ssl http2 proxy_protocol;
    server_name gateway.gugutamd.org;
    root /var/www/gateway;
}'

in_tree() {   # $1 — каталог дерева, $2 — код на bash
    RH_LIB_ONLY=1 bash -c '
        source "'"$ROOT"'/setup.sh"
        NGINX_AVAIL="'"$1"'/avail"; NGINX_ENABLED="'"$1"'/enabled"; LE_LIVE="'"$1"'/le"
        SETUP_LOG=/dev/null
        nginx() { return 0; }
        systemctl() { return 0; }
        '"$2"'
    ' 2>&1 || true
}

# --- чистый сервер: писать можно, ломать нечего ---
T=$(mktemp -d); mk_tree "$T"
R=$(in_tree "$T" 'nginx_auto_site "node-nl-1.gugutamd.org"')
if [[ -s "$T/avail/node-nl-1.gugutamd.org" && -e "$T/enabled/node-nl-1.gugutamd.org" ]]; then
    ok "на чистом сервере конфиг пишется сам"
else
    bad "на чистом сервере конфиг не записан:"; sed 's/^/      /' <<< "$R"
fi
rm -rf "$T"

# --- рядом живёт чужой сайт: не трогаем ничего, только советуем ---
T=$(mktemp -d); mk_tree "$T"
printf '%s\n' "$FOREIGN_CONF" > "$T/avail/gateway.gugutamd.org"
ln -sf "$T/avail/gateway.gugutamd.org" "$T/enabled/"
cp "$T/avail/gateway.gugutamd.org" "$T/before"
R=$(in_tree "$T" 'nginx_auto_site "node-nl-1.gugutamd.org" || true')
if [[ -e "$T/enabled/gateway.gugutamd.org" ]] && cmp -s "$T/avail/gateway.gugutamd.org" "$T/before"; then
    ok "чужой сайт остался на месте и не изменён"
else
    bad "установщик тронул чужой сайт:"; sed 's/^/      /' <<< "$R"
fi
if [[ ! -e "$T/avail/node-nl-1.gugutamd.org" ]]; then
    ok "свой конфиг не записан молча — выдана рекомендация"
else
    bad "конфиг ноды записан без спроса на сервере с чужим сайтом"
fi
if grep -q "КОНФИГ NGINX — РЕКОМЕНДАЦИЯ" <<< "$R"; then
    ok "напечатан готовый конфиг с командами"
else
    bad "рекомендации не было:"; sed 's/^/      /' <<< "$R"
fi
# Заглушку default_server держит сосед — свою в рекомендации добавлять нельзя
R=$(in_tree "$T" 'nginx_render_site "node-nl-1.gugutamd.org"')
if ! grep -q 'default_server' <<< "$R"; then
    ok "в рекомендуемом конфиге заглушка не задвоилась"
else
    bad "вторая заглушка default_server — nginx такой конфиг не примет"
fi
rm -rf "$T"

# --- рекомендация обязана быть только чтением ---
T=$(mktemp -d); mk_tree "$T"
printf '%s\n' "$FOREIGN_CONF" > "$T/avail/node-nl-1.gugutamd.org"
ln -sf "$T/avail/node-nl-1.gugutamd.org" "$T/enabled/"
BEFORE=$(find "$T" | sort; md5sum "$T"/avail/* 2>/dev/null)
in_tree "$T" 'nginx_advise "node-nl-1.gugutamd.org"' >/dev/null
AFTER=$(find "$T" | sort; md5sum "$T"/avail/* 2>/dev/null)
if [[ "$BEFORE" == "$AFTER" ]]; then
    ok "рекомендация не меняет ни одного файла"
else
    bad "nginx_advise что-то изменил"
fi
rm -rf "$T"

# --- починка к nginx не прикасается вовсе ---
REP=$(RH_LIB_ONLY=1 bash -c '
    source "'"$ROOT"'/setup.sh"
    SETUP_LOG=/dev/null; NONINTERACTIVE=1
    SUBDOMAIN="node-nl-1"; DOMAIN="gugutamd.org"
    SUMMARY=()
    repair_perms() { return 0; }
    repair_ssh_hardening() { return 0; }
    repair_verify() { return 0; }
    comp_telegram() { return 0; }
    comp_panel_watch() { return 0; }
    save_state() { return 0; }
    nginx_apply_site() { echo "ПИСАЛ КОНФИГ"; }
    comp_web() { echo "ПИСАЛ КОНФИГ"; }
    run_repair
' 2>&1 || true)
if grep -q "ПИСАЛ КОНФИГ" <<< "$REP"; then
    bad "автоматическая починка правит nginx:"; sed 's/^/      /' <<< "$REP"
elif grep -q "КОНФИГ NGINX — РЕКОМЕНДАЦИЯ" <<< "$REP" && grep -q "ИТОГ ПОЧИНКИ" <<< "$REP"; then
    ok "починка nginx не трогает, печатает рекомендацию и доходит до конца"
else
    bad "починка ни рекомендации, ни правки:"; sed 's/^/      /' <<< "$REP"
fi

# --- ручная правка спрашивает подтверждение ---
T=$(mktemp -d); mk_tree "$T"
ASK=$(printf 'n\n' | RH_LIB_ONLY=1 bash -c '
    source "'"$ROOT"'/setup.sh"
    NGINX_AVAIL="'"$T"'/avail"; NGINX_ENABLED="'"$T"'/enabled"; LE_LIVE="'"$T"'/le"
    SETUP_LOG=/dev/null; NONINTERACTIVE=""
    FULL_DOMAIN="node-nl-1.gugutamd.org"
    nginx() { return 0; }; systemctl() { return 0; }
    comp_web_nginx
' 2>&1 || true)
if [[ -e "$T/avail/node-nl-1.gugutamd.org" ]]; then
    bad "ручная правка записала конфиг, хотя ответили «нет»:"; sed 's/^/      /' <<< "$ASK"
elif grep -q "Ничего не изменено" <<< "$ASK"; then
    ok "на «нет» ручная правка ничего не пишет"
else
    bad "ручная правка не спросила:"; sed 's/^/      /' <<< "$ASK"
fi
ASK=$(printf 'y\n' | RH_LIB_ONLY=1 bash -c '
    source "'"$ROOT"'/setup.sh"
    NGINX_AVAIL="'"$T"'/avail"; NGINX_ENABLED="'"$T"'/enabled"; LE_LIVE="'"$T"'/le"
    SETUP_LOG=/dev/null; NONINTERACTIVE=""
    FULL_DOMAIN="node-nl-1.gugutamd.org"
    nginx() { return 0; }; systemctl() { return 0; }
    comp_web_nginx
' 2>&1 || true)
if [[ -s "$T/avail/node-nl-1.gugutamd.org" ]]; then
    ok "на «да» конфиг записывается"
else
    bad "подтверждение не применило конфиг:"; sed 's/^/      /' <<< "$ASK"
fi
rm -rf "$T"

# --- файл без нашей метки копируется перед перезаписью ---
T=$(mktemp -d); mk_tree "$T"
echo "чужой конфиг, написанный руками" > "$T/avail/node-nl-1.gugutamd.org"
in_tree "$T" 'nginx_apply_site "node-nl-1.gugutamd.org"' >/dev/null
if grep -qr "чужой конфиг, написанный руками" "$T/avail"/*.bak.* 2>/dev/null; then
    ok "перед перезаписью остаётся копия"
else
    bad "конфиг затёрт без копии"
fi
BAKS=$(ls "$T/avail"/*.bak.* 2>/dev/null | wc -l)
in_tree "$T" 'nginx_apply_site "node-nl-1.gugutamd.org"' >/dev/null
if [[ "$(ls "$T/avail"/*.bak.* 2>/dev/null | wc -l)" -eq "$BAKS" ]]; then
    ok "свой конфиг перезаписывается без лишних копий"
else
    bad "копии плодятся при каждом запуске"
fi
rm -rf "$T"

# --- сертификат не выпускается, пока ACME-путь не отдаётся ---
CERT=$(RH_LIB_ONLY=1 bash -c '
    source "'"$ROOT"'/setup.sh"
    SETUP_LOG=/dev/null; NONINTERACTIVE=1
    DOMAIN="gugutamd.org"; SUBDOMAIN="node-nl-1"; SETUP_CF="n"
    SERVER_IP="1.2.3.4"
    get_server_ip() { return 0; }
    wget() { return 0; }; mkdir() { return 0; }
    nginx_write_safety() { echo "foreign"; }
    acme_reachable() { return 1; }
    certbot() { echo "ВЫПУСКАЛ СЕРТИФИКАТ"; }
    nginx_advise() { echo "(рекомендация)"; }
    cf_restore_proxy() { return 0; }
    comp_web || true
' 2>&1 || true)
if grep -q "ВЫПУСКАЛ СЕРТИФИКАТ" <<< "$CERT"; then
    bad "certbot зовётся, хотя ACME-путь не отдаётся:"; sed 's/^/      /' <<< "$CERT"
else
    ok "без рабочего ACME-пути сертификат не выпускается"
fi

# Временного конфига 00-acme больше нет: раньше он вешал на 80 порт
# default_server и снимал ссылку на default — то есть правил чужой nginx.
if grep -q 'acme_serve_start\|acme_serve_stop' lib/*.sh; then
    bad "вернулся временный ACME-конфиг, который правит nginx ради выпуска"
else
    ok "выпуск сертификата обходится без правки nginx"
fi

# --------------------------------------------------------------------------
head_ "21. Группа docker у админ-учётки"
# --------------------------------------------------------------------------
# На ноде, где Docker стоял ДО установщика, comp_docker выходил сразу после
# "Docker уже установлен" и не доходил до usermod. Пользователь получал
# permission denied на /var/run/docker.sock, а диагностика молчала.
dg() {   # $1 — группы пользователя; печатает, что сделала функция
    RH_LIB_ONLY=1 bash -c '
        source "'"$ROOT"'/setup.sh"
        ADMIN_USER="vadim"
        id() { [[ "$1" == "-nG" ]] && echo "'"$1"'"; return 0; }
        getent() { return 0; }
        usermod() { echo "USERMOD: $*"; }
        docker_group_member
    ' 2>&1 || true
}
R=$(dg "vadim sudo")
if grep -q "USERMOD: -aG docker vadim" <<< "$R"; then
    ok "учётку без группы docker добавляют в группу"
else
    bad "в группу docker не добавили: $R"
fi
R=$(dg "vadim sudo docker")
if grep -q "USERMOD" <<< "$R"; then
    bad "usermod зовётся повторно, хотя пользователь уже в группе: $R"
else
    ok "повторно в группу не добавляют"
fi

# Docker уже установлен — это НЕ повод пропустить группу
R=$(RH_LIB_ONLY=1 bash -c '
    source "'"$ROOT"'/setup.sh"
    SETUP_LOG=/dev/null
    command() { [[ "${2:-}" == "docker" ]] && return 0; return 1; }
    docker_group_member() { echo "ГРУППА ПРОВЕРЕНА"; }
    comp_docker
' 2>&1 || true)
if grep -q "ГРУППА ПРОВЕРЕНА" <<< "$R"; then
    ok "при уже установленном Docker группа всё равно проверяется"
else
    bad "comp_docker выходит, не проверив группу:"; sed 's/^/      /' <<< "$R"
fi

# И починка обязана это чинить: на старых нодах это типовая находка
R=$(RH_LIB_ONLY=1 bash -c '
    source "'"$ROOT"'/setup.sh"
    SETUP_LOG=/dev/null; NONINTERACTIVE=1
    SUBDOMAIN="n1"; DOMAIN="example.com"; SUMMARY=()
    repair_perms() { return 0; }; repair_ssh_hardening() { return 0; }
    repair_verify() { return 0; }; comp_telegram() { return 0; }
    comp_panel_watch() { return 0; }; save_state() { return 0; }
    nginx_advise() { return 0; }
    docker_group_member() { echo "ЧИНИЛ ГРУППУ"; }
    run_repair
' 2>&1 || true)
if grep -q "ЧИНИЛ ГРУППУ" <<< "$R"; then
    ok "починка проверяет группу docker"
else
    bad "починка не трогает группу docker"
fi

# --------------------------------------------------------------------------
head_ "22. shellcheck (если установлен)"
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
