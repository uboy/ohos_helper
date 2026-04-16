# ohos_helper

Operator-facing helper workspace for OpenHarmony development.

This repository wraps common OHOS flows and carries two vendored tool repositories:

- `arkui-xts-selector/` - XTS selection, staging, execution, compare
- `gitee_util/` - PR and comments helper

## Bootstrap

Fresh clone with nested tools in one command:

```bash
git clone --recurse-submodules https://github.com/uboy/ohos_helper.git
```

If the main repository was already cloned without submodules:

```bash
git submodule update --init --recursive
```

After pulling new commits in the main repo, refresh pinned nested tools with:

```bash
git pull --ff-only
git submodule update --init --recursive
```

## Layout

- `ohos.sh` - main user-facing wrapper
- `ohos-helper.py` - build, file, and metadata helper
- `ohos_device.sh` - device and bridge helper
- `ohos_download.sh` - artifact download helper
- `arkui-xts-selector/` - vendored selector tool
- `gitee_util/` - vendored PR helper

## Design Notes

- [Project Relocation Design](docs/PROJECT_RELOCATION_SYMLINK_DESIGN.md) - move the whole workspace to a new canonical directory and preserve the old path as a symlink entry

## Workspace Relocation

You can validate and execute a full-root move using:

```bash
ohos admin relocate --target-root /data/shared/common/projects/ohos-helper --dry-run
ohos admin relocate --target-root /data/shared/common/projects/ohos-helper --legacy-link /data/shared/common/scripts --yes
```

This moves the real project root and leaves the old path as a symlink.

## Local Configuration (Not In Git)

Use a local config file outside the repository for machine-specific paths:

- default path: `${XDG_CONFIG_HOME:-$HOME/.config}/ohos/local.conf`
- override path: set `OHOS_USER_CONF=/abs/path/to/local.conf`

`ohos.sh` and `ohos_download.sh` load:

1. repo config: `./ohos.conf`
2. local config: `${OHOS_USER_CONF}` (if present)

On hosts with `/data/shared/common`, defaults are:

- tests: `/data/shared/common/xts_tests`
- firmware: `/data/shared/common/firmwares`
- sdk: `/data/shared/common/sdk`

Example `${XDG_CONFIG_HOME:-$HOME/.config}/ohos/local.conf`:

```bash
# Shared root (optional)
OHOS_SHARED_DOWNLOAD_ROOT=/data/shared/common

# Explicit overrides (recommended)
XTS_DOWNLOAD_ROOT=/data/shared/common/xts_tests
FIRMWARE_DOWNLOAD_ROOT=/data/shared/common/firmwares
SDK_DOWNLOAD_ROOT=/data/shared/common/sdk
```

You can verify active values with:

```bash
ohos xts help
ohos download help
```

## Test Modes

The wrapper currently exposes four different test surfaces, and they are intentionally not treated as the same thing:

- `ohos run ut ...` - host-side Linux unit-test wrappers for built `ace_engine` gtest flows
- `ohos test discover ...` - repo-side self-test discovery from component metadata
- `ohos test self-test ...` - developer self-test wrapper with auto-selected `aa test` or `developer_test run -t UT`
- `ohos xts ...` - ArkUI XTS selection, staging, and execution flows

Important scope note for `ohos test self-test`:

- auto mode prefers bundle-backed `aa test` when bundle/module metadata is available, and otherwise falls back to `test/testfwk/developer_test/start.sh run -t UT`
- `bundle.json -> component.build.test` is used as a discovery source only
- not every declared self-test target can be launched with `aa test`
- automatic `aa test` execution is supported only when bundle-backed metadata can be resolved from test assets such as `config.json`
- framework-mode execution requires a local `developer_test` runner in the OHOS tree
- bundle `aa test` execution does not yet auto-pull or parse device-side XML artifacts

Typical examples:

```bash
ohos run ut ace_engine_linux_unittest
ohos test discover ace_engine
ohos test self-test ace_engine --dry-run
ohos test self-test gn_only --framework developer_test --dry-run
ohos test self-test --framework developer_test --all --dry-run
ohos test self-test --bundle com.example.myapplication --module entry
ohos xts select ./foundation/arkui/ace_engine/...
```

## Notes

- The nested tools are pinned by this repository. Update them through normal superproject commits instead of pulling them independently inside the submodule checkout.
- Local build outputs and temporary runtime artifacts are intentionally ignored.

## Sync UX

`reposync` now renders compact progress with ETA for both major network-heavy stages:

- `repo sync`
- `git lfs fetch + checkout`

Behavior details:

- console shows a single updating progress line with elapsed time and ETA
- on stage failure, the script prints a highlighted error and the tail of the stage log
- full stage logs are still written under `.runtime/sync-logs/`
