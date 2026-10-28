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


def analyze_lines(lines: list[str], only_errors: bool = False) -> list[str]:
    picked = [line.strip() for line in lines if any(m in line for m in ANALYZE_MARKERS)]
    if only_errors:
        picked = [line for line in picked if " error • " in line]
    else:
        picked = [line for line in picked if " error • " not in line]
    picked = [line for line in picked if line]
    if not picked and not only_errors:
        picked = [line.strip() for line in lines[-40:] if line.strip()]
    return picked


def test_lines(lines: list[str]) -> list[str]:
    picked: list[str] = []
    for index, line in enumerate(lines):
        if "Pending timers:" not in line:
            continue
        for item in lines[index:index + 30]:
            stripped = item.strip()
            if stripped:
                picked.append(stripped)
    for index, line in enumerate(lines):
        if "EXCEPTION CAUGHT BY FLUTTER TEST FRAMEWORK" not in line:
            continue
        block = [item.strip() for item in lines[index:index + 90]]
        for offset, item in enumerate(block):
            if not item:
                continue
            previous = block[offset - 1] if offset else ""
            interesting = (
                "overflowed" in item
                or "error-causing widget" in item
                or (offset >= 1 and "error-causing widget" in previous)
                or ".dart:" in item
                or "RenderFlex" in item
                or "The following" in item
                or "file:///home/runner/work/pallsql/pallsql/lib/" in item
                or "Expected:" in item
                or "Actual:" in item
                or item.startswith("[E]")
                or " [E]" in item
            )
            if interesting or (
                offset >= 1
                and "thrown running a test" in previous
                and not item.startswith("#")
            ):
                picked.append(item)
    if picked:
        return picked[:40]
    return _test_marker_lines(lines)


def _test_marker_lines(lines: list[str]) -> list[str]:
    markers = ("Some tests failed", "Expected:", "Actual:", "Which:", "EXCEPTION",
               "Error:", "error:", "failed", "FAILED", "Test failed", "[E]")
    picked = [line.strip() for line in lines if any(m in line for m in markers)]
    if not picked:
        picked = [line.strip() for line in lines[-50:] if line.strip()]
    return picked


def gradle_lines(lines: list[str]) -> list[str]:
    start = None
    for index, line in enumerate(lines):
        if "What went wrong" in line:
            start = index
            break
    if start is None:
        for index, line in enumerate(lines):
            if "FAILURE:" in line:
                start = max(0, index - 2)
                break
    if start is None:
        block = [line.strip() for line in lines[-40:] if line.strip()]
        return block
    block: list[str] = []
    for line in lines[start:start + 60]:
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("> Run with"):
            continue
        block.append(stripped)
        if len(block) >= 45:
            break
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
        print("usage: ci_report.py <analyze|errors|notes|test|gradle|raw> <logfile> [logfile...]")
        return 2
    mode = argv[1]
    collected: list[str] = []
    for path in argv[2:]:
        lines = read_lines(path)
        if not lines:
            continue
        label = os.path.basename(path)
        if mode in ("analyze", "errors", "notes"):
            for line in analyze_lines(lines, only_errors=(mode == "errors")):
                collected.append(f"[{label}] {line}")
        elif mode == "test":
            collected.extend([f"[{label}] {line}" for line in test_lines(lines)])
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
