#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
"""Optimize package dependency trees from local APT Packages indexes.

The helper is intentionally read-only. It never calls apt, dpkg, sudo, or the
network; it only inspects Packages/Packages.gz metadata and produces a suggested
minimal dependency closure for review.
"""

from __future__ import annotations

import argparse
import gzip
import re
import sys
from dataclasses import dataclass
from pathlib import Path


DEP_SPLIT_RE = re.compile(r"\s*,\s*")
ALT_SPLIT_RE = re.compile(r"\s*\|\s*")
VERSION_RE = re.compile(r"\s*\([^)]*\)")
ARCH_RE = re.compile(r":(?:any|native|[a-z0-9-]+)$")


@dataclass(frozen=True)
class Package:
    name: str
    version: str
    installed_size: int
    depends: tuple[tuple[str, ...], ...]
    conflicts: frozenset[str]
    provides: frozenset[str]
    description: str


@dataclass
class Resolution:
    selected: dict[str, Package]
    edges: dict[str, list[str]]
    missing: list[str]
    conflicts: list[str]
    roots: dict[str, str]

    @property
    def total_size(self) -> int:
        return sum(package.installed_size for package in self.selected.values())


def normalize_package_name(value: str) -> str:
    value = VERSION_RE.sub("", value).strip()
    value = ARCH_RE.sub("", value)
    return value.strip()


def parse_dependency_groups(value: str) -> tuple[tuple[str, ...], ...]:
    groups: list[tuple[str, ...]] = []
    for group in DEP_SPLIT_RE.split(value):
        alternatives = tuple(
            name
            for name in (normalize_package_name(item) for item in ALT_SPLIT_RE.split(group))
            if name
        )
        if alternatives:
            groups.append(alternatives)
    return tuple(groups)


def parse_name_set(value: str) -> frozenset[str]:
    names: set[str] = set()
    for group in DEP_SPLIT_RE.split(value):
        for item in ALT_SPLIT_RE.split(group):
            name = normalize_package_name(item)
            if name:
                names.add(name)
    return frozenset(names)


def open_index(path: Path):
    if path.suffix == ".gz":
        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
    return path.open("r", encoding="utf-8", errors="replace")


def read_stanzas(path: Path) -> list[dict[str, str]]:
    stanzas: list[dict[str, str]] = []
    current: dict[str, str] = {}
    current_key: str | None = None

    with open_index(path) as handle:
        for raw_line in handle:
            line = raw_line.rstrip("\n")
            if not line:
                if current:
                    stanzas.append(current)
                current = {}
                current_key = None
                continue

            if line.startswith(" ") and current_key:
                current[current_key] = f"{current[current_key]}\n{line.strip()}"
                continue

            key, separator, value = line.partition(":")
            if separator:
                current_key = key
                current[key] = value.strip()

    if current:
        stanzas.append(current)

    return stanzas


def package_from_stanza(stanza: dict[str, str]) -> Package | None:
    name = stanza.get("Package", "")
    if not name:
        return None

    try:
        installed_size = int(stanza.get("Installed-Size", "0"))
    except ValueError:
        installed_size = 0

    dependency_text = ", ".join(
        value for key in ("Pre-Depends", "Depends") if (value := stanza.get(key))
    )

    return Package(
        name=name,
        version=stanza.get("Version", ""),
        installed_size=installed_size,
        depends=parse_dependency_groups(dependency_text),
        conflicts=parse_name_set(", ".join(stanza.get(key, "") for key in ("Conflicts", "Breaks"))),
        provides=parse_name_set(stanza.get("Provides", "")),
        description=stanza.get("Description", "").splitlines()[0],
    )


def default_index_paths(repo_root: Path) -> list[Path]:
    dists = repo_root / "dists"
    if not dists.exists():
        return []

    plain = sorted(dists.glob("**/Packages"))
    plain_dirs = {path.parent for path in plain}
    gz = sorted(path for path in dists.glob("**/Packages.gz") if path.parent not in plain_dirs)
    return plain + gz


def load_packages(repo_root: Path, indexes: list[Path]) -> tuple[dict[str, Package], dict[str, list[str]]]:
    paths = indexes or default_index_paths(repo_root)
    by_name: dict[str, Package] = {}
    providers: dict[str, list[str]] = {}
    seen_paths: set[Path] = set()

    for path in paths:
        path = path.resolve()
        if path in seen_paths:
            continue
        seen_paths.add(path)
        if not path.exists():
            raise FileNotFoundError(f"package index not found: {path}")

        for stanza in read_stanzas(path):
            package = package_from_stanza(stanza)
            if not package:
                continue
            existing = by_name.get(package.name)
            if existing and existing.installed_size <= package.installed_size:
                continue
            by_name[package.name] = package
            for provided in package.provides:
                providers.setdefault(provided, []).append(package.name)

    return by_name, providers


def candidate_names(name: str, packages: dict[str, Package], providers: dict[str, list[str]]) -> list[str]:
    names: list[str] = []
    if name in packages:
        names.append(name)
    names.extend(providers.get(name, []))
    return sorted(dict.fromkeys(names), key=lambda item: packages[item].installed_size)


