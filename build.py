#!/usr/bin/env python3
"""Склеивает модули из lib/ в один файл setup.sh.

Зачем сборка вообще нужна: нода ставится одной командой
    bash <(curl -fsSL .../setup.sh)
на чистый сервер, где нет ни git, ни самого репозитория. Значит на сервер
должен приезжать один самодостаточный файл. Модули существуют для нас,
собранный setup.sh — для сервера.

Порядок склейки — по именам файлов, поэтому они пронумерованы:
00-header (режимы оболочки и настройки) ... 99-main (точка входа) идёт последним.

    python3 build.py           собрать setup.sh
    python3 build.py --check   проверить, что setup.sh совпадает с lib/ (для CI)
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
LIB = ROOT / "lib"
OUT = ROOT / "setup.sh"

BANNER = """# ЭТОТ ФАЙЛ СОБРАН АВТОМАТИЧЕСКИ ИЗ lib/*.sh — НЕ РЕДАКТИРУЙТЕ ЕГО ВРУЧНУЮ.
# Правки вносятся в lib/, затем: python3 build.py
# Любое изменение здесь будет затёрто при следующей сборке."""


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


def assemble() -> str:
    files = modules()
    parts: list[str] = ["#!/bin/bash", BANNER, "# Собрано из: " + ", ".join(f.name for f in files), ""]
    for f in files:
        text = f.read_text(encoding="utf-8")
        # Убираем ТОЛЬКО собственный shebang модуля — он всегда первой строкой.
        # Раньше вырезались все строки с "#!/", и вместе с ними пропадали
        # shebang'и внутри heredoc'ов, которыми модули генерируют служебные
        # скрипты на сервере: файлы получались без первой строки и исполнялись
        # через /bin/sh, где нет [[ ]]. Ломалось молча.
        lines = text.split("\n")
        if lines and lines[0].startswith("#!/"):
            lines = lines[1:]
        parts.append(f"# ===== lib/{f.name} " + "=" * max(0, 60 - len(f.name)))
        parts.append("\n".join(lines).strip("\n"))
        parts.append("")
    return "\n".join(parts).rstrip() + "\n"


def main() -> int:
    built = assemble()
    if "--check" in sys.argv:
        if not OUT.exists():
            print("setup.sh отсутствует — запустите: python3 build.py", file=sys.stderr)
            return 1
        if OUT.read_text(encoding="utf-8") != built:
            print("setup.sh устарел: он не совпадает с содержимым lib/.", file=sys.stderr)
            print("Пересоберите: python3 build.py", file=sys.stderr)
            return 1
        print("setup.sh актуален")
        return 0

    # newline="\n" — иначе на Windows файл уедет в CRLF и сломается на сервере
    with OUT.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write(built)
    OUT.chmod(0o755)
    print(f"собрано: {OUT.name}  ({len(built.splitlines())} строк из {len(modules())} модулей)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
