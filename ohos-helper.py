#!/usr/bin/env python3
import argparse
import glob
import json
import os
import re
import sys
from collections import defaultdict

COMPONENT_ROOTS = [
    "foundation",
    "base",
    "drivers",
    "applications",
    "interface",
    "arkcompiler",
]

GN_TARGET_RE = re.compile(
    r'^\s*(?:ohos_\w+|group|action|action_foreach|executable|shared_library|static_library|source_set)'
    r'\("([^"]+)"\)',
    re.MULTILINE,
)


def section_rule(char="=", width=68):
    return char * width


def find_product_configs():
    patterns = ["vendor/*/*/config.json", "productdefine/common/products/*.json"]
    configs = []
    for pattern in patterns:
        configs.extend(glob.glob(pattern))
    return configs


def get_product_info(path):
    try:
        with open(path, "r", encoding="utf-8") as file_obj:
            data = json.load(file_obj)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None

    return {
        "name": data.get("product_name") or "",
        "cpu": data.get("target_cpu") or "",
        "path": path,
        "subsystems": data.get("subsystems", []),
    }


def list_products():
    print(f"\n{'PRODUCT':<30} | {'CPU':<10} | CONFIG PATH")
    print("-" * 100)
    for cfg in sorted(find_product_configs()):
        info = get_product_info(cfg)
        if info:
            print(f"{info['name']:<30} | {info['cpu']:<10} | {cfg}")
    print("\nTip: Use the 'PRODUCT' value for ./build.sh --product-name <value>")


def list_components(product_name):
    for cfg in find_product_configs():
        info = get_product_info(cfg)
        if not info or info["name"] != product_name:
            continue

        print(f"\nComponents for product: {product_name} (found in {cfg})")
        print(f"{'SUBSYSTEM':<25} | COMPONENT")
        print("-" * 60)
        subsystems = sorted(info["subsystems"], key=lambda item: item.get("subsystem") or "")
        for subsystem in subsystems:
            subsystem_name = subsystem.get("subsystem") or ""
            for component in subsystem.get("components", []):
                component_name = component.get("component") or ""
                print(f"{subsystem_name:<25} | {component_name}")
        print("\nTip: Use the 'COMPONENT' value for ./build.sh --build-target <value>")
        return

    print(f"Product '{product_name}' not found.")


def find_bundle_json(component_name):
    for root in COMPONENT_ROOTS:
        pattern = f"{root}/**/{component_name}/bundle.json"
        for match in glob.glob(pattern, recursive=True):
            try:
                with open(match, "r", encoding="utf-8") as file_obj:
                    data = json.load(file_obj)
            except (OSError, UnicodeDecodeError, json.JSONDecodeError):
                continue

            if data.get("component", {}).get("name") == component_name:
                return match, data
    return None, None


def scan_gn_targets(component_dir):
    targets = {}
    pattern = os.path.join(component_dir, "**", "BUILD.gn")
    for gn_path in glob.glob(pattern, recursive=True):
        try:
            with open(gn_path, "r", encoding="utf-8") as file_obj:
                content = file_obj.read()
        except (OSError, UnicodeDecodeError):
            continue

        found = sorted(set(GN_TARGET_RE.findall(content)))
        if not found:
            continue

        rel_dir = os.path.relpath(os.path.dirname(gn_path), component_dir)
        if rel_dir == ".":
            rel_dir = ""
        targets[rel_dir] = found
    return targets


def filter_gn_targets(targets, path_filter=None, target_filter=None):
    filtered = {}
    path_filter = path_filter.lower() if path_filter else None
    target_filter = target_filter.lower() if target_filter else None

    for rel_dir, names in sorted(targets.items()):
        dir_label = rel_dir or "(root)"
        if path_filter and path_filter not in dir_label.lower():
            continue

        matched = names
        if target_filter:
            matched = [name for name in names if target_filter in name.lower()]

        if matched:
            filtered[rel_dir] = matched

    return filtered


def summarize_top_groups(targets):
    summary = defaultdict(lambda: {"directories": 0, "targets": 0})
    for rel_dir, names in targets.items():
        if not rel_dir:
            group_name = "(root)"
        else:
            group_name = rel_dir.split(os.sep, 1)[0]
        summary[group_name]["directories"] += 1
        summary[group_name]["targets"] += len(names)
    return summary


