# Research

Date: 2026-04-07
Task class: `repo_change`, `non_trivial`

## Current state

- Workspace is a standalone scripts directory, not a git repository.
- Main files:
  - `ohos.sh`
  - `ohos-helper.py`
  - `ohos.conf`
  - `ohos-curl-fallback`
- `ohos.sh` currently supports a single top-level command per run.
- `ohos.sh init` runs `repo init` and then immediately calls `cmd_sync`.
- `ohos.sh sync` currently does three stages:
  1. `repo sync`
  2. `repo forall ... git lfs checkout`
  3. `build/prebuilts_download.sh`
- `ohos-helper.py info --deep` already scans `BUILD.gn` files and prints all matched targets grouped by directory.

## Environment observations

- `repo` exists at `/home/dmazur/bin/repo`.
- `npm` exists at `/home/dmazur/.nvm/versions/node/v22.22.0/bin/npm`.
- A real OHOS repo exists at `/home/dmazur/proj/ohos_master/.repo`.
- The sibling prebuilt link already exists in the expected place:
  - `/home/dmazur/proj/openharmony_prebuilts -> /data/shared/openharmony_prebuilts`
- Shared prebuilts source exists:
  - `/data/shared/openharmony_prebuilts`

## Requested changes

1. Support chained commands, for example:
   - `ohos.sh init sync build`
   - `ohos.sh sync build`
2. Add contextual help per command:
   - `ohos.sh help sync`
   - help should show what the command actually runs and with which parameters
3. Make `sync` more reliable so partial or hidden failures are less likely.
4. Improve `info --deep` discoverability and output structure:
   - include `--deep` in help output
   - make large target sets easier to scan
   - add filtering options
5. Offer dependency installation when missing:
   - `repo`
   - `nvm` / `npm`
6. Verify and create the sibling `openharmony_prebuilts` symlink when needed.

## Design decision: keep execution in Bash for this iteration

The user asked whether the `ohos.sh` logic should move into Python.

Decision for this change set:

- Keep the operational orchestration in `ohos.sh`.
- Keep metadata discovery and reporting in `ohos-helper.py`.

Reasoning:

- `ohos.sh` already owns shell-sensitive behavior:
  - sourcing `ohos.conf`
  - temporary `.npmrc` swap and restore
  - `trap`-based cleanup
  - `repo` / `repo forall` / `build.sh` execution
  - interactive confirmations
- A full executor migration to Python would increase change size and risk in the same patch.
- The requested improvements can be added cleanly without a full rewrite:
  - command-chain dispatcher in Bash
  - per-command help metadata in Bash
  - dependency and symlink checks in Bash
  - richer `info --deep` filtering/grouping in Python

## Reliability gaps in the current sync flow

- The sync flow has no preflight checks for `repo`, `nvm`, or `npm`.
- The sibling `openharmony_prebuilts` symlink is not verified by the script.
- `set -e` is enabled, but there is no explicit step runner that annotates failures with context.
- `repo sync`, LFS checkout, and prebuilts download are not separated into reusable validated stages.
- `init` always auto-syncs internally, which conflicts with command chaining.

## Planned implementation outline

- Add a command-chain dispatcher with explicit command boundaries.
- Preserve backward compatibility for `init` by auto-appending `sync` only when `init` runs alone.
- Add per-command help text that includes:
  - purpose
  - exact underlying commands/templates
  - important options
  - examples
- Add preflight helpers:
  - ensure `repo`
  - ensure `nvm` / `npm`
  - ensure sibling `openharmony_prebuilts` symlink
- Make sync stages explicit and validated:
  - `repo sync`
  - LFS storage configuration and checkout
  - prebuilts download
- Extend `ohos-helper.py info` with filters and structured deep output.
