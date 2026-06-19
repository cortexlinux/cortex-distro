#!/usr/bin/env python3
"""CX package installation profile manager.

The tool intentionally uses only the Python standard library so it can run on
fresh CX Linux systems before optional Python packages are installed.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from copy import deepcopy
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


PROFILE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
PACKAGE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+_.:-]{0,127}$")
STATE_VERSION = 1


class ProfileError(RuntimeError):
    """User-facing profile command error."""


@dataclass(frozen=True)
class Diff:
    added: list[str]
    removed: list[str]
    unchanged: list[str]


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def default_state_path() -> Path:
    if os.environ.get("CX_PROFILE_STATE"):
        return Path(os.environ["CX_PROFILE_STATE"]).expanduser()
    if os.environ.get("CX_PROFILE_DIR"):
        return Path(os.environ["CX_PROFILE_DIR"]).expanduser() / "profiles.json"
    return Path.home() / ".config" / "cx" / "profiles.json"


def empty_state() -> dict[str, Any]:
    return {"version": STATE_VERSION, "active": None, "profiles": {}}


def normalize_packages(packages: list[str] | None) -> list[str]:
    seen: set[str] = set()
    normalized: list[str] = []
    for raw in packages or []:
        package = raw.strip()
        if not package:
            continue
        if not PACKAGE_NAME_RE.match(package):
            raise ProfileError(f"Invalid package name: {raw!r}")
        if package not in seen:
            normalized.append(package)
            seen.add(package)
    return sorted(normalized)


def validate_profile_name(name: str) -> None:
    if not PROFILE_NAME_RE.match(name):
        raise ProfileError(
            "Profile names must be 1-64 characters and may contain only "
            "letters, numbers, dot, underscore, and dash."
        )


class ProfileStore:
    def __init__(self, path: Path | None = None) -> None:
        self.path = (path or default_state_path()).expanduser()
        self.state = self._load()

    def _load(self) -> dict[str, Any]:
        if not self.path.exists():
            return empty_state()
        try:
            with self.path.open("r", encoding="utf-8") as handle:
                state = json.load(handle)
        except json.JSONDecodeError as exc:
            raise ProfileError(f"Invalid profile state JSON: {self.path}") from exc

        if not isinstance(state, dict):
            raise ProfileError("Profile state must be a JSON object")
        state.setdefault("version", STATE_VERSION)
        state.setdefault("active", None)
        state.setdefault("profiles", {})
        if not isinstance(state["profiles"], dict):
            raise ProfileError("Profile state 'profiles' must be a JSON object")
        return state

    def save(self) -> None:
        target = self.path.resolve() if self.path.exists() else self.path
        target.parent.mkdir(parents=True, exist_ok=True)
        tmp = target.with_suffix(target.suffix + ".tmp")
        with tmp.open("w", encoding="utf-8") as handle:
            json.dump(self.state, handle, indent=2, sort_keys=True)
            handle.write("\n")
        tmp.replace(target)

    @property
    def profiles(self) -> dict[str, Any]:
        return self.state["profiles"]

    def require_profile(self, name: str) -> dict[str, Any]:
        try:
            return self.profiles[name]
        except KeyError as exc:
            raise ProfileError(f"Profile does not exist: {name}") from exc

    def create(self, name: str, packages: list[str] | None = None) -> dict[str, Any]:
        validate_profile_name(name)
        if name in self.profiles:
            raise ProfileError(f"Profile already exists: {name}")
        profile = {
            "name": name,
            "packages": normalize_packages(packages),
            "created_at": utc_now(),
            "updated_at": utc_now(),
            "versions": [],
        }
        self.profiles[name] = profile
        self._record_version(name, "create")
        if self.state["active"] is None:
            self.state["active"] = name
        self.save()
        return profile

    def copy(self, source: str, destination: str) -> dict[str, Any]:
        source_profile = self.require_profile(source)
        validate_profile_name(destination)
        if destination in self.profiles:
            raise ProfileError(f"Profile already exists: {destination}")
        profile = deepcopy(source_profile)
        profile["name"] = destination
        profile["created_at"] = utc_now()
        profile["updated_at"] = utc_now()
        profile["versions"] = []
        self.profiles[destination] = profile
        self._record_version(destination, f"copy from {source}")
        self.save()
        return profile

    def edit(self, name: str, add: list[str] | None, remove: list[str] | None) -> dict[str, Any]:
        profile = self.require_profile(name)
        packages = set(profile.get("packages", []))
        packages.update(normalize_packages(add))
        for package in normalize_packages(remove):
            packages.discard(package)
        profile["packages"] = sorted(packages)
        profile["updated_at"] = utc_now()
        self._record_version(name, "edit")
        self.save()
        return profile

    def switch(self, name: str) -> Diff:
        self.validate(name)
        previous = self.state.get("active")
        diff = self.diff(previous, name) if previous else Diff(
            added=self.require_profile(name)["packages"],
            removed=[],
            unchanged=[],
        )
        self.state["active"] = name
        self.save()
        return diff

    def validate(self, name: str) -> None:
        profile = self.require_profile(name)
        validate_profile_name(name)
        packages = profile.get("packages")
        if not isinstance(packages, list):
            raise ProfileError(f"Profile {name} has invalid packages list")
        normalize_packages([str(package) for package in packages])

    def diff(self, left: str | None, right: str) -> Diff:
        if left is None:
            left_packages: set[str] = set()
        else:
            left_packages = set(self.require_profile(left).get("packages", []))
        right_packages = set(self.require_profile(right).get("packages", []))
        return Diff(
            added=sorted(right_packages - left_packages),
            removed=sorted(left_packages - right_packages),
            unchanged=sorted(left_packages & right_packages),
        )

    def export_profile(self, name: str) -> dict[str, Any]:
        self.validate(name)
        profile = deepcopy(self.require_profile(name))
        return {
            "format": "cx-profile",
            "format_version": STATE_VERSION,
            "exported_at": utc_now(),
            "profile": profile,
        }

    def import_profile(self, payload: dict[str, Any], name: str | None = None) -> dict[str, Any]:
        if payload.get("format") != "cx-profile":
            raise ProfileError("Import file is not a cx-profile export")
        profile = payload.get("profile")
        if not isinstance(profile, dict):
            raise ProfileError("Import file does not contain a profile object")
        imported_name = name or str(profile.get("name", ""))
        validate_profile_name(imported_name)
        if imported_name in self.profiles:
            raise ProfileError(f"Profile already exists: {imported_name}")
        raw_packages = profile.get("packages", [])
        if not isinstance(raw_packages, list):
            raise ProfileError("Imported profile 'packages' must be a list")
        if not all(isinstance(package, str) for package in raw_packages):
            raise ProfileError("All packages in the imported profile must be strings")
        packages = normalize_packages(raw_packages)
        created = {
            "name": imported_name,
            "packages": packages,
            "created_at": utc_now(),
            "updated_at": utc_now(),
            "versions": [],
        }
        self.profiles[imported_name] = created
        self._record_version(imported_name, "import")
        if self.state["active"] is None:
            self.state["active"] = imported_name
        self.save()
        return created

    def _record_version(self, name: str, message: str) -> None:
        profile = self.require_profile(name)
        versions = profile.setdefault("versions", [])
        versions.append(
            {
                "id": len(versions) + 1,
                "created_at": utc_now(),
                "message": message,
                "packages": list(profile.get("packages", [])),
            }
        )
        profile["updated_at"] = utc_now()


def print_profile(profile: dict[str, Any], active: bool = False) -> None:
    marker = "*" if active else " "
    packages = profile.get("packages", [])
    print(f"{marker} {profile['name']} ({len(packages)} packages)")
    if packages:
        print("  - " + ", ".join(packages))


def print_diff(diff: Diff, left: str | None, right: str) -> None:
    source = left or "<empty>"
    print(f"{source} -> {right}:")
    for package in diff.removed:
        print(f"  - {package}")
    for package in diff.added:
        print(f"  + {package}")
    if not diff.added and not diff.removed:
        print("  no package changes")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="cx-profile", description="Manage CX package installation profiles")
    sub = parser.add_subparsers(dest="command", required=True)

    create = sub.add_parser("create", help="create a named profile")
    create.add_argument("name")
    create.add_argument("--package", "-p", action="append", default=[], help="package to include")

    sub.add_parser("list", help="list profiles")
    sub.add_parser("active", help="show the active profile")

    copy = sub.add_parser("copy", help="copy a profile")
    copy.add_argument("source")
    copy.add_argument("destination")

    edit = sub.add_parser("edit", help="add or remove packages")
    edit.add_argument("name")
    edit.add_argument("--add", action="append", default=[])
    edit.add_argument("--remove", action="append", default=[])

    switch = sub.add_parser("switch", help="validate and activate a profile")
    switch.add_argument("name")

    diff = sub.add_parser("diff", help="show package differences between profiles")
    diff.add_argument("left")
    diff.add_argument("right")

    validate = sub.add_parser("validate", help="validate a profile")
    validate.add_argument("name")

    export = sub.add_parser("export", help="export a profile to JSON")
    export.add_argument("name")
    export.add_argument("path", nargs="?", help="output path; stdout when omitted")

    import_cmd = sub.add_parser("import", help="import a profile JSON export")
    import_cmd.add_argument("path")
    import_cmd.add_argument("--name", help="override imported profile name")

    history = sub.add_parser("history", help="show profile version history")
    history.add_argument("name")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        store = ProfileStore()
        if args.command == "create":
            profile = store.create(args.name, args.package)
            print(f"Profile '{profile['name']}' created")
            return 0
        if args.command == "list":
            active = store.state.get("active")
            for name in sorted(store.profiles):
                print_profile(store.profiles[name], active=name == active)
            return 0
        if args.command == "active":
            active = store.state.get("active")
            if not active:
                print("No active profile")
                return 1
            print("Current:", active)
            print_profile(store.require_profile(active), active=True)
            return 0
        if args.command == "copy":
            profile = store.copy(args.source, args.destination)
            print(f"Profile '{profile['name']}' copied from '{args.source}'")
            return 0
        if args.command == "edit":
            profile = store.edit(args.name, args.add, args.remove)
            print(f"Profile '{profile['name']}' updated")
            return 0
        if args.command == "switch":
            previous = store.state.get("active")
            diff = store.switch(args.name)
            print(f"Switched to '{args.name}' profile")
            print_diff(diff, previous, args.name)
            return 0
        if args.command == "diff":
            print_diff(store.diff(args.left, args.right), args.left, args.right)
            return 0
        if args.command == "validate":
            store.validate(args.name)
            print(f"Profile '{args.name}' is valid")
            return 0
        if args.command == "export":
            payload = store.export_profile(args.name)
            output = json.dumps(payload, indent=2, sort_keys=True) + "\n"
            if args.path:
                Path(args.path).write_text(output, encoding="utf-8")
                print(f"Profile '{args.name}' exported to {args.path}")
            else:
                print(output, end="")
            return 0
        if args.command == "import":
            payload = json.loads(Path(args.path).read_text(encoding="utf-8"))
            profile = store.import_profile(payload, args.name)
            print(f"Profile '{profile['name']}' imported")
            return 0
        if args.command == "history":
            profile = store.require_profile(args.name)
            for version in profile.get("versions", []):
                print(
                    f"v{version['id']} {version['created_at']} "
                    f"{version['message']} ({len(version['packages'])} packages)"
                )
            return 0
    except (OSError, json.JSONDecodeError, ProfileError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    parser.error(f"Unhandled command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
