# Project Agent Rules

## CRITICAL: Use ohos Helper Commands Only

**Agents MUST NOT run raw commands (flash.py, hdc, flash_tool, xdevice, ssh to board servers) directly. All device operations go through ohos wrapper scripts:**

- **Flash**: `bash ohos_device.sh flash --server <host> --device <serial> <firmware>` — never `python3 flash.py` directly
- **XTS run**: `bash ohos_device.sh xts-run` or `bash ohos_device.sh xts-full-run` — never raw `aa test` or `xdevice run`
- **Board init**: `bash ohos_device.sh init-board` — never raw `hdc shell settings`
- **Power**: `bash ohos_device.sh power` — never raw PDU telnet/ssh
- **Device list**: `bash ohos_device.sh list-targets` — never raw `hdc list targets` or `flash_tool LD`
- **SSH to board servers**: use `_ssh_run` from ohos_device.sh or run ohos_device.sh with `--server`

**Exception**: Only bypass wrappers when the user explicitly requests it (e.g., "run flash.py directly for debugging").

- **Board state**: `conf/board-state.json` tracks firmware version on each board. `cmd_flash` updates it automatically on success. If flashing manually (e.g., raw flash.py for debugging), update the file via `_board_state_update <serial> <firmware_path>`.

This repository contains the operator-facing OHOS helper scripts and two nested tools:

- `ohos.sh` - main user-facing wrapper
- `ohos-helper.py` - build, file, and metadata helper
- `ohos_device.sh` - device and bridge helper (init-board, xts-run, xts-full-run, flash, power)
- `ohos_download.sh` - download daily SDK / firmware / XTS packages
- `ohos_pack.py` - package build artifacts into version-stamped archives
- `ohos_sign.sh` - HAP signing: profile generation, app signing, verification
- `arkui-xts-selector/` - XTS selection, reporting, run-store, compare
- `gitee_util/` - PR and comments helper
- `scripts/remote/` - SSH remote execution templates (`_remote_exec.sh` + `.sh.template` files)
- `boards.conf` - board inventory (serials, LocationIDs, servers, outlets)
- `../device-info-app/` - ArkTS app displaying device hardware/software info

## Project Skills

| Skill File | Name | Purpose |
|-----------|------|---------|
| `gitee_util/SKILL.md` | `gitcode-query` | Query PRs, CI status, merged PRs |
| `gitee_util/ci-skill.md` | `openharmony-ci` | CI architecture, build failure diagnosis, manifest pinning |
| `SKILL-device-flash.md` | `device-flash` | Flash firmware, recover boards, LocationID CLI mode, multi-device management |
| `SKILL-device-init.md` | `device-init` | Board prep: screen on, performance mode, USB dialog dismiss |
| `SKILL-xts-run.md` | `xts-run` | XTS static HAP install/run on multiple boards, TSV result collection (quick/debug) |
| `SKILL-xts-full-run.md` | `xts-full-run` | Full XTS suite via xdevice framework (recommended for regression) |
| — | `device-power` | PDU power control (on/off/reboot) for boards via APC Rack PDU |

## Mandatory Workflow

1. Classify every request first:
   - `repo_change`
   - `repo_read`
   - `content_task`
   - `general`
2. For non-trivial `repo_change` tasks, use `.agents/` for all temporary working files (plans, notes, coordination data). Delete when task is complete.
3. Work on one backlog item at a time.
4. Do not start the next backlog item until:
   - implementation is done
   - required checks passed
   - a short self-review was completed

## Branch And Sync Rules

1. Never implement new features directly on `master`.
2. Create a feature branch first in every touched repository.
3. If a change spans this repo and `arkui-xts-selector/`, use matching branch names in both repos when possible.
4. Keep the nested selector repo aligned with a local checkout (e.g. `~/proj/arkui-xts-selector`).
5. When publishing or handing off:
   - sync reviewed selector changes back to the local checkout
   - push only after verification succeeds
   - merge to `master` only after review
