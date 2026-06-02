---
name: device-flash
description: Flash firmware on Rockchip RK3568 boards. Uses LocationID-based CLI mode for multi-device servers, DevNo fallback for single-board servers.
---

# Skill: device-flash

## Use When

- User asks to flash firmware on one or more boards
- Board is stuck in Loader mode and needs recovery
- Need to check device status, list targets, or switch device modes
- Agent needs to understand the flashing architecture before modifying flash-related code

## Architecture

```
ohos device flash [options] <firmware_path>
        │
        ohos_device.sh → cmd_flash()
                │
                ├── kill_hdc_daemon()          # hdc -m holds USB lock
                ├── switch_to_loader()          # hdc -t <serial> target boot -bootloader
                ├── wait_for_loader()           # poll flash_tool LD until Pid=0x350a
                │                               # returns both DevNo AND LocationID
                ├── if boards_on_server > 1:
                │       python3 flash.py -a -i <path> -L <LocationID>    # CLI mode
                │   else:
                │       python3 flash.py -a -i <path> -D <DevNo>         # PTY mode
                │
                └── restore_hdc_daemon()       # restart hdc -m
```

### Flash Modes

| Mode | When | How | Device Selection |
|---|---|---|---|
| **CLI** | Multiple boards on server | `flash_tool -s <LocationID> <cmd>` per command | `-L <LocationID>` |
| **PTY** | Single board on server | `script -q -c flash_tool` batch stdin | `-D <DevNo>` |

**CLI mode is preferred** — DownloadImage works reliably. PTY mode has known DI bugs on some tool versions.

### Key Files

| File | Role |
|---|---|
| `ohos_device.sh` → `cmd_flash()` | Shell orchestrator: hdc kill/restore, Loader switch, LocationID/DevNo selection |
| `$OHOS_TOOLS_DIR/linux/flash.py` | Flash wrapper. `-L` for CLI mode, `-D` for PTY mode |
| `$OHOS_TOOLS_DIR/linux/bin/flash.x86_64` | Rockchip binary (Linux_Upgrade_Tool v1.61) |
| `boards.conf` | Board inventory with LocationID mappings per mode |

**flash.py is the ONLY flash script.** Never use other copies.

## Device Modes

| Mode | Pid | Description |
|---|---|---|
| Maskrom | 0x5000 | Normal running mode. HDC accessible. `hdc list targets` shows serial. |
| Loader | 0x350a | Flash mode. `flash.x86_64 LD` shows DevNo. Required for flashing. |

Serial in Maskrom (HDC) differs from serial in Loader — same physical board, different USB identities.
**LocationID also differs** between Maskrom and Loader modes for most boards.

## Board Inventory (boards.conf)

Each board has:
- `BOARD_<N>_SERIAL` — HDC serial (Maskrom mode)
- `BOARD_<N>_LOCATIONID_MASKROM` — LocationID in Maskrom mode
- `BOARD_<N>_LOCATIONID_LOADER` — LocationID in Loader mode (used for flashing)
- `BOARD_<N>_LOADER_SERIAL` — SerialNo in Loader mode
- `BOARD_<N>_SERVER` — which server the board is physically connected to

## Commands

```
# Flash specific board by HDC serial (auto-switches to Loader, uses LocationID if multi-board)
ohos device flash --device <hdc_serial> /path/to/firmware/

# Force LocationID (CLI mode)
python3 flash.py -a -i /path/to/firmware/ -L <Loader_LocationID>

# Force DevNo (PTY mode)
python3 flash.py -a -i /path/to/firmware/ -D <DevNo>

# Interactive: pick firmware + device
ohos device flash

# List devices
hdc list targets                    # HDC-visible devices (Maskrom mode)
flash.x86_64 LD                     # All Rockchip devices (both modes)
flash.x86_64 -s <LocationID> LD     # Filter by LocationID
```

## CLI Mode Flash Sequence (-L <LocationID>)

Each command is a separate `flash_tool -s <LocationID>` invocation:

1. `UL <MiniLoaderAll.bin> -noreset` — upgrade loader
2. Wait for device re-enumeration (same LocationID)
3. `TD` — test device
4. `DI -p <parameter.txt>` — write GPT/partition table
5. `DI -<part> <image>` — flash each partition
6. `RD` — reboot device

## Multi-Device Safety

When 2+ boards are on the same server:

1. **Always use `-L <LocationID>` (CLI mode)** — not `-D <DevNo>`
2. LocationID is stable per USB port — doesn't change between sessions
3. CLI mode runs each command separately — no cross-contamination
4. Boards on different servers can be flashed in parallel

**Never flash without explicit device selection when multiple devices are present.**

## Manual Flash Procedure (for a single board on multi-device server)

```bash
SERVER="your-server"            # server hostname
HDC_SERIAL="<serial>"           # from boards.conf
LOADER_LOCATIONID="144"         # from boards.conf
FIRMWARE="/path/to/firmware/"

# 1. Verify board is online
ssh $SERVER "hdc -t $HDC_SERIAL list targets"

# 2. Switch to Loader mode
ssh $SERVER "hdc -t $HDC_SERIAL target boot -bootloader"
sleep 6

# 3. Verify Loader mode with correct LocationID
ssh $SERVER "$OHOS_TOOLS_DIR/linux/bin/flash.x86_64 -s $LOADER_LOCATIONID LD"

# 4. Flash with LocationID (CLI mode)
ssh $SERVER "python3 $OHOS_TOOLS_DIR/linux/flash.py -a -i $FIRMWARE -L $LOADER_LOCATIONID"

# 5. Verify board booted back
sleep 30
ssh $SERVER "hdc -t $HDC_SERIAL list targets"
```

## Parallel Flashing (different servers)

```bash
# Boards on different servers can flash simultaneously
# Example: server2 + server3 in parallel

ssh your-server2 "hdc -t <serial1> target boot -bootloader; sleep 6; python3 flash.py -a -i <fw> -L <lid1>" &
ssh your-server3 "hdc -t <serial2> target boot -bootloader; sleep 6; python3 flash.py -a -i <fw> -L <lid2>" &
wait
```

## Board Recovery

If a board is stuck in Loader mode after failed flash:
1. Flash again: `python3 flash.py -a -i <good_firmware> -L <LocationID>`
2. `RD` at end reboots into OS
3. If board unresponsive — physical power cycle via PDU (`ohos device power cycle <outlet>`)

If hdc doesn't see a board after flash:
- Wait 30s — board may still be booting
- Check `flash.x86_64 LD` — might be in Loader (needs flash) or Maskrom (booting)

## Safety Rules

1. **Always ask user permission before flashing.** Physical hardware can be bricked.
2. **Use LocationID (CLI mode) when multiple boards on server.** DevNo is unreliable in multi-device scenarios.
3. **Verify correct LocationID.** Wrong LocationID = wrong board gets flashed.
4. **hdc must be stopped before flash.** `hdc -m` holds USB FD locks.
5. **Restore hdc after flash.** Otherwise device access is broken.
6. **Use only `$OHOS_TOOLS_DIR/linux/flash.py`.** No other flash.py is valid.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| DI hangs/returns instantly in interactive mode | DownloadImage bug in PTY mode | Use CLI mode: `flash.py -L <LocationID>` |
| `Creating comm object failed` | Device in Maskrom (Pid=0x5000) | Switch to Loader: `hdc -t <serial> target boot -bootloader` |
| Board doesn't enter Loader | MiniLoader broke Loader entry | Physical power cycle, use buttons, or DB from Maskrom |
| Wrong board flashed | Wrong LocationID/DevNo | Always verify LocationID matches target board |
| `hdc list targets` empty after flash | hdc not restored | Run `nohup hdc -m &` |
| `command is invalid` from flash tool | Using `DI` instead of `DownloadImage` | flash.py handles this internally |
