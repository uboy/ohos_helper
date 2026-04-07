# Plan

Date: 2026-04-07
Owner: Codex

## Goals

- Improve `ohos.sh` usability for routine OHOS flows.
- Reduce hidden setup and sync failures.
- Make `ohos-helper.py info --deep` usable on components with hundreds of targets.
- Leave a local design trail in case implementation stops mid-session.

## Scope

In scope:

- chained commands in `ohos.sh`
- contextual `help <command>`
- dependency prompts for missing `repo`, `nvm`, `npm`
- sibling `openharmony_prebuilts` symlink validation/creation
- stricter sync stage execution
- `ohos-helper.py info --deep` help/output/filter improvements

Out of scope for this patch:

- full Bash-to-Python rewrite of `ohos.sh`
- remote dependency installs during verification
- broad refactor of unrelated commands

## Implementation plan

1. Add command metadata and dispatch support in `ohos.sh`.
2. Add preflight helpers for:
   - `repo`
   - `nvm`
   - `npm`
   - sibling `openharmony_prebuilts` symlink
3. Refactor sync into explicit stage helpers with clearer failures.
4. Update `init` behavior for chained execution while preserving old single-command flow.
5. Add `help <command>` with command-specific detail and examples.
6. Extend `ohos-helper.py`:
   - document `--deep`
   - add `--path-filter`
   - add `--target-filter`
   - improve grouped summary output
7. Run targeted verification on shell syntax and Python CLI help.

## Command-chain parsing rule

- Safe chain targets for this iteration:
  - `init`
  - `sync`
  - `reset`
  - `gc`
  - `build`
- Informational commands remain single-dispatch style.
- `help` stays single-dispatch and may take one optional topic, for example `help sync`.
- `build` may still accept extra trailing `build.sh` arguments. To keep parsing predictable, chained `build` should be the final command in a sequence.

## Sync reliability plan

- Add a `run_step` wrapper to print the stage name and fail with context.
- Add preflight dependency checks before sync/build/init.
- Add explicit symlink verification before stages that depend on prebuilts.
- Make LFS step configure storage and fail if checkout fails.
- Keep cleanup of temporary `.npmrc` and proxy wrapper guarded by `trap`.

## Deep output plan

- Keep current metadata sections from `bundle.json`.
- For `--deep`, print:
  - total counts
  - directory summary with target counts
  - detailed grouped listing
- Add filters:
  - `--path-filter TEXT`
  - `--target-filter TEXT`
- Filters apply to the deep scan only.

## Verification

- `bash -n ohos.sh`
- `python3 -m py_compile ohos-helper.py`
- `./ohos.sh help`
- `./ohos.sh help sync`
- `python3 ohos-helper.py info --help`
- `python3 ohos-helper.py info ace_engine --deep --path-filter arkts_frontend --target-filter native`

## Risks

- Shell chain parsing can become ambiguous if future commands need free-form trailing args.
- Installing `nvm` inside a non-interactive shell can vary by environment. Keep prompts explicit and source `~/.nvm/nvm.sh` when available.
- Some OHOS trees may not use the same prebuilts assumptions. Keep the symlink target configurable in code if needed later.
