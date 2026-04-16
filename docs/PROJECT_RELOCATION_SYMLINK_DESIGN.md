# Design: Relocate The OHOS Helper Workspace And Preserve The Legacy Path Via Symlink

## Goal

Move the whole OHOS helper project into a new dedicated directory and leave the
current public path as a symbolic link.

Target outcome:

- the real project lives in a new canonical directory
- the old path remains usable
- the old path becomes a symlink entry in its parent directory
- existing user commands keep working through the old path

Example shape:

- current public path:
  - `/data/shared/common/scripts`
- new canonical path:
  - `/data/shared/common/projects/ohos-helper`
- final parent entry:
  - `/data/shared/common/scripts -> /data/shared/common/projects/ohos-helper`

Important filesystem clarification:

- the current directory itself cannot "contain only a symlink"
- the directory entry with that name in the parent must be replaced by a
  symlink after the real tree is moved away

## Why This Needs A Real Design

Today the project already behaves like a self-contained workspace:

- root wrappers:
  - `ohos.sh`
  - `ohos_device.sh`
  - `ohos_download.sh`
  - `ohos-helper.py`
  - `ohos_tdd_runner.py`
  - supporting runtime helpers
- nested dependencies:
  - `arkui-xts-selector/`
  - `gitee_util/`
- tracked docs, tests, runtime metadata, and git state

But there are still path assumptions that matter for relocation:

- shell wrappers resolve `SCRIPT_DIR` from `dirname "$0"` instead of a
  symlink-aware realpath helper
- several help/error texts still print the current absolute path literally
- multiple tests hardcode `/data/shared/common/scripts/...`
- `AGENTS.md` and other docs reference the current workspace path directly

If the tree is moved without hardening, the symlink may preserve some flows but
break others or leak the new internal path inconsistently.

## Current Observations

### 1. Most Python entrypoints are already close to relocatable

Examples:

- `ohos_xts_artifacts.py`
- `ohos_tdd_runner.py`
- selector modules under `arkui-xts-selector/src/...`

These mostly use `Path(__file__).resolve()`, which is already symlink-aware and
therefore compatible with a moved real root.

### 2. Shell wrappers are the main relocation risk

