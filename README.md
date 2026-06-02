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
- `ohos_sign.sh` - HAP and provisioning profile signing helper
- `arkui-xts-selector/` - vendored selector tool
- `gitee_util/` - vendored PR helper

## Design Notes

- [Project Relocation Design](docs/PROJECT_RELOCATION_SYMLINK_DESIGN.md) - move the whole workspace to a new canonical directory and preserve the old path as a symlink entry

## Workspace Relocation

You can validate and execute a full-root move using:

```bash
ohos admin relocate --target-root ~/projects/ohos-helper --dry-run
ohos admin relocate --target-root ~/projects/ohos-helper --legacy-link ~/scripts --yes
```

This moves the real project root and leaves the old path as a symlink.

## Local Configuration (Not In Git)

Use a local config file outside the repository for machine-specific paths:

- default path: `${XDG_CONFIG_HOME:-$HOME/.config}/ohos/local.conf`
- override path: set `OHOS_USER_CONF=/abs/path/to/local.conf`

`ohos.sh` and `ohos_download.sh` load:

1. repo config: `./ohos.conf`
2. local config: `${OHOS_USER_CONF}` (if present)

On hosts with a shared download root, defaults are:

- tests: `$HOME/.cache/ohos-downloads/tests`
- firmware: `$HOME/.cache/ohos-downloads/firmware`
- sdk: `$HOME/.cache/ohos-downloads/sdk`

Example `${XDG_CONFIG_HOME:-$HOME/.config}/ohos/local.conf`:

```bash
# Shared root (optional)
OHOS_SHARED_DOWNLOAD_ROOT=$HOME/.cache/ohos-downloads

# Explicit overrides (recommended)
XTS_DOWNLOAD_ROOT=$HOME/.cache/ohos-downloads/tests
FIRMWARE_DOWNLOAD_ROOT=$HOME/.cache/ohos-downloads/firmware
SDK_DOWNLOAD_ROOT=$HOME/.cache/ohos-downloads/sdk
```

You can verify active values with:

```bash
ohos xts help
ohos download help
ohos sign help
```

## Sync Notes

`ohos sync` runs three stages in order:

1. `repo sync`
2. `git lfs fetch + checkout`
3. `build/prebuilts_download.sh`

The wrapper now prints an explicit completion line after each stage, so long syncs do not look stuck at `repo sync 100%` when they are already moving on to LFS or prebuilts.
The LFS stage now hydrates into repo-local `.git/lfs` storage instead of depending on shared mirror writes, and it fails early if critical ArkUI `.tgz` files are still Git LFS pointer files.

When you chain commands such as `ohos init ... sync build rk3568`, the execution is fail-fast: if `init`, `sync`, or `build` fails, later steps are not started and the wrapper prints which chain step aborted.

If you need the tree-local SDK prebuilts that some SDK packaging or integration flows expect under `prebuilts/`, use:

```bash
ohos sync --download-sdk
```

This forwards `--download-sdk` to `build/prebuilts_download.sh`. It is not the same as `ohos download sdk`, which manages shared downloaded SDK artifacts outside the tree. `--download-sdk` makes sync heavier and is unnecessary for a normal source sync/build loop.

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

## Signing HAP Files

The wrapper provides HAP (HarmonyOS Ability Package) and provisioning profile signing via `ohos sign`. This uses the OpenHarmony `hap-sign-tool.jar` to sign applications for installation on OpenHarmony devices.

### Setup

Initialize signing certificates by copying missing files from your OpenHarmony source tree:

```bash
ohos sign init
```

If you need full certificate chain generation, use `init --full` (requires `autosign.py` from `developtools/hapsigner/autosign/`).

### Signing Modes

Two signing modes are supported:

- `debug` - Uses debug certificates and profile templates (default)
- `release` - Uses release certificates and profile templates

Configure the default mode in `ohos.conf`:

```bash
SIGN_MODE=release  # or debug
```

### Subcommands

#### `ohos sign init`

Prepare signing certificates. Copies missing files from `ohos_root/developtools/hapsigner/dist/` to the detected toolchain directory.

```bash
ohos sign init           # Copy missing files from ohos_root
ohos sign init --full    # Full certificate generation (not yet implemented)
```

#### `ohos sign profile`

Sign a provisioning profile (JSON template → P7B signed profile).

```bash
ohos sign profile [--debug|--release] [-o FILE]
```

Options:

- `--debug` - Use debug profile certificate (default)
- `--release` - Use release profile certificate
- `-o, --output FILE` - Output P7B file path (default: temporary file)

Example:

```bash
ohos sign profile --debug -o app-profile.p7b
ohos sign profile --release -o release-profile.p7b
```

#### `ohos sign app`

