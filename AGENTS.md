# Project Agent Rules

This repository contains the operator-facing OHOS helper scripts and two nested tools:

- `ohos.sh` - main user-facing wrapper
- `ohos-helper.py` - build, file, and metadata helper
- `ohos_device.sh` - device and bridge helper
- `arkui-xts-selector/` - XTS selection, reporting, run-store, compare
- `gitee_util/` - PR and comments helper

## Mandatory Workflow

1. Classify every request first:
   - `repo_change`
   - `repo_read`
   - `content_task`
   - `general`
2. For non-trivial `repo_change` tasks:
   - update `.scratchpad/research.md`
   - update `.scratchpad/plan.md`
   - update `coordination/tasks.jsonl`
   - update `coordination/state/codex.md` after meaningful progress
3. Work on one backlog item at a time.
4. Do not start the next backlog item until:
   - implementation is done
   - required checks passed
   - a short self-review was completed

## Branch And Sync Rules

1. Never implement new features directly on `master`.
2. Create a feature branch first in every touched repository.
3. If a change spans this repo and `arkui-xts-selector/`, use matching branch names in both repos when possible.
4. Keep the nested selector repo aligned with `/home/dmazur/proj/arkui-xts-selector`.
5. When publishing or handing off:
   - sync reviewed selector changes back to `/home/dmazur/proj/arkui-xts-selector`
   - push only after verification succeeds
   - merge to `master` only after review
6. Do not rewrite history unless the user explicitly asks for it.

## Verification Gates

Run only the checks relevant to the touched area, but always run at least one real gate before review.

### Shell wrapper changes

- `bash -n ohos.sh`
- `bash -n ohos_device.sh` if touched
- `python3 -m unittest -v test_ohos_xts_wrapper.py`

### Helper changes

- `python3 -m unittest -v test_ohos_helper.py`
- `python3 -m unittest -v test_ohos_sync.py`
- targeted smoke checks against a real OHOS tree when the change affects file/build lookup

### Selector changes

- `python3 -m py_compile` on modified selector files
- `python3 -m unittest -v arkui-xts-selector/tests/test_cli_design_v1.py`
- `python3 -m unittest -v arkui-xts-selector/tests/test_execution_orchestration.py`
- other focused selector tests when touching download, flashing, or transport logic

## XTS UX Rules

1. Default console output must stay compact.
2. If selected tests are numerous, write the full runnable list to JSON and print only the path plus the next command.
3. `xts run` must prefer real execution evidence over optimistic wrapper return codes.
4. Device/download/flash logic should move toward `ohos_device.sh` or a future dedicated tool instead of growing inside selector reporting paths.

## Artifact Lookup Rules

1. GN metadata is only the first lookup layer.
2. For ambiguous or generated inputs, prefer built metadata when available:
   - `module_info.json`
   - testcases metadata
   - `build.ninja` / ninja query
3. Generated assembled `.ets` wrappers must be explained explicitly instead of silently reported as “binary not found”.

## Runtime Artifacts

The following are usually runtime outputs, not project deliverables:

- `selector_report.json`
- `selected_tests.json`
- ad-hoc `*_tests_to_run.json`
- ad-hoc diagnostic logs

Keep them out of commits unless the task explicitly asks for checked-in fixtures.