def estimate_closure_size(
    name: str,
    packages: dict[str, Package],
    providers: dict[str, list[str]],
    seen: frozenset[str],
) -> int:
    candidates = candidate_names(name, packages, providers)
    if not candidates:
        return sys.maxsize // 4

    best = sys.maxsize // 4
    for candidate in candidates:
        if candidate in seen:
            return 0
        package = packages[candidate]
        total = package.installed_size
        next_seen = seen | {candidate}
        for group in package.depends:
            total += min(
                estimate_closure_size(option, packages, providers, next_seen) for option in group
            )
        best = min(best, total)
    return best


def pick_dependency(
    alternatives: tuple[str, ...],
    packages: dict[str, Package],
    providers: dict[str, list[str]],
    seen: frozenset[str],
) -> str | None:
    scored: list[tuple[int, str]] = []
    for alternative in alternatives:
        for candidate in candidate_names(alternative, packages, providers):
            scored.append((estimate_closure_size(candidate, packages, providers, seen), candidate))
    if not scored:
        return None
    return min(scored)[1]


def resolve_targets(
    targets: list[str],
    packages: dict[str, Package],
    providers: dict[str, list[str]],
) -> Resolution:
    resolution = Resolution(selected={}, edges={}, missing=[], conflicts=[], roots={})

    def add_package(name: str, parent: str | None = None, stack: frozenset[str] = frozenset()) -> None:
        candidates = candidate_names(name, packages, providers)
        if not candidates:
            resolution.missing.append(name if parent is None else f"{parent} -> {name}")
            return

        package_name = min(
            candidates,
            key=lambda candidate: estimate_closure_size(candidate, packages, providers, stack),
        )
        if parent is None:
            resolution.roots[name] = package_name
        if parent:
            resolution.edges.setdefault(parent, []).append(package_name)

        if package_name in stack or package_name in resolution.selected:
            return

        package = packages[package_name]
        resolution.selected[package_name] = package
        next_stack = stack | {package_name}

        for group in package.depends:
            picked = pick_dependency(group, packages, providers, next_stack)
            if not picked:
                resolution.missing.append(f"{package_name} -> {' | '.join(group)}")
                continue
            add_package(picked, package_name, next_stack)

    for target in targets:
        add_package(target)

    detect_conflicts(resolution)
    return resolution


def detect_conflicts(resolution: Resolution) -> None:
    selected = resolution.selected
    selected_names = set(selected)
    virtuals = {provided for package in selected.values() for provided in package.provides}
    selected_or_provided = selected_names | virtuals

    for package in selected.values():
        for conflict in sorted(package.conflicts & selected_or_provided):
            resolution.conflicts.append(f"{package.name} conflicts with {conflict}")


def print_tree(name: str, edges: dict[str, list[str]], indent: str, seen: set[str]) -> None:
    print(f"{indent}- {name}")
    if name in seen:
        print(f"{indent}  (cycle skipped)")
        return
    seen.add(name)
    for child in sorted(dict.fromkeys(edges.get(name, []))):
        print_tree(child, edges, f"{indent}  ", seen)


def print_dot(resolution: Resolution) -> None:
    print("digraph dependencies {")
    print('  rankdir="LR";')
    for name in sorted(resolution.selected):
        print(f'  "{name}";')
    for parent, children in sorted(resolution.edges.items()):
        for child in sorted(dict.fromkeys(children)):
            print(f'  "{parent}" -> "{child}";')
    print("}")


def print_summary(targets: list[str], resolution: Resolution, show_dot: bool) -> None:
    print("Optimized dependency plan")
    print("=========================")
    print(f"Targets: {', '.join(targets)}")
    print(f"Selected packages: {len(resolution.selected)}")
    print(f"Total Installed-Size: {resolution.total_size} KiB")
    print()

    print("Package closure:")
    for name in sorted(resolution.selected):
        package = resolution.selected[name]
        version = f" {package.version}" if package.version else ""
        description = f" - {package.description}" if package.description else ""
        print(f"  - {name}{version} ({package.installed_size} KiB){description}")
    print()

    print("Dependency tree:")
    for target in targets:
        root = resolution.roots.get(target, target)
        print_tree(root, resolution.edges, "", set())
    print()

    if resolution.missing:
        print("Missing dependencies:")
        for missing in sorted(dict.fromkeys(resolution.missing)):
            print(f"  - {missing}")
    else:
        print("Missing dependencies: none")

    if resolution.conflicts:
        print("Conflicts:")
        for conflict in sorted(dict.fromkeys(resolution.conflicts)):
            print(f"  - {conflict}")
    else:
        print("Conflicts: none")

    if show_dot:
        print()
        print_dot(resolution)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("packages", nargs="+", help="Target package names or virtual packages")
    parser.add_argument("--repo-root", type=Path, default=Path.cwd(), help="APT repository root")
    parser.add_argument("--index", type=Path, action="append", default=[], help="Packages or Packages.gz file")
    parser.add_argument("--dot", action="store_true", help="Include Graphviz DOT output")
    args = parser.parse_args(argv)

    try:
        packages, providers = load_packages(args.repo_root, args.index)
    except OSError as error:
        print(error, file=sys.stderr)
        return 2

    if not packages:
        print("No package indexes found. Pass --index or run from an APT repository root.", file=sys.stderr)
        return 2

    resolution = resolve_targets(args.packages, packages, providers)
    print_summary(args.packages, resolution, args.dot)

    if resolution.missing or resolution.conflicts:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
