#!/usr/bin/env python3
import json
import re
import shutil
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "branding.json"


TEXT_FILES = [
    "README.md",
    "Shared/Resources/demo.md",
    "Shared/Resources/getting-started.md",
    "scripts/release.sh",
    "scripts/release-appstore.sh",
    "scripts/release-ios.sh",
    "website/appcast.xml",
    "website/changelog.html",
    "website/cli.html",
    "website/index.html",
    "website/mcp.html",
    "website/privacy.html",
    "website/site.webmanifest",
]


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write_text_if_changed(path: Path, text: str, changed: list[str]) -> None:
    old = read_text(path) if path.exists() else ""
    if text != old:
        path.write_text(text, encoding="utf-8")
        changed.append(str(path.relative_to(ROOT)))


def load_config() -> dict:
    with CONFIG_PATH.open(encoding="utf-8") as handle:
        config = json.load(handle)
    required = ["marketingName", "debugMarketingName", "internalName", "cliName", "appBundleName", "dmgName"]
    missing = [key for key in required if not config.get(key)]
    if missing:
        raise SystemExit(f"branding.json missing required keys: {', '.join(missing)}")
    return config


def current_project_product(project_text: str, target: str, debug: bool = False) -> str | None:
    in_target = False
    in_debug = False
    for line in project_text.splitlines():
        if re.match(r"^  [A-Za-z0-9_-]+:", line):
            in_target = line.strip() == f"{target}:"
            in_debug = False
            continue
        if not in_target:
            continue
        if re.match(r"^        [A-Za-z0-9_-]+:", line):
            in_debug = line.strip() == "Debug:"
            continue
        match = re.match(r"^        PRODUCT_NAME:\s+(.+?)\s*$", line)
        if match and not debug and not in_debug:
            return match.group(1).strip('"')
        match = re.match(r"^          PRODUCT_NAME:\s+(.+?)\s*$", line)
        if match and debug and in_debug:
            return match.group(1).strip('"')
    return None


def apply_project_yml(config: dict, old_names: dict[str, str], changed: list[str]) -> None:
    path = ROOT / "project.yml"
    lines = read_text(path).splitlines()
    output: list[str] = []
    in_target: str | None = None
    in_debug = False

    for line in lines:
        target_match = re.match(r"^  ([A-Za-z0-9_-]+):", line)
        if target_match:
            in_target = target_match.group(1)
            in_debug = False
        elif in_target and re.match(r"^        [A-Za-z0-9_-]+:", line):
            in_debug = line.strip() == "Debug:"

        if in_target in {"Clearly", "Clearly-iOS"}:
            if re.match(r"^        PRODUCT_NAME:", line) and not in_debug:
                line = f"        PRODUCT_NAME: {config['marketingName']}"
            elif re.match(r"^          PRODUCT_NAME:", line) and in_debug:
                line = f"          PRODUCT_NAME: \"{config['debugMarketingName']}\""

        output.append(line)

    write_text_if_changed(path, "\n".join(output) + "\n", changed)
    old_names["projectProduct"] = current_project_product(read_text(path), "Clearly") or config["marketingName"]
    old_names["projectDebugProduct"] = current_project_product(read_text(path), "Clearly", debug=True) or config["debugMarketingName"]


def replace_plist_string_value(text: str, key: str, value: str) -> str:
    pattern = rf"(<key>{re.escape(key)}</key>\s*\n\s*<string>)(.*?)(</string>)"
    return re.sub(pattern, rf"\g<1>{value}\g<3>", text, count=1)


def replace_all_plist_string_values(text: str, key: str, value: str) -> str:
    pattern = rf"(<key>{re.escape(key)}</key>\s*\n\s*<string>)(.*?)(</string>)"
    return re.sub(pattern, rf"\g<1>{value}\g<3>", text)


def apply_plists(config: dict, changed: list[str]) -> None:
    for relative in ["Clearly/Info.plist", "Clearly/iOS/Info-iOS.plist"]:
        path = ROOT / relative
        text = read_text(path)
        text = replace_plist_string_value(text, "CFBundleDisplayName", config["marketingName"])
        text = replace_all_plist_string_values(text, "NSUbiquitousContainerName", config["marketingName"])
        write_text_if_changed(path, text, changed)


