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

TARGET_DEF_RE = re.compile(
    r'^\s*(?P<type>[A-Za-z_][A-Za-z0-9_]*)\("(?P<name>[^"]+)"\)\s*\{'
)
QUOTED_STRING_RE = re.compile(r'"((?:\\.|[^"\\])*)"')
DOUBLE_QUOTED_SEGMENT_RE = re.compile(r'"(?:\\.|[^"\\])*"')
TESTONLY_RE = re.compile(r"^\s*testonly\s*=\s*true\b", re.MULTILINE)
SCRIPT_RE = re.compile(r'^\s*script\s*=\s*"([^"]+)"', re.MULTILINE)
OUTPUT_NAME_RE = re.compile(r'^\s*output_name\s*=\s*"([^"]+)"', re.MULTILINE)
EXCLUDED_TARGET_TYPES = {"template", "config", "declare_args"}


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


def strip_quoted_strings(line):
    return DOUBLE_QUOTED_SEGMENT_RE.sub('""', line)


def find_target_block_end(lines, start_index):
    depth = 0
    seen_open_brace = False

    for index in range(start_index, len(lines)):
        code_part = lines[index].split("#", 1)[0]
        sanitized = strip_quoted_strings(code_part)
        if "{" in sanitized:
            seen_open_brace = True
        depth += sanitized.count("{")
        depth -= sanitized.count("}")
        if seen_open_brace and depth <= 0:
            return index

    return start_index


def extract_leading_comment(lines, start_index):
    comments = []
    index = start_index - 1
    while index >= 0:
        stripped = lines[index].strip()
        if not stripped:
            if comments:
                break
            return ""
        if stripped.startswith("#"):
            text = stripped[1:].strip()
            if text:
                comments.insert(0, text)
            index -= 1
            continue
        break
    return " ".join(comments)


def extract_first_match(pattern, text):
    match = pattern.search(text)
    return match.group(1) if match else ""


def extract_list_values(block_text, variable_names):
    names = "|".join(re.escape(name) for name in variable_names)
    pattern = re.compile(
        rf"^\s*(?:{names})\s*(?:\+?=)\s*\[(.*?)\]",
        re.MULTILINE | re.DOTALL,
    )
    values = []
    for match in pattern.finditer(block_text):
        values.extend(QUOTED_STRING_RE.findall(match.group(1)))
    return values


def build_target_summary(entry):
    if entry["comment"]:
        summary = entry["comment"]
    else:
        location = entry["rel_dir"] or "(root)"
        summary = f"{entry['type']} target in {location}"

    details = []
    if entry["testonly"]:
        details.append("testonly")
    if entry["script"]:
        details.append(f"script={entry['script']}")
    if entry["output_name"]:
        details.append(f"output={entry['output_name']}")
    if entry["dep_count"]:
        details.append(f"deps={entry['dep_count']}")
    if entry["sources_count"]:
        details.append(f"sources={entry['sources_count']}")

    if details:
        summary += f" ({', '.join(details)})"
    return summary


def scan_gn_targets(component_dir):
    entries = []
    pattern = os.path.join(component_dir, "**", "BUILD.gn")
    for gn_path in glob.glob(pattern, recursive=True):
        try:
            with open(gn_path, "r", encoding="utf-8") as file_obj:
                lines = file_obj.read().splitlines()
        except (OSError, UnicodeDecodeError):
            continue

        rel_dir = os.path.relpath(os.path.dirname(gn_path), component_dir)
        if rel_dir == ".":
            rel_dir = ""

        index = 0
        while index < len(lines):
            match = TARGET_DEF_RE.match(lines[index])
            if not match:
                index += 1
                continue

            target_type = match.group("type")
            if target_type in EXCLUDED_TARGET_TYPES:
                index += 1
                continue

            end_index = find_target_block_end(lines, index)
            block_lines = lines[index : end_index + 1]
            block_text = "\n".join(block_lines)
            deps = extract_list_values(
                block_text,
                ["deps", "public_deps", "external_deps", "data_deps"],
            )
            sources = extract_list_values(block_text, ["sources"])

            entry = {
                "name": match.group("name"),
                "type": target_type,
                "rel_dir": rel_dir,
                "dir_parts": [] if not rel_dir else rel_dir.split(os.sep),
                "build_file": gn_path,
                "build_file_rel": os.path.relpath(gn_path, component_dir),
                "line": index + 1,
                "comment": extract_leading_comment(lines, index),
                "testonly": bool(TESTONLY_RE.search(block_text)),
                "script": extract_first_match(SCRIPT_RE, block_text),
                "output_name": extract_first_match(OUTPUT_NAME_RE, block_text),
                "deps": deps,
                "dep_count": len(deps),
                "sources_count": len(sources),
            }
            entry["summary"] = build_target_summary(entry)
            entries.append(entry)
            index = end_index + 1

    entries.sort(key=lambda item: (item["rel_dir"], item["name"]))
    return entries


