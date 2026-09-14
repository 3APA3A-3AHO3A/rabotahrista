#!/usr/bin/env python3
"""Шаги установки не должны задавать вопросы.

Полная установка устроена так: сначала скрипт спрашивает всё, что ему нужно,
и только потом начинает работать. Смысл в том, чтобы человек ответил на вопросы
и ушёл, а не сторожил терминал двадцать минут.

Нарушить это легко: добавляешь в comp_* функцию один read — и установка
замирает посреди работ, дожидаясь ввода. Так уже случалось дважды:
с Telegram-прокси и с портом панели. Этот тест ищет прямые read внутри
функций, которые вызываются из full_install через do_step.

Вызовы ask_* разрешены: они сами проверяют, заданы ли ответы, и молчат,
если всё уже известно.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIB = ROOT / "lib"

FN_RE = re.compile(r"^([a-zA-Z_][a-zA-Z0-9_]*)\(\)\s*\{")
READ_RE = re.compile(r"(?:^|[|;&]{1,2}|\bthen\b|\bdo\b|\belse\b)\s*read\s+-")
HERE_RE = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def heredoc_mask(lines: list[str]) -> list[bool]:
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


def steps_of_full_install() -> list[str]:
    """Имена функций, которые полная установка запускает через do_step."""
    text = (LIB / "90-install.sh").read_text(encoding="utf-8")
    return sorted(set(re.findall(r'do_step\s+"[^"]*"\s+([a-zA-Z_][a-zA-Z0-9_]*)', text)))


def bodies() -> dict[str, tuple[Path, int, list[str]]]:
    found = {}
    for f in sorted(LIB.glob("*.sh")):
        lines = f.read_text(encoding="utf-8").split("\n")
        mask = heredoc_mask(lines)
        for i, line in enumerate(lines):
            m = FN_RE.match(line)
            if not m or mask[i]:
                continue
            end = i
            if not (lines[i].count("{") == lines[i].count("}") and lines[i].rstrip().endswith("}")):
                end = i + 1
                while end < len(lines) and not (lines[end] == "}" and not mask[end]):
                    end += 1
            found[m.group(1)] = (f, i, lines[i:end + 1])
    return found


def main() -> int:
    steps = steps_of_full_install()
    if not steps:
        print("не нашёл ни одного do_step в lib/90-install.sh", file=sys.stderr)
        return 1

    all_fn = bodies()
    problems = []
    for name in steps:
        if name not in all_fn:
            continue
        path, start, body = all_fn[name]
        mask = heredoc_mask(body)
        for off, line in enumerate(body):
            if mask[off] or line.lstrip().startswith("#"):
                continue
            if READ_RE.search(line):
                problems.append(
                    f"{path.name}:{start + off + 1}  {name}() спрашивает во время установки:\n"
                    f"      {line.strip()[:90]}\n"
                    f"      -> перенесите вопрос в функцию ask_* и вызовите её заранее"
                )

    if problems:
        print("ШАГ УСТАНОВКИ ОСТАНОВИТСЯ И БУДЕТ ЖДАТЬ ВВОДА:\n", file=sys.stderr)
        for p in problems:
            print("  " + p, file=sys.stderr)
        return 1

    print(f"check_no_prompts: OK (проверено шагов: {len(steps)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