def total_targets(targets):
    return sum(len(names) for names in targets.values())


def print_list_section(title, items, prefix="  - "):
    print(f"\n{title}:")
    for item in items:
        print(f"{prefix}{item}")


def print_build_targets(build):
    has_targets = False

    groups = build.get("group_type", {})
    if groups:
        has_targets = True
        print("\nBuild Targets (group_type):")
        for group_name in sorted(groups):
            targets = groups[group_name]
            if not targets:
                continue
            print(f"  [{group_name}]")
            for target in targets:
                print(f"    {target}")

    sub_components = build.get("sub_component", [])
    if sub_components:
        has_targets = True
        print("\nBuild Targets (sub_component):")
        for target in sub_components:
            print(f"    {target}")

    inner_kits = build.get("inner_kits", [])
    if inner_kits:
        has_targets = True
        print("\nInner Kits (shared APIs):")
        for kit in inner_kits:
            name = kit.get("name", "")
            if not name:
                continue
            header = kit.get("header", {}) or {}
            header_base = header.get("header_base", "")
            suffix = f"  (headers: {header_base})" if header_base else ""
            print(f"    {name}{suffix}")

    tests = build.get("test", [])
    if tests:
        has_targets = True
        print("\nTest Targets:")
        for target in tests:
            print(f"    {target}")

    if not has_targets:
        print("\nNo build targets found in bundle.json.")


def print_deep_scan(component_dir, path_filter=None, target_filter=None):
    print(f"\n{section_rule()}")
    print(f"BUILD.gn Targets (deep scan from {component_dir})")

    scanned_targets = scan_gn_targets(component_dir)
    if not scanned_targets:
        print("No BUILD.gn targets found.")
        return

    filtered_targets = filter_gn_targets(
        scanned_targets,
        path_filter=path_filter,
        target_filter=target_filter,
    )

    scanned_total = total_targets(scanned_targets)
    filtered_total = total_targets(filtered_targets)

    print("\nScan Summary:")
    print(f"  Directories scanned : {len(scanned_targets)}")
    print(f"  Targets scanned     : {scanned_total}")
    if path_filter or target_filter:
        print(f"  Matched directories : {len(filtered_targets)}")
        print(f"  Matched targets     : {filtered_total}")
        if path_filter:
            print(f"  Path filter         : {path_filter}")
        if target_filter:
            print(f"  Target filter       : {target_filter}")

    if not filtered_targets:
        print("\nNo BUILD.gn targets matched the active filters.")
        return

    top_groups = summarize_top_groups(filtered_targets)
    print("\nTop-Level Groups:")
    for group_name in sorted(top_groups):
        group_info = top_groups[group_name]
        print(
            f"  - {group_name:<24} "
            f"{group_info['targets']:>4} targets in {group_info['directories']:>3} directories"
        )

    print("\nTargets By Directory:")
    for rel_dir in sorted(filtered_targets):
        names = filtered_targets[rel_dir]
        dir_label = rel_dir or "(root)"
        print(f"\n  [{dir_label}] ({len(names)} targets)")
        for name in names:
            print(f"    :{name}")


def show_component_info(component_name, deep=False, path_filter=None, target_filter=None):
    path, data = find_bundle_json(component_name)
    if not data:
        print(f"Error: Component '{component_name}' metadata (bundle.json) not found.")
        return 1

    component = data.get("component", {})
    component_dir = os.path.dirname(path)

    print(f"\n{section_rule()}")
    print(f"Component:  {component_name}")
    print(f"Path:       {path}")
    print(f"Subsystem:  {component.get('subsystem')}")
    print(section_rule())

    features = sorted(component.get("features", []))
    if features:
        print(f"\nAvailable Features (GN Args) [{len(features)}]:")
        for feature in features:
            print(f"  - {feature}")
        print("\nTip: Use features as --gn-args <feature>=true")
    else:
        print("\nNo specific features defined.")

    print_build_targets(component.get("build", {}))

    if deep:
        print_deep_scan(
            component_dir,
            path_filter=path_filter,
            target_filter=target_filter,
        )

    print(f"\n{section_rule()}")
    print("Examples for this component:")
    print(f"  Build component:  ./build.sh --product-name rk3568 --build-target {component_name}")
    if features:
        print(f"  With feature:     ./build.sh --product-name rk3568 --gn-args {features[0]}=true")
    if not deep:
        print(f"  Deep scan:        ohos info {component_name} --deep")
        print(f"  Filtered scan:    ohos info {component_name} --deep --path-filter arkts_frontend")
    return 0


