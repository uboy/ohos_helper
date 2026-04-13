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

## Notes

- The nested tools are pinned by this repository. Update them through normal superproject commits instead of pulling them independently inside the submodule checkout.
- Local build outputs and temporary runtime artifacts are intentionally ignored.