def filter_target_entries(entries, path_filter=None, target_filter=None, target_type=None):
    path_filter = path_filter.lower() if path_filter else None
    target_filter = target_filter.lower() if target_filter else None
    target_type = target_type.lower() if target_type else None

    filtered = []
    for entry in entries:
        dir_label = entry["rel_dir"] or "(root)"
        if path_filter and path_filter not in dir_label.lower():
            continue
        if target_filter and target_filter not in entry["name"].lower():
            continue
        if target_type and target_type != entry["type"].lower():
            continue
        filtered.append(entry)
    return filtered


def summarize_top_groups(entries):
    summary = defaultdict(lambda: {"directories": set(), "targets": 0})
    for entry in entries:
        group_name = entry["dir_parts"][0] if entry["dir_parts"] else "(root)"
        summary[group_name]["directories"].add(entry["rel_dir"])
        summary[group_name]["targets"] += 1
    return summary


def summarize_target_types(entries):
    summary = defaultdict(int)
    for entry in entries:
        summary[entry["type"]] += 1
    return summary


def summarize_directory_depths(entries):
    summary = defaultdict(lambda: {"directories": set(), "targets": 0})
    for entry in entries:
        depth = len(entry["dir_parts"])
        summary[depth]["directories"].add(entry["rel_dir"])
        summary[depth]["targets"] += 1
    return summary


def group_entries_by_directory(entries):
    grouped = defaultdict(list)
    for entry in entries:
        grouped[entry["rel_dir"]].append(entry)
    return grouped


def format_preview_list(values, limit=4):
    preview = values[:limit]
    text = ", ".join(preview)
    if len(values) > limit:
        text += f", ... (+{len(values) - limit})"
    return text


def target_label(entry, include_path=False, include_type=False):
    if include_path:
        path_prefix = entry["rel_dir"] or "(root)"
        label = f"{path_prefix}:{entry['name']}"
    else:
        label = f":{entry['name']}"

    if include_type:
        label += f" [{entry['type']}]"
    return label


def describe_target_lines(entry):
    lines = [
        f"summary: {entry['summary']}",
        f"file: {entry['build_file_rel']}:{entry['line']}",
    ]

    meta = []
    if entry["testonly"]:
        meta.append("testonly=true")
    if entry["output_name"]:
        meta.append(f"output_name={entry['output_name']}")
    if entry["script"]:
        meta.append(f"script={entry['script']}")
    if entry["dep_count"]:
        meta.append(f"deps={entry['dep_count']}")
    if entry["sources_count"]:
        meta.append(f"sources={entry['sources_count']}")
    if meta:
        lines.append(f"meta: {', '.join(meta)}")

    if entry["deps"]:
        lines.append(f"deps: {format_preview_list(entry['deps'])}")
    return lines


def print_target_entry(entry, indent="  ", describe=False, include_path=False):
    print(f"{indent}{target_label(entry, include_path=include_path, include_type=describe)}")
    if describe:
        for line in describe_target_lines(entry):
            print(f"{indent}  {line}")


def print_grouped_entries(entries, describe=False):
    print("\nTargets By Directory (grouped view):")
    grouped = group_entries_by_directory(entries)
    for rel_dir in sorted(grouped):
        dir_label = rel_dir or "(root)"
        targets = grouped[rel_dir]
        print(f"\n  [{dir_label}] ({len(targets)} targets)")
        for entry in targets:
            print_target_entry(entry, indent="    ", describe=describe)