Sign a HAP file or all unsigned HAPs in a directory using a pre-signed profile.

```bash
ohos sign app <file|dir> [--profile FILE] [--debug|--release] [-o FILE]
```

Options:

- `--profile FILE` - Path to signed profile P7B (auto-generated if not specified)
- `--debug` - Use debug mode (default)
- `--release` - Use release mode
- `-o, --output FILE` - Output HAP file path (for single file input)

Example:

```bash
# Sign single HAP with auto-generated profile
ohos sign app entry-default-unsigned.hap

# Sign with specific profile
ohos sign app entry-default-unsigned.hap --profile app-profile.p7b -o entry-default-signed.hap

# Sign all unsigned HAPs in directory
ohos sign app ./build/default/outputs/default/ --release
```

#### `ohos sign auto`

Sign profile and app in one step. This is the most common workflow.

```bash
ohos sign auto <file|dir> [--debug|--release] [-o FILE]
```

Options:

- `--debug` - Use debug mode (default)
- `--release` - Use release mode
- `-o, --output FILE` - Output HAP file path (for single file input)

Example:

```bash
# Sign single HAP (auto-generates profile)
ohos sign auto entry-default-unsigned.hap

# Sign all unsigned HAPs in directory in release mode
ohos sign auto ./build/default/outputs/default/ --release
```

#### `ohos sign verify`

Verify the signature of a signed HAP file.

```bash
ohos sign verify <file>
```

Example:

```bash
ohos sign verify entry-default-signed.hap
```

### Configuration

Configure signing behavior in `ohos.conf`:

```bash
# Toolchain path (auto-detected if empty)
SIGN_TOOL_PATH=/path/to/toolchains/lib

# Keystore and key passwords (default: 123456)
SIGN_KEYSTORE_PWD=123456
SIGN_KEY_PWD=123456

# Default signing mode
SIGN_MODE=debug

# Profile key aliases
SIGN_KEY_ALIAS_APP="openharmony application release"
SIGN_KEY_ALIAS_PROFILE="openharmony application profile release"

# Custom profile template (optional)
SIGN_PROFILE_TEMPLATE=/path/to/custom-profile-template.json
```

### Toolchain Resolution

The signing toolchain is auto-detected in the following order:

1. `SIGN_TOOL_PATH` configuration variable
2. `$OHOS_TOOLS_DIR/toolchains/lib/` (shared tools)
3. Latest downloaded SDK: `${SDK_DOWNLOAD_ROOT}/ohos-sdk-public/<tag>/toolchains/lib/`
4. OpenHarmony source tree: `${OHOS_REPO_ROOT}/developtools/hapsigner/dist/`

If `OpenHarmonyApplication.pem` is missing from the detected toolchain, run `ohos sign init` to copy it from `ohos_root/developtools/hapsigner/dist/`.

### Requirements

- Java 11 or later required (uses `hap-sign-tool.jar`)
- Valid signing certificates: `OpenHarmony.p12`, `OpenHarmonyApplication.pem`, `OpenHarmonyProfileDebug.pem`, `OpenHarmonyProfileRelease.pem`
- Profile templates: `UnsgnedDebugProfileTemplate.json`, `UnsgnedReleasedProfileTemplate.json`

### Typical Workflow

```bash
# 1. Initialize certificates (first time only)
ohos sign init

# 2. Sign HAP for testing (debug mode)
ohos sign auto ./entry/build/default/outputs/default/entry-default-unsigned.hap

# 3. Sign for release
ohos sign auto ./entry/build/default/outputs/default/ --release

# 4. Verify signed HAP
ohos sign verify entry-default-signed.hap
```

## Device Flashing

Flash firmware onto Rockchip RK3568 boards. Supports multi-device environments with LocationID-based CLI targeting.

### Quick Start

```bash
# Interactive: pick firmware + device
ohos device flash

# Flash specific firmware to specific board (recommended)
ohos device flash --device <hdc_serial> /path/to/firmware/

# Flash board already in Loader mode
ohos device flash --devno <N> /path/to/firmware/

# Check device status
ohos device list-targets
```

### How It Works

1. **Stops hdc daemon** — `hdc -m` holds USB locks that block the flash tool
2. **Switches device to Loader mode** — `hdc -t <serial> target boot -bootloader` (only with `--device`)
3. **Detects multi-device** — counts boards on server; picks CLI or PTY mode automatically
4. **Flashes all partitions** — UL → TD → DI (parameter + each partition image) → RD
5. **Reboots device** — `rd` command resets the board, it boots into the new firmware
6. **Restores hdc daemon** — restarts `hdc -m` for normal device access

### Flash Modes

