#!/usr/bin/env python3
"""
Detect and explain package conflicts before install.

This helper is intentionally small and dependency-free so it can run from the
cx-core package before the Python cx CLI is installed from PyPI.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


APT_RELATION_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9+.-]+")


@dataclass(frozen=True)
class Conflict:
    """One conflict found between requested packages."""

    packages: tuple[str, ...]
    reason: str
    options: tuple[str, ...]
    source: str

    @property
    def key(self) -> str:
        """Stable key used for saved choices and duplicate removal."""
        return "|".join(sorted(self.packages))


def parse_relation_names(value: str) -> set[str]:
    """Extract package names from an apt relationship field."""
    names: set[str] = set()
    for part in value.split(","):
        names.update(APT_RELATION_RE.findall(part.strip()))
    return names


def read_apt_fields(package: str) -> dict[str, list[str]]:
    """Read fields from apt-cache show for one package."""
    try:
        result = subprocess.run(
            ["apt-cache", "show", package],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return {}

    fields: dict[str, list[str]] = {}
    current_key = ""
    for line in result.stdout.splitlines():
        if not line:
            current_key = ""
            continue
        if line[0].isspace() and current_key:
            fields[current_key][-1] += " " + line.strip()
            continue
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        current_key = key.strip()
        fields.setdefault(current_key, []).append(value.strip())
    return fields


def detect_apt_conflicts(packages: list[str]) -> list[Conflict]:
    """Find conflicts reported by apt metadata for the requested packages."""
    requested = set(packages)
    conflicts: dict[str, Conflict] = {}

    for package in packages:
        fields = read_apt_fields(package)
        related: set[str] = set()
        for field in ("Conflicts", "Breaks"):
            for value in fields.get(field, []):
                related.update(parse_relation_names(value))

        overlap = sorted((related & requested) - {package})
        for other in overlap:
            package_pair = tuple(sorted((package, other)))
            conflict = Conflict(
                packages=package_pair,
                reason=f"{package} cannot be installed together with {other}",
                options=package_pair,
                source="apt-cache",
            )
            conflicts[conflict.key] = conflict

    return list(conflicts.values())


def load_rule_conflicts(path: Path, packages: list[str]) -> list[Conflict]:
    """Load extra conflict rules from JSON when the file is available."""
    if not path.exists():
        return []

    try:
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"Warning: could not read rules file {path}: {exc}", file=sys.stderr)
        return []

    requested = set(packages)
    found: list[Conflict] = []
    for item in data.get("conflicts", []):
        item_packages = tuple(str(pkg) for pkg in item.get("packages", []))
        if len(item_packages) < 2:
            continue
        if set(item_packages).issubset(requested):
            options = tuple(str(option) for option in item.get("options", item_packages))
            found.append(
                Conflict(
                    packages=tuple(sorted(item_packages)),
                    reason=str(item.get("reason", "Packages cannot be installed together")),
                    options=options,
                    source=str(path),
                )
            )
    return found


def load_preferences(path: Path) -> dict[str, str]:
    """Load saved conflict choices from disk."""
    if not path.exists():
        return {}
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {str(key): str(value) for key, value in data.items()}


def save_preference(path: Path, key: str, choice: str) -> None:
    """Persist one saved choice while keeping existing choices."""
    data = load_preferences(path)
    data[key] = choice
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write("\n")


def conflict_to_dict(conflict: Conflict, saved_choice: str | None) -> dict[str, object]:
    """Convert a conflict to the JSON output shape."""
    return {
        "packages": list(conflict.packages),
        "reason": conflict.reason,
        "options": list(conflict.options),
        "source": conflict.source,
        "saved_choice": saved_choice,
    }


def print_human(conflicts: Iterable[Conflict], preferences: dict[str, str]) -> None:
    """Print the normal terminal output."""
    conflict_list = list(conflicts)
    if not conflict_list:
        print("No package conflicts found.")
        return

    print("Package conflicts found:")
    for index, conflict in enumerate(conflict_list, start=1):
        print(f"\n{index}. {' vs '.join(conflict.packages)}")
        print(f"   Reason: {conflict.reason}")
        saved_choice = preferences.get(conflict.key)
        if saved_choice:
            print(f"   Saved preference: keep {saved_choice}")
        print("   Options:")
        for option_index, option in enumerate(conflict.options, start=1):
            print(f"     {option_index}) keep {option}")


def prompt_for_choices(conflicts: Iterable[Conflict], preferences_path: Path) -> dict[str, str]:
    """Ask the user which package to keep for each conflict."""
    saved: dict[str, str] = {}
    for conflict in conflicts:
        print(f"\nConflict: {' vs '.join(conflict.packages)}")
        print(f"Reason: {conflict.reason}")
        for option_index, option in enumerate(conflict.options, start=1):
            print(f"  {option_index}) keep {option}")
        print("  s) skip for now")

        while True:
            try:
                answer = input(f"Select option [1-{len(conflict.options)} or s]: ").strip()
            except EOFError:
                print("\nNo selection made.", file=sys.stderr)
                break

            if answer.lower() == "s":
                break
            if answer.isdigit():
                selected_index = int(answer) - 1
                if 0 <= selected_index < len(conflict.options):
                    choice = conflict.options[selected_index]
                    save_preference(preferences_path, conflict.key, choice)
                    saved[conflict.key] = choice
                    print(f"Saved preference: keep {choice}")
                    break
            print("Please enter a listed option.")
    return saved


def default_preferences_path() -> Path:
    """Return the default path for saved conflict preferences."""
    return Path(
        os.environ.get(
            "CX_CONFLICT_PREFERENCES",
            Path.home() / ".config" / "cx" / "conflict-preferences.json",
        )
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(
        description="Detect package conflicts and save a preferred resolution."
    )
    parser.add_argument("packages", nargs="+", help="Packages planned for install")
    parser.add_argument(
        "--rules",
        default="/etc/cx/package-conflicts.json",
        help="Optional JSON conflict rules file",
    )
    parser.add_argument(
        "--preferences",
        default=str(default_preferences_path()),
        help="Saved preference file",
    )
    parser.add_argument("--choice", help="Save this package as the preferred option")
    parser.add_argument(
        "--interactive",
        action="store_true",
        help="Prompt for a preferred option for each conflict",
    )
    parser.add_argument("--json", action="store_true", help="Print JSON output")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    """Run the conflict resolver command."""
    args = parse_args(argv)
    preferences_path = Path(args.preferences).expanduser()
    preferences = load_preferences(preferences_path)

    conflicts = detect_apt_conflicts(args.packages)
    conflicts.extend(load_rule_conflicts(Path(args.rules).expanduser(), args.packages))
    conflicts = sorted(
        {conflict.key: conflict for conflict in conflicts}.values(),
        key=lambda item: item.key,
    )

    if args.choice:
        matching = [conflict for conflict in conflicts if args.choice in conflict.options]
        if not matching:
            print(f"Choice '{args.choice}' does not match any conflict option.", file=sys.stderr)
            return 2
        for conflict in matching:
            save_preference(preferences_path, conflict.key, args.choice)
            preferences[conflict.key] = args.choice

    if args.interactive and conflicts:
        preferences.update(prompt_for_choices(conflicts, preferences_path))

    if args.json:
        payload = {
            "ok": not conflicts,
            "conflicts": [
                conflict_to_dict(conflict, preferences.get(conflict.key))
                for conflict in conflicts
            ],
        }
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print_human(conflicts, preferences)

    return 1 if conflicts else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