def print_flat_entries(entries, describe=False):
    print("\nTargets (flat view):")
    for entry in entries:
        print_target_entry(entry, indent="  ", describe=describe, include_path=True)


def make_tree_node(name, path):
    return {
        "name": name,
        "path": path,
        "children": {},
        "entries": [],
        "target_count": 0,
        "dir_count": 0,
    }


def build_directory_tree(entries):
    root = make_tree_node(".", "")
    for entry in entries:
        node = root
        node["target_count"] += 1
        current_path = []
        for part in entry["dir_parts"]:
            current_path.append(part)
            if part not in node["children"]:
                node["children"][part] = make_tree_node(part, os.sep.join(current_path))
            node = node["children"][part]
            node["target_count"] += 1
        node["entries"].append(entry)
    compute_tree_dir_counts(root)
    return root


def compute_tree_dir_counts(node):
    dir_count = len(node["children"])
    for child in node["children"].values():
        dir_count += compute_tree_dir_counts(child)
    node["dir_count"] = dir_count
    return dir_count


def format_tree_directory_label(node):
    suffix = f"{node['target_count']} targets"
    if node["dir_count"]:
        suffix += f", {node['dir_count']} subdirs"
    return f"{node['name']}/ ({suffix})"


def print_tree_children(node, prefix="", depth=0, max_depth=None, describe=False):
    items = []
    for child_name in sorted(node["children"]):
        items.append(("dir", node["children"][child_name]))
    for entry in sorted(node["entries"], key=lambda item: item["name"]):
        items.append(("target", entry))

    for index, item in enumerate(items):
        is_last = index == len(items) - 1
        connector = "`- " if is_last else "|- "
        next_prefix = prefix + ("   " if is_last else "|  ")
        item_type, payload = item

        if item_type == "dir":
            label = format_tree_directory_label(payload)
            if max_depth is not None and depth + 1 >= max_depth:
                print(f"{prefix}{connector}{label} [collapsed]")
                continue
            print(f"{prefix}{connector}{label}")
            print_tree_children(
                payload,
                prefix=next_prefix,
                depth=depth + 1,
                max_depth=max_depth,
                describe=describe,
            )
            continue

        label = target_label(payload, include_type=describe)
        print(f"{prefix}{connector}{label}")
        if describe:
            for line in describe_target_lines(payload):
                print(f"{next_prefix}{line}")


def print_tree(entries, max_depth=None, describe=False):
    root = build_directory_tree(entries)
    print("\nDirectory Tree (tree view):")
    root_suffix = f"{root['target_count']} targets"
    if root["dir_count"]:
        root_suffix += f", {root['dir_count']} subdirs"
    print(f"  . ({root_suffix})")
    print_tree_children(root, prefix="  ", depth=0, max_depth=max_depth, describe=describe)


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


def print_deep_scan(
    component_dir,
    path_filter=None,
    target_filter=None,
    target_type=None,
    view="grouped",
    max_depth=None,
    describe=False,
):
    print(f"\n{section_rule()}")
    print(f"BUILD.gn Targets (deep scan from {component_dir})")

    scanned_entries = scan_gn_targets(component_dir)
    if not scanned_entries:
        print("No BUILD.gn targets found.")
        return

    filtered_entries = filter_target_entries(
        scanned_entries,
        path_filter=path_filter,
        target_filter=target_filter,
        target_type=target_type,
    )

    scanned_dirs = {entry["rel_dir"] for entry in scanned_entries}
    filtered_dirs = {entry["rel_dir"] for entry in filtered_entries}

    print("\nScan Summary:")
    print(f"  Directories scanned : {len(scanned_dirs)}")
    print(f"  Targets scanned     : {len(scanned_entries)}")
    print(f"  Active view         : {view}")
    if describe:
        print("  Describe mode       : enabled")
    if path_filter or target_filter or target_type:
        print(f"  Matched directories : {len(filtered_dirs)}")
        print(f"  Matched targets     : {len(filtered_entries)}")
        if path_filter:
            print(f"  Path filter         : {path_filter}")
        if target_filter:
            print(f"  Target filter       : {target_filter}")
        if target_type:
            print(f"  Target type filter  : {target_type}")
    if max_depth is not None and view == "tree":
        print(f"  Tree max depth      : {max_depth}")

    if not filtered_entries:
        print("\nNo BUILD.gn targets matched the active filters.")
        return

    type_summary = summarize_target_types(filtered_entries)
    print("\nTarget Types:")
    for type_name in sorted(type_summary):
        print(f"  - {type_name:<24} {type_summary[type_name]:>4} targets")

    top_groups = summarize_top_groups(filtered_entries)
    print("\nTop-Level Groups:")
    for group_name in sorted(top_groups):
        group_info = top_groups[group_name]
        print(
            f"  - {group_name:<24} "
            f"{group_info['targets']:>4} targets in {len(group_info['directories']):>3} directories"
        )

    depth_summary = summarize_directory_depths(filtered_entries)
    print("\nDirectory Depths:")
    for depth in sorted(depth_summary):
        depth_info = depth_summary[depth]
        print(
            f"  - depth {depth:<2} "
            f"{depth_info['targets']:>4} targets in {len(depth_info['directories']):>3} directories"
        )

    if view == "grouped":
        print_grouped_entries(filtered_entries, describe=describe)
    elif view == "tree":
        print_tree(filtered_entries, max_depth=max_depth, describe=describe)
    elif view == "flat":
        print_flat_entries(filtered_entries, describe=describe)


