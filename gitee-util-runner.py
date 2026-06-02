#!/usr/bin/env python3
"""Compatibility runner for the vendored gitee_util repository."""

from __future__ import annotations

import collections
import collections.abc
import runpy
import sys
from pathlib import Path


def ensure_collections_compat() -> None:
    aliases = (
        "Mapping",
        "MutableMapping",
        "Sequence",
        "MutableSequence",
        "Set",
        "MutableSet",
        "Iterable",
    )
    for name in aliases:
        if not hasattr(collections, name):
            setattr(collections, name, getattr(collections.abc, name))


def main() -> None:
    repo_dir = Path(__file__).resolve().parent / "gitee_util"
    entrypoint = repo_dir / "git_host_util.py"
    if not entrypoint.is_file():
        raise SystemExit(f"Missing vendored gitee_util entrypoint: {entrypoint}")

    ensure_collections_compat()
    sys.path.insert(0, str(repo_dir))
    sys.argv[0] = str(entrypoint)
    runpy.run_path(str(entrypoint), run_name="__main__")


if __name__ == "__main__":
    main()
