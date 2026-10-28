#!/usr/bin/env python3
"""Turn CI logs into GitHub Actions annotations.

GitHub shows only a handful of annotations per step, so each annotation packs
several log lines together. This exists so a failed run is debuggable without
downloading artifacts (logs are stored on a CDN that some networks block).

Usage:
    python3 scripts/ci_report.py analyze /tmp/analyze.log
    python3 scripts/ci_report.py gradle /tmp/debug-build.log
"""

from __future__ import annotations

import os
import sys

MAX_LINES = 120
LINES_PER_ANNOTATION = 5
MAX_ANNOTATIONS = 9
MAX_PAYLOAD = 1100

ANALYZE_MARKERS = (" • ", "error •", "warning •", "info •", "Failed", "Error:")


def read_lines(path: str) -> list[str]:
    if not os.path.exists(path):
        return []
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        return [line.rstrip("\n") for line in handle]


def analyze_lines(lines: list[str]) -> list[str]:
    picked = [line.strip() for line in lines if any(m in line for m in ANALYZE_MARKERS)]
    picked = [line for line in picked if line]
    if not picked:
        picked = [line.strip() for line in lines[-40:] if line.strip()]
    return picked


def gradle_lines(lines: list[str]) -> list[str]:
    start = 0
    for index, line in enumerate(lines):
        if "What went wrong" in line or "FAILURE:" in line:
            start = max(0, index - 2)
            break
    block = [line.rstrip() for line in lines[start:start + 80]]
    block = [line for line in block if line.strip()]
    if not block:
        block = [line for line in lines[-60:] if line.strip()]
    return block


def emit(kind: str, lines: list[str]) -> None:
    lines = lines[:MAX_LINES]
    chunks: list[list[str]] = []
    current: list[str] = []
    size = 0
    for line in lines:
        if len(current) >= LINES_PER_ANNOTATION or size + len(line) > MAX_PAYLOAD:
            chunks.append(current)
            current = []
            size = 0
        current.append(line)
        size += len(line) + 3
    if current:
        chunks.append(current)
    chunks = chunks[:MAX_ANNOTATIONS]
    for index, chunk in enumerate(chunks):
        payload = " | ".join(chunk).replace("%", "%25").replace("\r", " ")
        print(f"::error title={kind} {index + 1}/{len(chunks)}::{payload}")


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("usage: ci_report.py <analyze|gradle|raw> <logfile> [logfile...]")
        return 2
    mode = argv[1]
    collected: list[str] = []
    for path in argv[2:]:
        lines = read_lines(path)
        if not lines:
            continue
        label = os.path.basename(path)
        if mode == "analyze":
            collected.extend([f"[{label}] {line}" for line in analyze_lines(lines)])
        elif mode == "gradle":
            collected.extend([f"[{label}] {line}" for line in gradle_lines(lines)])
        else:
            collected.extend([f"[{label}] {line}" for line in lines[-40:]])
    if not collected:
        print("::warning title=ci-report::no log lines were captured")
        return 0
    emit(mode, collected)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
