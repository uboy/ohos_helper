# Test 2: NK Build (static XTS + firmware + SDK)

## Prerequisites

- `ohos` helper available (sourced from `ohos.sh`)
- Repo: `~/ohos_master`

## Step-by-Step

### 1. Verify the 3 PRs are available locally (already fetched)

```bash
# PR 6696 (developtools/ace_ets2bundle)
cd ~/ohos_master/developtools/ace_ets2bundle
git fetch https://gitcode.com/openharmony/developtools_ace_ets2bundle.git \
  +refs/merge-requests/6696/head:pr_6696

# PR 10666 (arkcompiler/ets_frontend)
cd ~/ohos_master/arkcompiler/ets_frontend
git fetch https://gitcode.com/openharmony/arkcompiler_ets_frontend.git \
  +refs/merge-requests/10666/head:pr_10666

# PR 32684 (interface/sdk-js)
cd ~/ohos_master/interface/sdk-js
git fetch https://gitcode.com/openharmony/interface_sdk-js.git \
  +refs/merge-requests/32684/head:pr_32684
```

### 2. Verify the PRs are already in NK manifest

```bash
# All 3 PRs should show "ALREADY MERGED" because NK manifest
# tracks kopnovanatalia's fork which includes these fixes.
cd ~/ohos_master/developtools/ace_ets2bundle
git merge-base --is-ancestor pr_6696 HEAD && echo "PR 6696: ✓"

cd ~/ohos_master/arkcompiler/ets_frontend
git merge-base --is-ancestor pr_10666 HEAD && echo "PR 10666: ✓"

cd ~/ohos_master/interface/sdk-js
git merge-base --is-ancestor pr_32684 HEAD && echo "PR 32684: ✓"
```

### 3. Reset the repo (clean rebuild)

```bash
cd ~/ohos_master
ohos reset --yes
```

This will:
- Hard-reset all sub-repos (`git clean -fxd` + `git reset --hard HEAD`)
- Delete `out/` and `prebuilts/`
- Re-sync everything from manifest
- Run `git lfs fetch + checkout`
- Run `build/prebuilts_download.sh`

### 4. Build firmware (rk3568)

```bash
cd ~/ohos_master
ohos build rk3568
```

Equivalent to: `./build.sh --product-name rk3568 --ccache`

### 5. Build SDK (ohos-sdk)

```bash
cd ~/ohos_master
ohos build sdk
```

Equivalent to: `./build.sh --product-name ohos-sdk --ccache`

### 6. Build static XTS

```bash
cd ~/ohos_master
ohos build xts-static
```

Equivalent to: `XTS_SUITETYPE=hap_static ./build.sh --product-name rk3568 --ccache`

## Notes

- The NK manifest uses `kopno` remote (kopnovanatalia's fork on GitCode) for 3 repos:
  - `developtools/ace_ets2bundle` → pinned at `9a0bdeaad`
  - `arkcompiler/ets_frontend` → pinned at `2fdcffd4e`
  - `interface/sdk-js` → pinned at `4acd75d5d`
- All 3 PRs (6696, 10666, 32684) are included in these pinned commits
- After `ohos reset`, the code is restored to these pinned SHAs (PRs are preserved)
- Builds are sequential; firmware + SDK + XTS can be run in any order with `ohos build <alias>`
