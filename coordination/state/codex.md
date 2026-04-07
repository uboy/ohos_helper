# Codex State

Date: 2026-04-07
Status: implementation and verification complete

## Current context

- Task is treated as a non-trivial repo change.
- Local policy files referenced by AGENTS were not present on disk, so the message-provided policy text is being used as the working contract.
- Research and plan artifacts were created in `.scratchpad/`.
- The real sibling prebuilts setup on this machine is:
  - repo root: `/home/dmazur/proj/ohos_master`
  - sibling symlink: `/home/dmazur/proj/openharmony_prebuilts`
  - target: `/data/shared/openharmony_prebuilts`

## Completed work

- Added chained execution support for `init`, `sync`, `reset`, `gc`, and final `build`.
- Added contextual help for `help`, `help sync`, `help build`, and `help info`.
- Added preflight install prompts for missing `repo`, `nvm`, and `npm`.
- Added sibling prebuilts symlink validation and creation logic.
- Tightened the sync flow into explicit repo, LFS, and prebuilts stages.
- Aligned `ohos.conf` command templates with the stricter `git lfs fetch && git lfs checkout` flow.
- Extended `ohos-helper.py info` with:
  - `--deep`
  - `--path-filter`
  - `--target-filter`
  - grouped top-level summaries
  - grouped per-directory target output

## Verification

- `bash -n ohos.sh`
- `python3 -m py_compile ohos-helper.py`
- `bash ohos.sh help`
- `bash ohos.sh help sync`
- `bash ohos.sh help info`
- `python3 ohos-helper.py info --help`
- `python3 /data/shared/common/scripts/ohos-helper.py info ace_engine --deep`
- `python3 /data/shared/common/scripts/ohos-helper.py info ace_engine --deep --path-filter arkts_frontend --target-filter native`

## Remaining caveats

- Interactive install prompts for missing `repo` / `nvm` / `npm` were implemented but not exercised live because those tools are already installed in the current environment.
- Chained mutating flows such as `ohos init sync build` were validated by parser and help paths, but not executed against a fresh repo during this session.