6. Do not rewrite history unless the user explicitly asks for it.
7. Main repo remote: `origin -> https://github.com/uboy/ohos_helper.git`

## Build Aliases

| Alias | Product | Env | Description |
|-------|---------|-----|-------------|
| `rk3568` / `rk` | rk3568 | — | Default full build with dynamic XTS |
| `xts` | rk3568 | `./test/xts/acts/build.sh ... xts_suitetype=hap_dynamic` | Explicit alias for XTS (dynamic) |
| `xts-dynamic` | rk3568 | — | Same as xts (dynamic) |
| `xts-static` | rk3568 | `./test/xts/acts/build.sh ... xts_suitetype=hap_static` | XTS static build only |
| `xts-all` / `xts-full` | rk3568 | both | Dynamic + static in sequence |
| `sdk` | ohos-sdk | `sdk_build_arkts=true` | SDK build |
| `sdk-linux` / `sdklin` | ohos-sdk | `sdk_platform=linux` | Linux-only SDK |

## Pack Command (`ohos pack <type>`)

Package post-build artifacts into version-stamped `.tar.gz` archives.
Without `<type>`, auto-detects what was built.

| Type | What it packages | Archive name |
|------|-----------------|-------------|
| `firmware` | `out/<product>/packages/phone/images/*` | `{product}-firmware-{date}-{hash}.tar.gz` |
| `xts` | `out/<product>/suites/acts/*` | `{product}-xts-{date}-{hash}.tar.gz` |
| `libs` | `out/<product>/libs/*` | `{product}-libs-{date}-{hash}.tar.gz` |
| `all` | firmware + xts + libs + metadata | `{product}-all-{date}-{hash}.tar.gz` |
| `list` | (no archive) | Prints available artifacts per type |
| `auto` / (none) | auto-detected | Packs whatever was built; interactive menu when multiple types found |

Options: `--product`, `--output`, `--name`, `--dry-run`, `--list`

## PR Comments (`ohos show-comments`)

```
python3 gitee_util/gitee_query.py show-comments <owner> <repo> <pr_num>
```

Fetches all PR comments including CI bot HTML tables with build log URLs and DCP dashboard links.

## Verification Gates

### Shell wrapper changes

- `bash -n ohos.sh`
- `bash -n ohos_device.sh` if touched
- `bash -n ohos_build_workarounds.sh` if touched
- `bash -n scripts/remote/*.sh` and `bash -n scripts/remote/*.sh.template` if touched
- `python3 -m unittest -v test_ohos_xts_wrapper.py`
- `bash tests/test_build_workarounds.sh` if `ohos_build_workarounds.sh` or `build-workarounds.yaml` touched

### Helper changes

- `python3 -m unittest -v test_ohos_helper.py`
- `python3 -m unittest -v test_ohos_sync.py`
- targeted smoke checks against a real OHOS tree when the change affects file/build lookup

### Selector changes

- `python3 -m py_compile` on modified selector files
- `python3 -m unittest -v arkui-xts-selector/tests/test_cli_design_v1.py`
- `python3 -m unittest -v arkui-xts-selector/tests/test_execution_orchestration.py`
- other focused selector tests when touching download or transport logic

## XTS UX Rules

1. Default console output must stay compact.
2. If selected tests are numerous, write the full runnable list to JSON and print only the path plus the next command.
3. `xts run` must prefer real execution evidence over optimistic wrapper return codes.
4. See `SKILL-device-flash.md` for board flashing, recovery, and multi-device rules.

## Remote Execution Architecture

Commands on remote servers use template-based execution, not inline SSH:

1. **Templates** live in `scripts/remote/*.sh.template` with `{{PLACEHOLDER}}` variables
2. **`_remote_exec()`** substitutes placeholders via sed, pipes script to `ssh ... bash -s`
3. **No SCP needed** — script goes via stdin pipe, no file left on remote host
4. **Existing templates:** `init-board`, `xts-test-hap`
5. **Adding new template:** create `scripts/remote/<name>.sh.template`, call `_remote_exec "$server" <name> KEY=val...`