Current wrappers use:

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
```

That gives the launch directory, not the real directory of the script target.

This is acceptable when the project is a normal directory, but becomes wrong
after relocation because:

- dependency lookup should follow the real moved tree
- user-facing commands may still need to preserve the legacy symlink path

### 3. The repo should move as one unit, not file-by-file

The project is already a git root with submodules:

- root `.git`
- submodules in `.gitmodules`
  - `arkui-xts-selector`
  - `gitee_util`

Trying to move only "some files related to ohos" would create a fragile split.
The correct relocation unit is the whole project root.

### 4. There are foreign local files in the current root today

Current non-project local files include:

- `ai-env.sh`
- `ai-targets.conf`
- `proxy.conf`
- `proxy.sh`

Ignored local/runtime content also exists:

- `.scratchpad/`
- `coordination/`
- `.runtime/`
- `out/`
- `patches/`

This matters because the target state says the old path should become only a
symlink. That cannot happen cleanly if unrelated local files are left behind in
the old directory.

## Design Decision

The relocation feature should move the **entire project root** to a new
canonical location and then replace the old path with a symlink.

It should not try to cherry-pick "OHOS-only" files out of the current root.

Reason:

- the git root, submodules, tests, docs, runtime helpers, and wrapper
  entrypoints are tightly coupled
- partial movement would create two semi-valid roots instead of one valid root
- a full-root move keeps git and submodule semantics intact

## Scope

In scope:

- root git repository
- nested submodules
- wrapper scripts and Python tools
- tracked docs and tests
- project-local runtime folders that are intentionally part of the workspace
  layout
- compatibility via legacy symlink path

Out of scope:

- moving user-global config under `~/.config/...`
- changing download/cache roots such as `/data/shared/common/xts_tests`
- migrating arbitrary unrelated local files silently without policy
- changing the public CLI surface beyond relocation support

## Target Path Model

The implementation should distinguish two path concepts.

### 1. Launch Path

The path the user typed or the automation invoked.

Examples:

- `/data/shared/common/scripts/ohos.sh`
- `/data/shared/common/scripts/ohos_device.sh`

Use for:

- user-facing copy-paste commands
- backward-compatible remote wrapper command generation
- help messages that should keep showing the stable public path

### 2. Real Project Root

The resolved filesystem target after following symlinks.

Example:

- `/data/shared/common/projects/ohos-helper`

Use for:

- dependency lookup
- locating nested submodules
- internal Python `PYTHONPATH` and helper resolution
- git and filesystem integrity checks

## Required Hardening Before Any Move

### 1. Add a shared shell path resolver

Every shell wrapper should use a common symlink-aware helper instead of raw
`dirname "$0"`.

Required outputs:

- `OHOS_LAUNCH_DIR`
- `OHOS_LAUNCH_PATH`
- `OHOS_REAL_DIR`
- `OHOS_REAL_ROOT`

Contract:

- internal file lookup uses `OHOS_REAL_DIR`
- user-visible command rendering prefers `OHOS_LAUNCH_PATH`

### 2. Stop hardcoding the current absolute root in wrapper strings

Current examples that must change:

- `ohos.sh requires bash. Run it with: bash /data/shared/common/scripts/ohos.sh ...`
- equivalent messages in:
  - `ohos_device.sh`
  - `ohos_download.sh`

These should render the actual launch path instead of a frozen machine path.

### 3. Make tests path-dynamic

Several tests currently hardcode the current absolute workspace path.

These should switch to one of:

- `Path(__file__).resolve().parent / "ohos.sh"`
- environment override
- temp workspace fixture with symlinked launch path

This is a mandatory precondition, otherwise relocation support cannot be
verified automatically.

### 4. Review user-facing path rendering in selector output

The selector already uses resolved Python paths in many places. That is good
for correctness, but after relocation it may print the new canonical real path.

That is acceptable for storage correctness, but design should define whether
human output should prefer:

- the canonical real path
- or the stable legacy symlink path when equivalent

Recommended rule:

- internal storage uses canonical real paths
- user-facing wrapper commands keep the legacy launch path
- raw artifact paths may remain canonical if they point into the real root

## Relocation Workflow

## Phase 0 - Dry-run inventory

Add an admin-style relocation flow, for example:

```bash
ohos admin relocate --target-root /data/shared/common/projects/ohos-helper --legacy-link /data/shared/common/scripts --dry-run
```

Dry-run must report:

- current detected real root
- requested target root
- requested legacy link path
- tracked git status summary
- submodule presence
- foreign local files in the current root
- ignored/runtime directories present
- whether launch-path hardening is already complete

## Phase 1 - Preflight gates

Relocation must stop unless all gates pass.

Required gates:

- current root is a git repository
- submodule directories exist
- target root does not already contain conflicting data
- legacy path is a real directory, not already a wrong symlink
- no in-progress dangerous operation is detected
- foreign local files are either:
  - explicitly approved for movement
  - explicitly excluded and relocated elsewhere first

Recommended default policy:

- fail closed when foreign files are present
- print them and require explicit override

This is necessary because the current workspace already contains non-project
local files.

## Phase 2 - Atomic move strategy

The feature should move the whole root from the parent directory, not from
inside the directory being replaced.

Required sequence:

1. lock relocation
2. resolve and validate parent directories
3. move current root to the target path
4. create the legacy symlink at the old path
5. run post-move verification through the legacy path
6. if verification fails:
   - remove the symlink
   - move the tree back
   - report rollback status

The feature should not delete the original root before verification succeeds.

## Phase 3 - Post-move verification

Minimum verification set:

- `bash <legacy-link>/ohos.sh help`
- `bash <legacy-link>/ohos.sh xts help`
- `bash <legacy-link>/ohos_device.sh help`
- `bash <legacy-link>/ohos_download.sh help`
- `python3 <legacy-link>/ohos_tdd_runner.py --help`
- `git -C <legacy-link> status`
- `git -C <legacy-link> submodule status`
- selector smoke:
  - `PYTHONPATH=<legacy-link>/arkui-xts-selector/src python3 -m arkui_xts_selector --help`

Recommended additional verification:

- one wrapper test that launches through the symlink path
- one selector test that confirms default project root resolution still works

## Foreign File Policy

Because the current root already contains local files unrelated to the tracked
project, relocation needs an explicit policy.

Recommended behavior:

- default:
  - relocation aborts and lists foreign files
- optional override:
  - `--move-foreign-files-with-root`
- optional safer override:
  - `--stash-foreign-files-to <path>`

Recommended default is the safer one:

- do not silently move unrelated local files

## Git And Submodule Handling

The design assumes the whole git root is moved as one directory.

That preserves:

- root `.git`
- submodule worktrees
- `.gitmodules`
- current branch state

The feature should still verify after the move:

- `git status` works through the legacy symlink path
- `git submodule status` resolves both nested repos correctly

## Rollback Design

Rollback should be first-class, not ad-hoc.

Rollback is required when:

- symlink creation fails
- post-move verification fails
- submodule or git checks fail

Rollback sequence:

1. remove the newly created legacy symlink if it exists
2. move the canonical directory back to the original location
3. re-run a minimal sanity check
4. print whether rollback fully restored the old state

## Risks

### 1. Shell launch-path ambiguity

If wrappers do not distinguish launch path from real path, some commands will:

- look for dependencies in the wrong directory
- or print the wrong path back to the user

### 2. Test brittleness

Current absolute-path tests will either fail or falsely pin the old root
forever.

### 3. Foreign local files blocking clean replacement

Because the old path must become a symlink entry, any leftover unrelated files
in the old directory are a real blocker, not cosmetic noise.

### 4. Output path inconsistency

Some Python modules use resolved paths for run store and artifact output. That
is correct internally, but the design must accept that displayed artifact paths
may switch to the canonical root after relocation.

## Acceptance Criteria

The feature is complete only when all of the following are true:

- the real project root can be moved to a new canonical path
- the old public path becomes a symlink entry in the parent directory
- wrappers launched through the old path still work
- nested submodules still resolve correctly
- no hardcoded absolute current-root strings remain in runtime-critical shell
  behavior
- tests exist for symlink-based launch behavior
- relocation fails safely when foreign local files are present without
  explicit approval
- rollback works on post-move verification failure

## Recommended Implementation Order

1. Path-hardening only
   - shell resolver
   - dynamic tests
   - remove hardcoded runtime path strings
2. Dry-run relocation command
   - inventory
   - foreign-file reporting
   - no filesystem mutation yet
3. Real relocation with rollback
4. Symlink-launch integration tests

## Final Decision

Implement relocation as a full-root move with legacy-path symlink
compatibility.

Do not implement it as a selective file shuffle.

The critical engineering rule is:

- resolve the real project root for internals
- preserve the launch path for compatibility-facing UX

That gives a design that is operationally safe, testable, and compatible with
the current git + submodule structure.