def show_component_info(
    component_name,
    deep=False,
    path_filter=None,
    target_filter=None,
    target_type=None,
    view="grouped",
    max_depth=None,
    describe=False,
):
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
            target_type=target_type,
            view=view,
            max_depth=max_depth,
            describe=describe,
        )

    print(f"\n{section_rule()}")
    print("Examples for this component:")
    print(f"  Build component:  ./build.sh --product-name rk3568 --build-target {component_name}")
    if features:
        print(f"  With feature:     ./build.sh --product-name rk3568 --gn-args {features[0]}=true")
    if not deep:
        print(f"  Deep scan:        ohos info {component_name} --deep")
        print(f"  Tree view:        ohos info {component_name} --deep --view tree --max-depth 2")
        print(f"  Describe target:  ohos info {component_name} --deep --target-filter linux_unittest --describe")
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
  6. Browse as tree:          python3 ohos-helper.py info ace_engine --deep --view tree --max-depth 2 | less -R
  7. Describe one target:     python3 ohos-helper.py info ace_engine --deep --target-filter linux_unittest --describe
  8. Run build:               ./build.sh --product-name rk3568 --build-target ace_engine
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
  python3 ohos-helper.py info ace_engine --deep --view tree --max-depth 2
  python3 ohos-helper.py info ace_engine --deep --target-type group --target-filter linux
  python3 ohos-helper.py info ace_engine --deep --path-filter test/unittest --describe
  python3 ohos-helper.py info ace_engine --deep --view tree --max-depth 3 | less -R
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
    info_parser.add_argument(
        "--target-type",
        help="Keep only deep-scan targets of this type (for example: group, action, ohos_shared_library)",
    )
    info_parser.add_argument(
        "--view",
        choices=["grouped", "tree", "flat"],
        default="grouped",
        help="How to render deep-scan results",
    )
    info_parser.add_argument(
        "--max-depth",
        type=int,
        help="Limit tree expansion depth when --view tree is used",
    )
    info_parser.add_argument(
        "--describe",
        action="store_true",
        help="Show file, line, type, deps, and heuristic target meaning in deep output",
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
        deep_only_args_used = any(
            [
                args.path_filter,
                args.target_filter,
                args.target_type,
                args.view != "grouped",
                args.max_depth is not None,
                args.describe,
            ]
        )
        if deep_only_args_used and not args.deep:
            parser.error(
                "--path-filter, --target-filter, --target-type, --view, --max-depth, and --describe require --deep"
            )
        if args.max_depth is not None and args.max_depth < 1:
            parser.error("--max-depth must be >= 1")
        return show_component_info(
            args.component,
            deep=args.deep,
            path_filter=args.path_filter,
            target_filter=args.target_filter,
            target_type=args.target_type,
            view=args.view,
            max_depth=args.max_depth,
            describe=args.describe,
        )

    if args.command == "params":
        show_common_params()
        return 0

    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