Never construct complex inline SSH commands — always use templates. See `scripts/remote/_remote_exec.sh` for the helper API.

## CI Build Analysis

When a local build fails but CI daily build succeeds, always check the CI pipeline `preCompile` step for PR merges. CI may merge pending merge requests into `developtools/ace_ets2bundle` (or other repos) during preCompile — these patches may fix build issues that the current master doesn't have.

To check:
```bash
grep "preCompile" <daily_build.log> | grep -o "merge-requests/[0-9]*"
```

To test locally:
```bash
cd developtools/ace_ets2bundle
git fetch https://gitcode.com/openharmony/developtools_ace_ets2bundle.git \
  +refs/merge-requests/<PR_NUM>/head:pr_<PR_NUM>
git merge pr_<PR_NUM> --no-edit
```

## Artifact Lookup Rules

1. GN metadata is only the first lookup layer.
2. For ambiguous or generated inputs, prefer built metadata when available:
   - `module_info.json`
   - testcases metadata
   - `build.ninja` / ninja query
3. Generated assembled `.ets` wrappers must be explained explicitly instead of silently reported as “binary not found”.

## Board Management Requirements (ohos_device.sh)

**MANDATORY: Agents must follow these requirements when modifying ohos_device.sh or related tools. Requirements cannot be changed without explicit user confirmation.**

### Flash (cmd_flash)

| ID | Requirement |
|----|-------------|
| F1 | Remote flash (`--server`) must use tmux on the remote server so the flash survives client disconnect |
| F2 | Flash logs must be written to `~/flash-logs/<short>-<date>.log` on the remote server |
| F3 | After launching remote flash, the client must stream the log in real-time until tmux session ends |
| F4 | User can reconnect via `ssh <server> tmux attach -t flash-<short>` or `ssh <server> tail -f <log>` |
| F5 | LocationID from `boards.conf` is used for CLI mode on multi-device servers; DevNo fallback for single-board |
| F6 | `--server` requires `--device` — no interactive device picking on remote |
| F7 | Firmware path must be validated on the remote server before starting flash |
| F8 | hdc daemon must be killed before flash (USB lock) and restored after |
| F9 | Local flash path must remain unchanged when `--server` is not specified |
| F10 | After successful flash, update `conf/board-state.json` with firmware path, version, timestamp, user, and board serial |
| F11 | Before hdc switch to Loader mode, detect current mode via `flash_tool LD`. If already in Loader with matching LocationID, skip switch and flash directly |
| F12 | Acquire per-board lock (`/tmp/ohos-flash-<short>.lock`) before flash. If locked by live process, warn with details and abort. Stale locks auto-removed. Lock released on completion via trap |

### Board Inventory (boards.conf)

| ID | Requirement |
|----|-------------|
| B1 | Board inventory lives in `conf/boards.conf` (or `$BOARDS_CONF`), sourced as shell |
| B2 | Each board has: serial, short, server, status, outlet, LocationID (Maskrom + Loader), LoaderSerial |
| B3 | Only boards with `STATUS=OK` are selected by default; `--boards`/`--device` overrides |
| B4 | Board iteration pattern: `for i in $(seq 1 $BOARD_COUNT); do indirect var expansion ${!var}` |

### XTS Run (cmd_xts_run — debug/fast path)

| ID | Requirement |
|----|-------------|
| X1 | Uses raw `aa test` commands via SSH remote templates — for quick debug runs |
| X2 | Input: TSV file (hap_file, bundle_name, module_name) + hap directory |
| X3 | Round-robin distribution across boards, parallel via background processes |
| X4 | Per-HAP log capture (arkts.console ring buffer) for non-PASS results |
| X5 | Merged summary.tsv output with pass/fail counts |

