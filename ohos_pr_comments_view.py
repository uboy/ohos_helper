#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


COMMENT_HEADER_RE = re.compile(r"^---\s*(.*?)\s*@\s*(.*?)\s*---\s*$")


def collapse_blank_lines(text: str) -> str:
    lines = text.splitlines()
    collapsed: list[str] = []
    blank_run = 0
    for line in lines:
        if line.strip():
            blank_run = 0
            collapsed.append(line.rstrip())
            continue
        blank_run += 1
        if blank_run <= 1:
            collapsed.append("")
    return "\n".join(collapsed).strip()


def parse_comments(raw_text: str) -> tuple[str, list[dict[str, str]]]:
    title = ""
    comments: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    body_lines: list[str] = []

    for raw_line in raw_text.splitlines():
        line = raw_line.rstrip()
        match = COMMENT_HEADER_RE.match(line.strip())
        if match:
            if current is not None:
                current["body"] = collapse_blank_lines("\n".join(body_lines)) or "[empty]"
                comments.append(current)
            current = {"author": match.group(1).strip() or "unknown", "created_at": match.group(2).strip() or "N/A"}
            body_lines = []
            continue
        if current is None:
            if line.strip() and not title:
                title = line.strip().lstrip("💬").strip()
            continue
        body_lines.append(line)

    if current is not None:
        current["body"] = collapse_blank_lines("\n".join(body_lines)) or "[empty]"
        comments.append(current)

    return title or "PR comments", comments


def format_comments(raw_text: str) -> str:
    normalized = collapse_blank_lines(raw_text)
    if not normalized:
        return ""

    title, comments = parse_comments(normalized)
    if not comments:
        return normalized + "\n"

    parts = [title, "=" * min(max(len(title), 24), 72), ""]
    for index, comment in enumerate(comments, start=1):
        parts.append(f"[{index}] {comment['author']}")
        parts.append(f"created: {comment['created_at']}")
        parts.append("-" * 72)
        parts.append(comment["body"])
        if index != len(comments):
            parts.append("")
    return "\n".join(parts).rstrip() + "\n"


def render_text(text: str) -> int:
    pager_disabled = os.environ.get("OHOS_PR_NO_PAGER", "").strip().lower() in {"1", "true", "yes"}
    pager = shutil.which("less")
    if pager_disabled or pager is None or not sys.stdout.isatty():
        sys.stdout.write(text)
        return 0
    completed = subprocess.run([pager, "-R"], input=text, text=True, check=False)
    return int(completed.returncode)


def main() -> int:
    parser = argparse.ArgumentParser(description="Format raw PR comments into a compact viewer-friendly output.")
    parser.add_argument("input", nargs="?", help="Path to a file with raw show-comments output. Reads stdin if omitted.")
    args = parser.parse_args()

    if args.input:
        raw_text = Path(args.input).read_text(encoding="utf-8")
    else:
        raw_text = sys.stdin.read()

    return render_text(format_comments(raw_text))


if __name__ == "__main__":
    raise SystemExit(main())
