---
name: ohos-helper-project
description: Use when working on the OHOS helper scripts repository. Covers ohos.sh, ohos-helper.py, ohos_device.sh, nested arkui-xts-selector integration, branch-first workflow, sync rules, verification gates, and compact XTS/reporting expectations.
---

# Ohos Helper Project Skill

Use this guide when the task touches this repository or its nested helper tools.

## Repository Map

- `ohos.sh`
  - main CLI wrapper users run as `ohos ...`
- `ohos-helper.py`
  - build, target, file, and artifact lookup helper
- `ohos_device.sh`
  - device access, remote HDC, bridge packaging, device-oriented help
- `arkui-xts-selector/`
  - selector, ranking, report rendering, run-store, compare, XTS execution planning
- `gitee_util/`
  - PR, comments, and provider-specific API helpers

## Mandatory Working Style

1. Read `AGENTS.md` and `BACKLOG.md` first.
2. For non-trivial repo changes, keep local design state current:
   - `.scratchpad/research.md`
   - `.scratchpad/plan.md`
   - `coordination/tasks.jsonl`
   - `coordination/state/codex.md`
3. Work on a feature branch, not `master`.
4. If the change touches `arkui-xts-selector/`, use a matching feature branch there too.
5. Implement one backlog item at a time.
6. Run targeted verification before review.

## Current Product Direction

- Keep user-facing output compact.
- Prefer JSON artifacts over huge command dumps.
- Make `xts run` prove real execution, not only wrapper success.
- Move device/download/flash responsibilities out of selector-heavy paths.
- Improve source-file-to-artifact lookup with built metadata, not only GN heuristics.

## Verification Matrix

### Wrapper work

- `bash -n ohos.sh`
- `bash -n ohos_device.sh`
- `python3 -m unittest -v test_ohos_xts_wrapper.py`

### Helper work

- `python3 -m unittest -v test_ohos_helper.py`
- `python3 -m unittest -v test_ohos_sync.py`

### Selector work

- `python3 -m py_compile ...`
- `python3 -m unittest -v arkui-xts-selector/tests/test_cli_design_v1.py`
- `python3 -m unittest -v arkui-xts-selector/tests/test_execution_orchestration.py`
- add focused selector tests that match the touched area

## Sync Notes

- Main repo remote: `origin -> https://github.com/uboy/ohos_helper.git`
- Nested selector repo should stay aligned with `/home/dmazur/proj/arkui-xts-selector`
- Publish or merge only after checks and review

## Important Special Cases

- Generated assembled advanced component `.ets` files are not normal source owners for artifact lookup.
- For `.ets` inputs, expect HAP/module/test outputs more often than a standalone binary.
- If many tests are found, put the full runnable list in JSON and keep the console output short.