def show_common_params():
    params = [
        ("--product-name", "Target product (from 'products' command)"),
        ("--target-cpu", "Architecture: arm, arm64, x86_64"),
        ("--build-target", "Component name or GN path"),
        ("--gn-args", "Custom arguments: 'is_debug=true'"),
        ("--ccache", "Enable or disable ccache (True/False)"),
        ("--fast-rebuild", "Skip slow GN generation (True/False)"),
        ("--build-type", "release, debug, profile"),
    ]
    print("\nCommon Parameters Reference:")
    print("-" * 80)
    for key, value in params:
        print(f"  {key:<20} : {value}")


def build_parser():
    parser = argparse.ArgumentParser(
        description="OpenHarmony Build Helper - find products, parts, and build targets",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
General workflow:
  1. Find your product:       python3 ohos-helper.py products
  2. See what parts it has:   python3 ohos-helper.py parts rk3568
  3. Inspect one component:   python3 ohos-helper.py info ace_engine
  4. Deep-scan BUILD.gn:      python3 ohos-helper.py info ace_engine --deep
  5. Filter deep results:     python3 ohos-helper.py info ace_engine --deep --path-filter arkts_frontend --target-filter native
  6. Run build:               ./build.sh --product-name rk3568 --build-target ace_engine
""",
    )

    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    subparsers.add_parser(
        "products",
        help="List all available products",
        description="List all products defined in vendor/ and productdefine/.",
        epilog="Example: Use 'rk3568' from the PRODUCT column for --product-name.",
    )

    parts_parser = subparsers.add_parser(
        "parts",
        help="List components in a product",
        description="List all subsystems and components included in a specific product configuration.",
        epilog="Example: python3 ohos-helper.py parts rk3568",
    )
    parts_parser.add_argument("product", help="Product name (for example: rk3568)")

    info_parser = subparsers.add_parser(
        "info",
        help="Show component details and optional deep target scan",
        description="Find bundle.json for a component and extract GN args, build targets, and optional BUILD.gn targets.",
        epilog="""
Examples:
  python3 ohos-helper.py info ace_engine
  python3 ohos-helper.py info ace_engine --deep
  python3 ohos-helper.py info ace_engine --deep --path-filter arkts_frontend
  python3 ohos-helper.py info ace_engine --deep --target-filter native
""",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    info_parser.add_argument("component", help="Component name (for example: ace_engine)")
    info_parser.add_argument(
        "--deep",
        action="store_true",
        help="Scan BUILD.gn files for target definitions and print grouped output",
    )
    info_parser.add_argument(
        "--path-filter",
        help="Keep only deep-scan directories whose path contains this text",
    )
    info_parser.add_argument(
        "--target-filter",
        help="Keep only deep-scan targets whose name contains this text",
    )

    subparsers.add_parser(
        "params",
        help="Quick reference for build.sh flags",
        description="Show the most frequently used flags for the main build script.",
    )

    return parser


def main():
    parser = build_parser()
    if len(sys.argv) == 1:
        parser.print_help()
        return 1

    args = parser.parse_args()

    if args.command == "products":
        list_products()
        return 0

    if args.command == "parts":
        list_components(args.product)
        return 0

    if args.command == "info":
        if (args.path_filter or args.target_filter) and not args.deep:
            parser.error("--path-filter and --target-filter require --deep")
        return show_component_info(
            args.component,
            deep=args.deep,
            path_filter=args.path_filter,
            target_filter=args.target_filter,
        )

    if args.command == "params":
        show_common_params()
        return 0

    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