def ordered_unique(values: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        if value and value not in seen:
            seen.add(value)
            result.append(value)
    return result


def internal_name_repairs(config: dict, text: str) -> str:
    marketing = config["marketingName"]
    internal = config["internalName"]
    repairs = {
        f"{marketing}Core": f"{internal}Core",
        f"{marketing}CLIIntegrationTests": f"{internal}CLIIntegrationTests",
        f"{marketing}CLI": f"{internal}CLI",
        f"{marketing}QuickLook": f"{internal}QuickLook",
        f"{marketing}MCP": f"{internal}MCP",
        f"{marketing}-iOS": f"{internal}-iOS",
        f"{marketing}.xcodeproj": f"{internal}.xcodeproj",
        f"{marketing}App.swift": f"{internal}App.swift",
        f"struct {marketing}App": f"struct {internal}App",
        f"{marketing}/": f"{internal}/",
        f"{marketing}.entitlements": f"{internal}.entitlements",
        f"{marketing}-AppStore.entitlements": f"{internal}-AppStore.entitlements",
        f"DerivedData/{marketing}-*": f"DerivedData/{internal}-*",
        f"-scheme {marketing} ": f"-scheme {internal} ",
        f"-scheme {marketing}\n": f"-scheme {internal}\n",
        f"scheme {marketing} ": f"scheme {internal} ",
    }
    for old, new in repairs.items():
        text = text.replace(old, new)
    return text


def apply_text_replacements(config: dict, old_product: str, old_debug_product: str, changed: list[str]) -> None:
    internal = config["internalName"]
    previous_names = list(config.get("previousMarketingNames", []))
    if old_product != internal:
        previous_names.append(old_product)
    previous_names = ordered_unique(previous_names)

    replacements: list[tuple[str, str]] = []
    for old_name in previous_names:
        replacements.extend([
            (f"{old_name} Dev.app", f"{config['debugMarketingName']}.app"),
            (f"{old_name}.app", config["appBundleName"]),
            (f"{old_name}.dmg", config["dmgName"]),
            (f"{old_name} Dev", config["debugMarketingName"]),
            (old_name, config["marketingName"]),
        ])

    for relative in TEXT_FILES:
        path = ROOT / relative
        if not path.exists():
            continue
        text = read_text(path)
        for old, new in replacements:
            if old and old != new:
                text = text.replace(old, new)
        text = internal_name_repairs(config, text)
        write_text_if_changed(path, text, changed)


def copy_optional_asset(source: str | None, destination: Path, changed: list[str]) -> None:
    if not source:
        return
    source_path = (ROOT / source).resolve()
    if not source_path.exists():
        raise SystemExit(f"Configured branding asset does not exist: {source}")

    if source_path.is_dir():
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(source_path, destination)
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_path, destination)
    changed.append(str(destination.relative_to(ROOT)))


def apply_icons(config: dict, changed: list[str]) -> None:
    icons = config.get("icons", {})
    copy_optional_asset(icons.get("appIconSource"), ROOT / "Clearly/AppIcon.icon", changed)
    for destination, source in icons.get("websiteIcons", {}).items():
        copy_optional_asset(source, ROOT / destination, changed)


def main() -> int:
    config = load_config()
    project_text = read_text(ROOT / "project.yml")
    old_product = current_project_product(project_text, "Clearly") or config["internalName"]
    old_debug_product = current_project_product(project_text, "Clearly", debug=True) or f"{old_product} Dev"

    changed: list[str] = []
    old_names: dict[str, str] = {}
    apply_project_yml(config, old_names, changed)
    apply_plists(config, changed)
    apply_text_replacements(config, old_product, old_debug_product, changed)
    apply_icons(config, changed)

    if changed:
        print("Applied branding to:")
        for path in sorted(set(changed)):
            print(f"  {path}")
    else:
        print("Branding already up to date.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
