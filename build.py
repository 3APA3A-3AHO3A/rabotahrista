#!/usr/bin/env python3
"""Склеивает модули из lib/ в готовые к запуску скрипты.

Зачем сборка вообще нужна: нода ставится на чистый сервер, где нет ни git,
ни репозитория. Значит туда должен приезжать один самодостаточный файл.
Модули существуют для нас, собранные скрипты — для сервера.

Собирается два файла:

  setup.sh   всё из lib/*.sh. Порядок склейки — по именам, поэтому они
             пронумерованы: 00-header (режимы оболочки и настройки) первым,
             99-main (точка входа) последним.

  check.sh   только диагностика: блок настроек из 00-header.sh плюс
             lib/94-check.sh. Тот же код, что и в меню установщика, — чтобы
             проверка и починка не разъезжались. Отдельный файл нужен тем,
             кому на живой ноде хочется запустить заведомо ничего не меняющий
             скрипт.

    python3 build.py           собрать оба файла
    python3 build.py --check   проверить, что собранное совпадает с lib/ (для CI)
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
LIB = ROOT / "lib"
OUT = ROOT / "setup.sh"
CHECK_OUT = ROOT / "check.sh"
CHECK_MOD = LIB / "94-check.sh"
HEADER_MOD = LIB / "00-header.sh"

# Границы блока с путями и портами внутри 00-header.sh. Диагностике нужны те же
# пути, что и установщику, а два списка неизбежно разойдутся — поэтому не копия,
# а вырезка из единственного оригинала.
SETTINGS_BEGIN = "# === НАСТРОЙКИ ==="
SETTINGS_END = "# ================="

BANNER = """# ЭТОТ ФАЙЛ СОБРАН АВТОМАТИЧЕСКИ ИЗ lib/*.sh — НЕ РЕДАКТИРУЙТЕ ЕГО ВРУЧНУЮ.
# Правки вносятся в lib/, затем: python3 build.py
# Любое изменение здесь будет затёрто при следующей сборке."""

CHECK_DOC = """# ##########################################################################
#  ДИАГНОСТИКА НОДЫ rabotahrista
#
#  Скрипт НИЧЕГО НЕ МЕНЯЕТ. Только читает и рассказывает, что нашёл.
#  Это сознательное ограничение: его безопасно запускать на живой ноде
#  в любой момент, он не трогает ни конфиги, ни сервисы, ни фаервол.
#
#      curl -fsSL .../check.sh -o /tmp/check.sh
#      sudo bash /tmp/check.sh            быстрая проверка
#      sudo bash /tmp/check.sh --deep     + тест продления сертификата
#
#  То же самое есть в самом установщике: меню -> пункт 3. Код один и тот же,
#  этот файл собирается из lib/94-check.sh.
# ##########################################################################"""


def strip_shebang(text: str) -> str:
    """Убирает ТОЛЬКО собственный shebang модуля — он всегда первой строкой.

    Раньше вырезались все строки с "#!/", и вместе с ними пропадали shebang'и
    внутри heredoc'ов, которыми модули генерируют служебные скрипты на сервере:
    файлы получались без первой строки и исполнялись через /bin/sh, где нет
    [[ ]]. Ломалось молча.
    """
    lines = text.split("\n")
    if lines and lines[0].startswith("#!/"):
        lines = lines[1:]
    return "\n".join(lines).strip("\n")


def modules() -> list[Path]:
    files = sorted(LIB.glob("*.sh"))
    if not files:
        sys.exit("lib/ пуста — нечего собирать")
    names = [f.name for f in files]
    if names[0] != "00-header.sh":
        sys.exit(f"первым модулем должен быть 00-header.sh, а не {names[0]}")
    if names[-1] != "99-main.sh":
        sys.exit(f"последним модулем должен быть 99-main.sh, а не {names[-1]}")
    return files


def settings_block() -> str:
    """Вырезает блок настроек из 00-header.sh по маркерам."""
    lines = HEADER_MOD.read_text(encoding="utf-8").split("\n")
    try:
        a = lines.index(SETTINGS_BEGIN)
        b = lines.index(SETTINGS_END)
    except ValueError:
        sys.exit(
            f"в {HEADER_MOD.name} не найдены маркеры блока настроек "
            f"({SETTINGS_BEGIN!r} ... {SETTINGS_END!r}) — из него собирается check.sh"
        )
    if b <= a:
        sys.exit(f"в {HEADER_MOD.name} маркеры блока настроек стоят в обратном порядке")
    return "\n".join(lines[a : b + 1])


def assemble() -> str:
    files = modules()
    parts: list[str] = ["#!/bin/bash", BANNER, "# Собрано из: " + ", ".join(f.name for f in files), ""]
    for f in files:
        parts.append(f"# ===== lib/{f.name} " + "=" * max(0, 60 - len(f.name)))
        parts.append(strip_shebang(f.read_text(encoding="utf-8")))
        parts.append("")
    return "\n".join(parts).rstrip() + "\n"


def assemble_check() -> str:
    if not CHECK_MOD.exists():
        sys.exit(f"нет {CHECK_MOD.name} — из него собирается check.sh")
    parts: list[str] = [
        "#!/bin/bash",
        BANNER,
        f"# Собрано из: {HEADER_MOD.name} (блок настроек), {CHECK_MOD.name}",
        "",
        CHECK_DOC,
        "",
        # Намеренно без set -e: тот же код выполняется внутри установщика, где
        # его зовут в подоболочке, и поведение обязано совпадать.
        "set -o pipefail",
        "",
        settings_block(),
        "",
        'if locale -a 2>/dev/null | grep -qix \'C\\.UTF-*8\'; then export LC_ALL=C.UTF-8; fi',
        'if [[ "$EUID" -ne 0 ]]; then',
        '    # "sudo bash <(curl ...)" не работает: sudo закрывает лишние дескрипторы',
        '    echo "Нужны права root. Запускать так:"',
        "    echo",
        '    echo "  curl -fsSL https://raw.githubusercontent.com/3APA3A-3AHO3A/rabotahrista/main/check.sh -o /tmp/check.sh"',
        '    echo "  sudo bash /tmp/check.sh"',
        "    echo",
        "    exit 1",
        "fi",
        "",
        strip_shebang(CHECK_MOD.read_text(encoding="utf-8")),
        "",
        'rh_check "$@"',
    ]
    return "\n".join(parts).rstrip() + "\n"


def write(path: Path, text: str) -> None:
    # newline="\n" — иначе на Windows файл уедет в CRLF и сломается на сервере
    with path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    path.chmod(0o755)


def main() -> int:
    targets = [(OUT, assemble()), (CHECK_OUT, assemble_check())]

    if "--check" in sys.argv:
        stale = []
        for path, built in targets:
            if not path.exists():
                print(f"{path.name} отсутствует — запустите: python3 build.py", file=sys.stderr)
                return 1
            if path.read_text(encoding="utf-8") != built:
                stale.append(path.name)
        if stale:
            print("устарело (не совпадает с lib/): " + ", ".join(stale), file=sys.stderr)
            print("Пересоберите: python3 build.py", file=sys.stderr)
            return 1
        print("setup.sh и check.sh актуальны")
        return 0

    for path, built in targets:
        write(path, built)
        print(f"собрано: {path.name}  ({len(built.splitlines())} строк)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
