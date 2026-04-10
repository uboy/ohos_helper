# Backlog

Status legend:

- `active`
- `pending`
- `blocked`
- `done`

## Execution Rules

1. Take one backlog item at a time.
2. Create or reuse a dedicated feature branch before implementation.
3. Update `.scratchpad` and `coordination` state before and after the item.
4. Run targeted checks.
5. Do a short self-review.
6. Only then move to the next item.

## Workflow And Governance

- `done` Project rules and skill guide
  - add tracked `AGENTS.md`
  - add tracked `SKILL.md`
  - keep branch/sync rules explicit in the repo

## XTS Output And Execution

- `done` Compact `ohos xts run --from-report` output
  - avoid replaying the whole selection report
  - show only selected tests, progress, and result
- `done` Real execution validation for `xts run`
  - prefer `xdevice` when ACTS artifacts are available
  - stop treating bare `aa_test RC=0` as sufficient proof of success
- `done` Clarify SDK usage in XTS output
  - stop implying SDK is required for every XTS run path

## Download And Device UX

- `done` Improve Windows bridge UX
  - auto-detect the Linux server IP for `ohos device bridge package-windows`
  - default `--server-user` to the current Linux user
  - explain clearly:
    - which PC has the USB-connected device
    - which Linux host runs `ohos xts` commands
    - which commands run on Windows and which run on Linux
- `done` Interactive `ohos download` without args
  - arrow-key menu
  - `Enter` to run
  - `Esc` to cancel
  - inline key hints
- `done` Clean signal handling
  - `Ctrl+C`
  - `SIGTERM`
  - clear “script stopped” message
  - consistent cleanup
- `pending` Continue device/tool extraction
  - move download/flash/device-prep logic out of selector-heavy code paths
  - keep selector focused on ranking, report, compare, and run-store

## PR And Feedback UX

- `pending` Better `ohos pr` comments viewer
  - navigable console view
  - compact whitespace
  - readable formatting in a pager/TUI

## File And Artifact Lookup

- `done` Improve source-file-to-artifact lookup using built metadata
  - consume `module_info.json` and testcase metadata when present
  - add `build.ninja` / ninja-query fallback
  - improve `.ets` and generated wrapper handling
- `done` Better generated-wrapper messaging
  - explain when an assembled `.ets` file is excluded
  - explain what artifact types were searched

## Integration Work

- `blocked` Integrate `Unification_docs/Dyn_Sta_XTS/run.py`
  - current cloned source is not yet in a usable state
  - unblock when a valid script source is available

## Config UX

- `pending` Extend `ohos npmrc`
  - support explicit original/default registry profile
  - keep mirror profile as a separate mode