| Mode | When | Device Selection | Method |
|---|---|---|---|
| **CLI** (preferred) | Multiple boards on server | `-L <LocationID>` | Separate `flash_tool -s <LocationID>` per command |
| **PTY** | Single board on server | `-D <DevNo>` | Batch stdin via `script -q -c flash_tool` |

CLI mode is preferred — DownloadImage works reliably. PTY mode has known DI bugs.

`ohos device flash` auto-selects CLI mode when multiple boards are detected on the server. No manual flag needed.

### Device Selection

- `--device <serial>` — HDC serial number (from `boards.conf` or `hdc list targets`). Switches this board to Loader mode.
- `--devno <N>` — Rockchip DevNo (from `flash.x86_64 LD`). For single-board servers only.
- `--locationid <ID>` — Rockchip LocationID. Auto-selected from `boards.conf` when using `--device` on multi-board server.

LocationID is stable per USB port and differs between Maskrom (HDC) and Loader modes. `boards.conf` stores both.

### Multi-Device Safety

When 2+ boards are on the same server, `cmd_flash()` automatically uses CLI mode with LocationID from `boards.conf`. No cross-contamination — each flash command targets a single board.

Boards on different servers can be flashed in parallel.

### Board Recovery

If a board is stuck in Loader mode:

```bash
# Re-flash with known-good firmware (auto-detects LocationID from boards.conf)
ohos device flash --device <hdc_serial> /path/to/firmware/
```

If `hdc list targets` is empty after flash, wait 30s — the board may still be booting.

### Components

| Component | Path | Role |
|---|---|---|
| Shell orchestrator | `ohos_device.sh` → `cmd_flash()` | hdc kill/restore, Loader switch, LocationID/DevNo selection |
| Flash wrapper (CLI + PTY) | `$OHOS_TOOLS_DIR/linux/flash.py` | `-L` for CLI mode, `-D` for PTY mode |
| Rockchip binary | `$OHOS_TOOLS_DIR/linux/bin/flash.x86_64` | Linux_Upgrade_Tool v1.61 |
| Board inventory | `boards.conf` | Serial, LocationID (Maskrom + Loader), server mapping |

See `SKILL-device-flash.md` for detailed architecture, safety rules, and troubleshooting.

## Board Preparation

Prepare one or all boards for testing — keep screen on, set performance mode:

```bash
ohos device init-board                    # all visible boards, 24h screen timeout
ohos device init-board --device <serial>  # specific board
ohos device init-board --timeout 6000000  # 100 min screen timeout
ohos device init-board --restore          # restore defaults
```

What it does per board:

1. Wake screen (`power-shell wakeup`)
2. Override screen-off timeout to 24h (`power-shell timeout -o 86400000`)
3. Set performance mode (`power-shell setmode 602`)
4. Swipe up to unlock screen (`uitest uiInput dircFling 2`)
5. Dismiss USB dialog (`uitest uiInput click 350 800` + `aa force-stop com.usb.right`)

Board discovery reads `boards.conf` for server/serial mapping. Boards on remote servers are accessed via SSH.

## PDU Power Control

Control APC Rack PDU power outlets for boards with assigned outlets:

```bash
ohos device power list                          # list all outlets
ohos device power on 3                          # turn on outlet 3
ohos device power off --board feb8800           # turn off by board name
ohos device power reboot --board a2eba00        # power cycle
ohos device power status 4                      # check outlet status
```

PDU credentials configured in `boards.conf` (`PDU_HOST`, `PDU_USER`, `PDU_PASS`, `PDU_PROTO`).

## XTS Static Test Execution

Run XTS static tests across multiple boards in parallel:

```bash
ohos device xts-run --tsv tests.tsv --hap-dir /path/to/haps
```

Options:

- `--tsv <file>` — TSV file with columns: `hap_file`, `bundle_name`, `module_name`
- `--hap-dir <dir>` — directory containing HAP files
- `--output-dir <dir>` — output directory (default: `./xts-results`)
- `--boards <server:serial,...>` — explicit board list (default: auto-detect from `boards.conf`)
- `--ssh-user <user>` — SSH user for remote servers (default: `$USER`)
- `--no-init` — skip board initialization
- `--continue` — skip already-completed tests from previous run

Output: per-group TSV results and merged `summary.tsv` with pass/fail counts.

Example:

```bash
# Full run on all boards
ohos device xts-run \
    --tsv tests.tsv \
    --hap-dir /path/to/haps/

# Resume interrupted run
ohos device xts-run --tsv tests.tsv --hap-dir ./haps --continue
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
- use `ohos sync --raw-output` when you want the underlying `repo` / `git lfs` output directly instead of the compact progress renderer
- daily artifact utility reports now suppress duplicate firmware `primary_root` when it is identical to `extracted_root`, and include `manifest_path` when a firmware/SDK manifest is discovered
