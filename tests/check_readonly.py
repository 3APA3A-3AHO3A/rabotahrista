#!/usr/bin/env python3
"""Гарантия, что check.sh только читает.

Смысл диагностики в том, что её безопасно запустить на живой ноде посреди
рабочего дня. Как только туда просочится хоть одна изменяющая команда, это
перестанет быть правдой — а заметить такое глазами при очередной правке легко
не успеть. Поэтому проверка автоматическая.

Ищем изменяющие команды именно в позиции команды (начало строки, после |, ;,
&&, ||, (, {, then, do, else), чтобы упоминание внутри строки-подсказки
вида  fix "права: chmod 600 файл"  не считалось нарушением.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TARGET = ROOT / "check.sh"

# Что считается началом команды
CMD_START = r"(?:^|[|;&]{1,2}|\(|\{|\bthen\b|\bdo\b|\belse\b)\s*"

FORBIDDEN: list[tuple[str, str]] = [
    (rf"{CMD_START}(rm|mv|cp|mkdir|touch|chmod|chown|chgrp|ln|dd|truncate|tee|install)\s",
     "изменяет файлы"),
    (rf"{CMD_START}sed\s+(?:-[a-zA-Z]*i|--in-place)",
     "sed -i правит файл на месте"),
    (rf"{CMD_START}systemctl\s+(start|stop|restart|reload|enable|disable|mask|unmask)\b",
     "меняет состояние сервисов"),
    (rf"{CMD_START}(?:apt-get|apt|dpkg)\s+(?!.*(?:^|\s)-s(?:\s|$))(?:.*\s)?(install|upgrade|remove|purge|dist-upgrade)\b",
     "ставит или удаляет пакеты"),
    (rf"{CMD_START}ufw\s+(allow|deny|limit|reject|reset|enable|disable|delete|reload)\b",
     "меняет правила фаервола"),
    (rf"{CMD_START}docker\s+(?:compose\s+)?(up|down|restart|rm|stop|start|kill|pull)\b",
     "меняет состояние контейнеров"),
    (rf"{CMD_START}(?:adduser|useradd|usermod|userdel|passwd|chpasswd|visudo)\b",
     "меняет пользователей"),
    (rf"{CMD_START}(?:reboot|shutdown|halt|poweroff)\b",
     "перезагружает сервер"),
    (rf"{CMD_START}(?:swapon|swapoff|mkswap|fallocate|sysctl\s+-[wp]|update-grub|modprobe)\b",
     "меняет систему"),
    (rf"{CMD_START}certbot\s+(?:certonly|renew|--nginx)",
     "выпускает или продлевает сертификат по-настоящему"),
]

# Явно безопасные варианты: симуляция apt и тестовое продление сертификата
ALLOWED = [
    re.compile(r"(?:apt-get|apt|dpkg)\s+(?:-s\b|--simulate\b|--dry-run\b)"),
    re.compile(r"certbot\s+.*--dry-run"),
]

# Перенаправление вывода в настоящий файл (в /dev/null и в дескрипторы — можно)
REDIRECT = re.compile(r"(?<![0-9<>])>>?\s*(?!/dev/null)(?!&[0-9-])(?!\s*$)[\"'$/\w]")


def strip_noise(line: str) -> str:
    """Убирает комментарии и содержимое кавычек — там команды не выполняются."""
    out, i, quote = [], 0, None
    while i < len(line):
        ch = line[i]
        if quote:
            if ch == quote:
                quote = None
            out.append(" ")
        elif ch in "\"'":
            quote = ch
            out.append(" ")
        elif ch == "#" and (not out or out[-1].isspace()):
            break
        else:
            out.append(ch)
        i += 1
    return "".join(out)


def main() -> int:
    if not TARGET.exists():
        print(f"{TARGET.name} не найден", file=sys.stderr)
        return 1

    problems: list[str] = []
    for n, raw in enumerate(TARGET.read_text(encoding="utf-8").split("\n"), 1):
        line = strip_noise(raw)
        if not line.strip():
            continue
        if any(a.search(line) for a in ALLOWED):
            continue
        for pattern, why in FORBIDDEN:
            if re.search(pattern, line):
                problems.append(f"check.sh:{n}  {why}\n      {raw.strip()[:100]}")
                break
        else:
            if REDIRECT.search(line):
                problems.append(f"check.sh:{n}  пишет в файл\n      {raw.strip()[:100]}")

    if problems:
        print("ДИАГНОСТИКА ПЕРЕСТАЛА БЫТЬ ТОЛЬКО ЧИТАЮЩЕЙ:\n", file=sys.stderr)
        for p in problems:
            print("  " + p, file=sys.stderr)
        print("\n  check.sh обязан только читать — его запускают на живых нодах.", file=sys.stderr)
        return 1

    print("check_readonly: OK (check.sh ничего не меняет)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
