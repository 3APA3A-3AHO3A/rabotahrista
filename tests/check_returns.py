#!/usr/bin/env python3
"""Статическая проверка: функция не должна заканчиваться голой проверкой.

Почему это отдельный тест. В bash функция возвращает код последней команды.
Если последняя строка — [[ ... ]] или [[ ... ]] && что-то, то при несовпадении
условия функция вернёт 1. А из-за set -e вызов вида

    [[ -n "$TG_BOT_TOKEN" ]] && ask_telegram

убьёт весь скрипт молча, посреди установки. Ровно так и происходило:
ask_telegram заканчивалась на [[ -z "$TG_TOPIC_ID" ]] && read ...,
и повторная установка с уже заполненным Telegram обрывалась без единого слова.

Лечится явным "return 0" в конце функции. Этот тест следит, чтобы класс
ошибки не вернулся.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FN_RE = re.compile(r"^([a-zA-Z_][a-zA-Z0-9_]*)\(\)\s*\{")
HERE_RE = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")

# Голое условие в конце: [[ ... ]] или [[ ... ]] && cmd  (без || — тот даёт код 0)
RISKY = [
    re.compile(r"^\[\[.*\]\]\s*$"),
    re.compile(r"^\[\[.*\]\]\s*&&(?!.*\|\|)"),
    re.compile(r"^\(\(.*\)\)\s*$"),
    re.compile(r"^\(\(.*\)\)\s*&&(?!.*\|\|)"),
    re.compile(r"^(test|\[) .*\]?\s*&&(?!.*\|\|)"),
]


def heredoc_mask(lines: list[str]) -> list[bool]:
    """Отмечает строки внутри heredoc — в них не надо искать код."""
    mask = [False] * len(lines)
    i = 0
    while i < len(lines):
        m = HERE_RE.search(lines[i])
        if m and not lines[i].lstrip().startswith("#"):
            term, j = m.group(2), i + 1
            while j < len(lines) and lines[j].strip() != term:
                mask[j] = True
                j += 1
            if j < len(lines):
                mask[j] = True
            i = j + 1
        else:
            i += 1
    return mask


def last_statement(body: list[str]) -> str:
    idx = len(body) - 1
    if body[idx].strip() == "}":
        idx -= 1
    while idx >= 0 and (not body[idx].strip() or body[idx].lstrip().startswith("#")):
        idx -= 1
    return body[idx].strip() if idx >= 0 else ""


def check(path: Path) -> list[str]:
    lines = path.read_text(encoding="utf-8").split("\n")
    mask = heredoc_mask(lines)
    problems = []
    for i, line in enumerate(lines):
        m = FN_RE.match(line)
        if not m or mask[i]:
            continue
        name = m.group(1)
        if lines[i].count("{") == lines[i].count("}") and lines[i].rstrip().endswith("}"):
            end = i
        else:
            end = i + 1
            while end < len(lines) and not (lines[end] == "}" and not mask[end]):
                end += 1
        last = last_statement(lines[i : end + 1])
        if any(r.match(last) for r in RISKY):
            problems.append(
                f"{path.name}:{i + 1}  функция {name}() заканчивается условием:\n"
                f"      {last}\n"
                f"      -> при несовпадении вернёт 1 и убьёт скрипт из-за set -e.\n"
                f"      -> добавьте 'return 0' последней строкой функции."
            )
    return problems


def main() -> int:
    targets = sorted((ROOT / "lib").glob("*.sh"))
    problems: list[str] = []
    for f in targets:
        problems += check(f)
    if problems:
        print("НАЙДЕНЫ ФУНКЦИИ, КОТОРЫЕ МОГУТ МОЛЧА УБИТЬ СКРИПТ:\n", file=sys.stderr)
        for p in problems:
            print("  " + p, file=sys.stderr)
        return 1
    print(f"check_returns: OK ({len(targets)} модулей)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