### XTS Full Run (cmd_xts_full_run — regression path)

| ID | Requirement |
|----|-------------|
| R1 | Uses xdevice framework (`python -m xdevice run acts`) — the recommended default |
| R2 | Module discovery from `testcases/*.json` with variant filtering (static/dynamic/any) |
| R3 | xdevice bootstrap: discovers packages in ACTS `tools/`, pip installs to `$TMPDIR/ohos_xts_xdevice/` |
| R4 | Shard suite creation: per-shard dirs with user_config.xml + acts.json (ShellKit device prep) |
| R5 | Report format: `devices` dict keyed by serial, with `host` field — compatible with existing `xts_full_runs/` |
| R6 | Dry-run produces plan without side effects (no output dir, no bootstrap, no flash) |
| R7 | Exit code 0 on all pass, 1 on any fail or timeout |
| R8 | Temporary shard directories cleaned up after run |
| R9 | Missing .json for a module causes early failure; missing .hap warns but continues |
| R10 | **Mandatory: Always init boards before test run** — reboot + wake screen + dismiss USB dialog + performance mode. Never skip unless user explicitly says so. |
| R11 | **Test distribution by duration, NOT by module count** — use `cycle1_hap_analysis.json` for measured duration per HAP. Greedy bin-packing (longest-job-first) so all shards finish at roughly the same time. Never round-robin by count. |
| R12 | **Run log on NFS** — `run.log` in output dir, flushed on every write. `tail -f` for live monitoring. |
| R13 | **Always save xdevice stdout/stderr** as artifacts, even on success. Extract failure details from result XMLs and log them. |

### General

| ID | Requirement |
|----|-------------|
| G1 | All shell changes must pass `bash -n` syntax check before commit |
| G2 | All Python changes must pass `python3 -m py_compile` and relevant tests |
| G3 | New commands integrated into `ohos_device.sh` dispatch (case statement at end of file) |
| G4 | Help text (`print_help_*`) must document all options with examples |
| G5 | Remote operations use `_ssh_run()` helper with `OHOS_SSH_USER` from boards.conf |
| G6 | Test runs must save artifacts (logs, results, reports) to `$TEST_ARTIFACT_ROOT/<timestamp>/` (default: `$TMPDIR/ohos_test_artifacts/`) |
| G7 | Artifacts include: stdout/stderr capture, test result XML/JSON, coverage summary |

## Requirement Change Policy

**Agents MUST NOT modify the requirements above without explicit user approval.** When implementing changes:

1. If a change would violate a requirement, stop and ask the user before proceeding.
2. If a new requirement is discovered during implementation, propose it to the user for approval before adding.
3. Tests must verify requirements (behavior), not implementation details.
4. When in doubt about whether a change affects requirements, ask the user.

## Agent Temporary Files

Agents produce temporary working files during tasks. Rules:

1. **All agent temp files** go to `.agents/` (gitignored). This includes: plans, research notes, coordination data, review artifacts, scratch pads.
2. **Delete temp files** when the task is complete. `.agents/` must be empty between tasks.
3. **Persistent knowledge** — insights useful for future tasks must be saved as:
   - Skills: `SKILL-*.md` for operational knowledge (how to flash, how to run XTS, etc.)
   - `AGENTS.md` for project rules, requirements, and workflow
   - `docs/` for reference documentation
   - Never leave knowledge trapped in temp files.
4. **No temp files in repo root.** Files like `CODE_REVIEW.md`, `TODO_*.md`, `*.scratch.md` in the root are forbidden — use `.agents/`.

## Runtime Artifacts

The following are usually runtime outputs, not project deliverables:

- `selector_report.json`
- `selected_tests.json`
- ad-hoc `*_tests_to_run.json`
- ad-hoc diagnostic logs

Default location for such files in this repo: [`.runtime/`](.runtime/README.md)

Keep them out of commits unless the task explicitly asks for checked-in fixtures.
