---
name: device-init
description: Board preparation for testing — screen keep-on, performance mode, USB dialog dismiss
---

# Skill: device-init

## Use When

- Before running XTS tests or any automated test suite
- Board just flashed and booted into new firmware
- Board screen went dark during a long test run
- Need to restore default power settings after testing

## Architecture

```
ohos device init-board [--device <serial>]
        |
        ohos_device.sh -> cmd_init_board()
                |
                per board:
                └── _remote_exec init-board          # template-based execution
                    ├── power-shell wakeup            # wake screen
                    ├── power-shell timeout -o 86400000
                    ├── power-shell setmode 602       # performance mode
                    ├── uitest uiInput dircFling 2    # swipe up to unlock
                    ├── uitest uiInput click 350 800  # dismiss USB dialog
                    └── aa force-stop com.usb.right   # kill USB picker
```

All commands execute via `scripts/remote/init-board.sh.template` — single SSH round-trip per board instead of 6 sequential calls.

## Commands

```bash
# Prepare all boards
ohos device init-board

# Prepare specific board
ohos device init-board --device <serial>

# Custom screen timeout (ms)
ohos device init-board --timeout 6000000

# Restore defaults
ohos device init-board --restore
```

## Board Discovery

Reads `boards.conf` for server/serial mapping. For each board, HDC commands run via SSH to the server where the board is physically connected.

## Key Details

- **Screen timeout** must be long enough for the test campaign (default 24h)
- **USB dialog** appears after every reboot and blocks test execution
- **Performance mode** (602) prevents CPU throttling during tests
- **dircFling 2** swipes up to unlock; **click 350 800** taps "Cancel" on USB dialog
- Must run after flashing and before any test execution

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Screen stays dark | Timeout expired | Re-run init-board |
| Tests fail with "not installed" | USB dialog blocked install | Run init-board, check uitest click |
| Board not found | Wrong server or hdc down | Check `hdc list targets` on server |
