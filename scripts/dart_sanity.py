#!/usr/bin/env python3
"""Very small heuristic linter for Dart sources.

It cannot replace `dart analyze`, but it catches the mistakes that are easy to
make when editing without a Dart toolchain: unbalanced delimiters, unterminated
string literals, stray backslashes and mismatched interpolation braces.
"""
import re
import sys
from pathlib import Path


def check(path: Path):
    src = path.read_text(encoding="utf-8")
    problems = []
    i = 0
    n = len(src)
    stack = []  # (char, line)
    line = 1
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        # comments
        if src.startswith("//", i):
            j = src.find("\n", i)
            if j == -1:
                break
            i = j
            continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            if j == -1:
                problems.append((line, "unterminated block comment"))
                break
            line += src.count("\n", i, j)
            i = j + 2
            continue
        # raw strings
        if c in "rR" and i + 1 < n and src[i + 1] in "'\"":
            quote = src[i + 1]
            triple = src.startswith(quote * 3, i + 1)
            start_line = line
            if triple:
                j = src.find(quote * 3, i + 4)
                if j == -1:
                    problems.append((start_line, "unterminated raw triple string"))
                    break
                line += src.count("\n", i, j)
                i = j + 3
            else:
                j = src.find(quote, i + 2)
                if j == -1:
                    problems.append((start_line, "unterminated raw string"))
                    break
                i = j + 1
            continue
        if c in "'\"":
            quote = c
            triple = src.startswith(quote * 3, i)
            start_line = line
            j = i + (3 if triple else 1)
            closed = False
            while j < n:
                ch = src[j]
                if ch == "\\":
                    j += 2
                    continue
                if ch == "\n":
                    line += 1
                    if not triple:
                        problems.append((start_line, "newline inside a single line string"))
                        closed = True
                        break
                    j += 1
                    continue
                if triple and src.startswith(quote * 3, j):
                    j += 3
                    closed = True
                    break
                if not triple and ch == quote:
                    j += 1
                    closed = True
                    break
                # interpolation: skip ${...} quickly
                if ch == "$" and j + 1 < n and src[j + 1] == "{":
                    depth = 0
                    k = j + 1
                    while k < n:
                        if src[k] == "{":
                            depth += 1
                        elif src[k] == "}":
                            depth -= 1
                            if depth == 0:
                                break
                        elif src[k] == "\n":
                            line += 1
                        k += 1
                    j = k + 1
                    continue
                j += 1
            if not closed:
                problems.append((start_line, "unterminated string literal"))
                break
            i = j
            continue
        if c in "([{":
            stack.append((c, line))
            i += 1
            continue
        if c in ")]}":
            if not stack:
                problems.append((line, f"unexpected closing {c!r}"))
                i += 1
                continue
            open_char, open_line = stack.pop()
            pairs = {")": "(", "]": "[", "}": "{"}
            if open_char != pairs[c]:
                problems.append(
                    (line, f"mismatched {c!r}, opened {open_char!r} at line {open_line}")
                )
            i += 1
            continue
        i += 1
    for open_char, open_line in stack:
        problems.append((open_line, f"unclosed {open_char!r}"))
    return problems


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "lib")
    files = sorted(root.rglob("*.dart"))
    if len(sys.argv) > 2:
        files += sorted(Path(sys.argv[2]).rglob("*.dart"))
    total = 0
    for path in files:
        for line, message in check(path):
            total += 1
            print(f"{path}:{line}: {message}")
    print(f"{len(files)} file(s) scanned, {total} problem(s)")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
