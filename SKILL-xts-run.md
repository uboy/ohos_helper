---
name: xts-run
description: XTS static HAP test execution on multiple boards with TSV result collection
---

# Skill: xts-run

## Use When

- Running XTS static regression across multiple boards
- Need to install, execute, and collect results for hundreds of HAP tests
- Resuming an interrupted test campaign

## Architecture

```
ohos device xts-run --tsv <file> --hap-dir <dir>
        |
        ohos_device.sh -> cmd_xts_run()
                |
                ├── parse TSV (hap_file, bundle_name, module_name)
                ├── split into N groups (one per board)
                │
                per group (parallel via cmd_xts_run_group):
                ├── for each HAP:
                │   └── _remote_exec xts-test-hap        # template-based execution
                │       ├── hdc uninstall <bundle>
                │       ├── hdc file send <hap> /tmp/
                │       ├── hdc install /tmp/<hap>
                │       ├── hdc shell aa test -b <bundle> -m <module> -s unittest OHJSUnitTest -w 600
                │       └── parse output -> RESULT_CODE\tmsg
                │
                └── write group_N_results.tsv

                └── merge all group results -> summary.tsv
```

### Remote Execution

Install and test run via `scripts/remote/xts-test-hap.sh.template` — no inline SSH quoting. Template handles two-phase install (file send + install from device), test execution, and result parsing. Caller receives single `RESULT_CODE\tmsg` line.

## Commands

```bash
# Full run on all boards from boards.conf
ohos device xts-run \
    --tsv /path/to/tests.tsv \
    --hap-dir /path/to/haps/ \
    --output-dir /path/to/results/

# Resume interrupted run
ohos device xts-run --tsv tests.tsv --hap-dir ./haps --continue

# Skip board init (already prepared)
ohos device xts-run --tsv tests.tsv --hap-dir ./haps --no-init

# Specific boards
ohos device xts-run \
    --tsv tests.tsv \
    --hap-dir ./haps/ \
    --boards <serial1>,<serial2>,<serial3>
```

## TSV Format

Input TSV must have columns: `hap_file`, `bundle_name`, `module_name`

```
hap_file	bundle_name	module_name
ActsXxx.hap	com.xxx.static	entry
ActsYyy.hap	com.yyy.static	entry
```

Generate from HAP files:
```python
import json, zipfile, os, glob

hap_dirs = ["path/to/haps/", "path/to/acts/"]
with open("tests.tsv", "w") as out:
    out.write("hap_file\tbundle_name\tmodule_name\n")
    for hap_dir in hap_dirs:
        for hap_path in sorted(glob.glob(os.path.join(hap_dir, "**/*.hap"), recursive=True)):
            try:
                with zipfile.ZipFile(hap_path) as zf:
                    with zf.open("module.json") as mf:
                        d = json.load(mf)
                        bundle = d.get("app", {}).get("bundleName", "UNKNOWN")
                        module = d.get("module", {}).get("name", "entry")
                        out.write(f"{os.path.basename(hap_path)}\t{bundle}\t{module}\n")
            except Exception:
                out.write(f"{os.path.basename(hap_path)}\tERROR\tentry\n")
```

**Note:** `hap_file` must be basename only. Directory path goes in `--hap-dir`.

If HAPs are in multiple directories, symlink them to one:
```bash
mkdir -p /tmp/all_haps
ln -s /path/to/haps/**/*.hap /tmp/all_haps/
ln -s /path/to/acts/**/*.hap /tmp/all_haps/
```

## Result Codes

| Code | Meaning |
|---|---|
| `PASS` | All test cases passed (fail=0, error=0) |
| `PARTIAL` | Some passed, some failed |
| `INSTALL_FAIL` | HAP installation failed |
| `CRASH` | Application died during test |
| `TIMEOUT` | Test did not finish in 600s |
| `NOT_INSTALLED` | Bundle not found after install |
| `EXEC_FAIL` | Could not start test |
| `SKIP` | HAP file not found |
| `UNKNOWN` | Could not parse result |

## Log Capture: arkts.console Ring Buffer

Test HAPs output per-testcase diagnostics via `console.info()` / `console.error()`. These flow through the OHOS hilog system as `arkts.console` messages and contain detailed assertion information like `[Hypium][errorDetail]std.core.String cannot be cast to std.core.Boolean`.

### The Problem

xdevice collects hilog by pulling persisted files from `/data/log/hilog/*` on the device *after* the test completes. However, `arkts.console` output lives in the **in-memory ring buffer**. For **short tests** (1 test case, <~1 min), the app process exits before `hilogd` flushes the ring buffer to disk, so xdevice never sees these messages.

Example: AccessibilityLevel (1 case) → 0 arkts.console lines in xdevice hilog. LayoutWeightNowear (25 cases, ~2.5 min) → 759 lines.

### The Fix

The `xts-test-hap.sh.template` runs `hdc shell hilog -r` **after** the test result is parsed for any non-PASS result. `hilog -r` dumps the entire ring buffer and exits (no tail, no conflict with test runner). The output is filtered for `arkts.console` lines and saved to `$LOG_DIR/<hap_name>.hilog`.

- `hilog -r` captures what's still in memory — survives short test exits
- Runs after `aa test` completes — no interference with result capture
- Filtered to `arkts.console` only — avoids megabytes of system noise
- Saved alongside group results — per-HAP, per-board

### Verifying Logs Are Complete

After a run, check that `.hilog` files exist for each non-PASS result:
```bash
ls -la <output-dir>/group_*/*.hilog
# vs
ls -la <output-dir>/group_*/*.tsv | wc -l
```

If a short test still has no `.hilog`, the ring buffer may have been overwritten by subsequent activity (too many boards sharing one hilog buffer). In that case, spread tests across fewer boards per server or increase the hilog buffer size: `hdc shell hilog -b 4096`.

## Output Files

```
<output-dir>/
├── group_0_results.tsv    # board 1 results
├── group_1_results.tsv    # board 2 results
├── ...
├── group_0/               # board 1 per-HAP arkts.console logs
│   ├── ActsXxx.hilog      #   (only for non-PASS results)
│   └── ActsYyy.hilog
├── group_1/               # board 2 per-HAP arkts.console logs
├── group_0.log            # board 1 full log
├── group_1.log            # board 2 full log
├── ...
├── summary.tsv            # merged results from all groups
└── start_time.txt         # run metadata
```

## Timing

- Average HAP test: 60-120s
- 353 tests per board (2117 / 6): ~6-12 hours
- All boards run in parallel

## Troubleshooting

| Problem | Solution |
|---|---|
| INSTALL_FAIL "sign info inconsistent" | Script does uninstall before install automatically |
| INSTALL_FAIL "Not match target" | Board not in HDC mode — check `hdc list targets` |
| Test hangs | `-w 600` timeout enforced; if needed, `aa force-stop <bundle>` |
| hdc not found on server | `LD_LIBRARY_PATH=$OHOS_TOOLS_DIR/toolchains:$LD_LIBRARY_PATH` |
| Out of space on device | Script cleans `/data/local/tmp/*.hap` after each test |
