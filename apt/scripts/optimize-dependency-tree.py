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
RELATION_RE = re.compile(
    r"^\s*([a-z0-9+.-]+(?::(?:any|native|[a-z0-9-]+))?)"
    r"(?:\s*\((<<|<=|=|>=|>>)\s*([^)]+)\))?\s*$"
)
ARCH_RE = re.compile(r":(?:any|native|[a-z0-9-]+)$")


@dataclass(frozen=True)
class Requirement:
    """Package or virtual-package relationship requested by an APT field."""

    name: str
    operator: str = ""
    version: str = ""


@dataclass(frozen=True)
class Package:
    """Normalized package metadata extracted from an APT Packages stanza."""

    name: str
    version: str
    installed_size: int
    depends: tuple[tuple[Requirement, ...], ...]
    conflicts: frozenset[Requirement]
    provides: frozenset[Requirement]
    description: str


@dataclass
class Resolution:
    """Dependency resolution result, including selected packages and diagnostics."""

    selected: dict[str, Package]
    edges: dict[str, list[str]]
    missing: list[str]
    conflicts: list[str]
    roots: dict[str, str]

    @property
    def total_size(self) -> int:
        """Return the sum of Installed-Size values for selected packages."""
        return sum(package.installed_size for package in self.selected.values())


def normalize_package_name(value: str) -> str:
    """Strip architecture qualifiers from a package or virtual package name."""
    return ARCH_RE.sub("", value).strip()


def parse_requirement(value: str) -> Requirement | None:
    """Parse a Debian package relationship token into name, operator, and version."""
    match = RELATION_RE.match(value)
    if not match:
        name = normalize_package_name(value)
        return Requirement(name) if name else None
    name, operator, version = match.groups()
    return Requirement(normalize_package_name(name), operator or "", version or "")


def parse_dependency_groups(value: str) -> tuple[tuple[Requirement, ...], ...]:
    """Parse Depends/Pre-Depends text into comma groups with pipe alternatives."""
    groups: list[tuple[Requirement, ...]] = []
    for group in DEP_SPLIT_RE.split(value):
        alternatives = tuple(
            requirement
            for requirement in (
                parse_requirement(item) for item in ALT_SPLIT_RE.split(group)
            )
            if requirement
        )
        if alternatives:
            groups.append(alternatives)
    return tuple(groups)


def parse_requirement_set(value: str) -> frozenset[Requirement]:
    """Parse a comma/pipe separated relationship field into normalized names."""
    requirements: set[Requirement] = set()
    for group in DEP_SPLIT_RE.split(value):
        for item in ALT_SPLIT_RE.split(group):
            requirement = parse_requirement(item)
            if requirement:
                requirements.add(requirement)
    return frozenset(requirements)


def open_index(path: Path):
    """Open either a plain Packages file or a gzipped Packages.gz index."""
    if path.suffix == ".gz":
        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
    return path.open("r", encoding="utf-8", errors="replace")


def read_stanzas(path: Path) -> list[dict[str, str]]:
    """Read Debian control stanzas, preserving folded continuation lines."""
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

            if line.startswith((" ", "\t")) and current_key:
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
    """Convert one Packages stanza into a Package, skipping malformed entries."""
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

    description_lines = stanza.get("Description", "").splitlines()

    return Package(
        name=name,
        version=stanza.get("Version", ""),
        installed_size=installed_size,
        depends=parse_dependency_groups(dependency_text),
        conflicts=parse_requirement_set(
            ", ".join(stanza.get(key, "") for key in ("Conflicts", "Breaks"))
        ),
        provides=parse_requirement_set(stanza.get("Provides", "")),
        description=description_lines[0] if description_lines else "",
    )


def default_index_paths(repo_root: Path) -> list[Path]:
    """Discover Packages indexes below dists/, preferring plain files over gzip twins."""
    dists = repo_root / "dists"
    if not dists.exists():
        return []

    plain = sorted(dists.glob("**/Packages"))
    plain_dirs = {path.parent for path in plain}
    gz = sorted(path for path in dists.glob("**/Packages.gz") if path.parent not in plain_dirs)
    return plain + gz


def load_packages(
    repo_root: Path, indexes: list[Path]
) -> tuple[dict[str, list[Package]], dict[str, list[tuple[Package, Requirement]]]]:
    """Load package metadata and virtual-package provider mappings from indexes."""
    paths = indexes or default_index_paths(repo_root)
    by_name: dict[str, list[Package]] = {}
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
            by_name.setdefault(package.name, []).append(package)

    for versions in by_name.values():
        versions.sort(key=lambda package: (package.installed_size, package.version))

    providers: dict[str, list[tuple[Package, Requirement]]] = {}
    for versions in by_name.values():
        if not versions:
            continue
        package = versions[0]
        for provided in package.provides:
            providers.setdefault(provided.name, []).append((package, provided))

    for provided_packages in providers.values():
        provided_packages.sort(key=lambda item: (item[0].installed_size, item[0].name))

    return by_name, providers


def debian_version_compare(left: str, right: str) -> int:
    """Compare two Debian package versions using Debian Policy ordering rules."""

    def split_epoch(version: str) -> tuple[int, str]:
        epoch_text, separator, rest = version.partition(":")
        if separator and epoch_text.isdigit():
            return int(epoch_text), rest
        return 0, version

    def split_revision(version: str) -> tuple[str, str]:
        upstream, separator, revision = version.rpartition("-")
        if separator:
            return upstream, revision
        return version, "0"

    def char_order(char: str) -> int:
        if not char:
            return 0
        if char == "~":
            return -1
        if char.isalpha():
            return ord(char)
        return ord(char) + 256

    def compare_part(left_part: str, right_part: str) -> int:
        left_index = right_index = 0
        while left_index < len(left_part) or right_index < len(right_part):
            while (
                left_index < len(left_part) and not left_part[left_index].isdigit()
            ) or (
                right_index < len(right_part) and not right_part[right_index].isdigit()
            ):
                left_char = left_part[left_index] if left_index < len(left_part) else ""
                right_char = (
                    right_part[right_index] if right_index < len(right_part) else ""
                )
                order_delta = char_order(left_char) - char_order(right_char)
                if order_delta:
                    return -1 if order_delta < 0 else 1
                if left_index < len(left_part):
                    left_index += 1
                if right_index < len(right_part):
                    right_index += 1

            left_digit_start = left_index
            right_digit_start = right_index
            while left_index < len(left_part) and left_part[left_index].isdigit():
                left_index += 1
            while right_index < len(right_part) and right_part[right_index].isdigit():
                right_index += 1

            left_digits = left_part[left_digit_start:left_index].lstrip("0")
            right_digits = right_part[right_digit_start:right_index].lstrip("0")
            if len(left_digits) != len(right_digits):
                return -1 if len(left_digits) < len(right_digits) else 1
            if left_digits != right_digits:
                return -1 if left_digits < right_digits else 1

        return 0

    left_epoch, left_rest = split_epoch(left)
    right_epoch, right_rest = split_epoch(right)
    if left_epoch != right_epoch:
        return -1 if left_epoch < right_epoch else 1

    left_upstream, left_revision = split_revision(left_rest)
    right_upstream, right_revision = split_revision(right_rest)
    upstream_result = compare_part(left_upstream, right_upstream)
    if upstream_result:
        return upstream_result
    return compare_part(left_revision, right_revision)


def version_satisfies(
    candidate_version: str, operator: str, required_version: str
) -> bool:
    """Return whether a candidate version satisfies a Debian relationship."""
    if not operator:
        return True
    comparison = debian_version_compare(candidate_version, required_version)
    return {
        "<<": comparison < 0,
        "<=": comparison <= 0,
        "=": comparison == 0,
        ">=": comparison >= 0,
        ">>": comparison > 0,
    }[operator]


def package_satisfies(requirement: Requirement, package: Package) -> bool:
    """Return whether a real package satisfies a requested relationship."""
    return package.name == requirement.name and version_satisfies(
        package.version, requirement.operator, requirement.version
    )


def provider_satisfies(requirement: Requirement, provided: Requirement) -> bool:
    """Return whether a Provides relationship satisfies a virtual package request."""
    if provided.name != requirement.name:
        return False
    if not requirement.operator:
        return True
    if not provided.version:
        return False
    return version_satisfies(provided.version, requirement.operator, requirement.version)


def selected_package_for(
    requirement: Requirement, selected: dict[str, Package]
) -> Package | None:
    """Return the selected package satisfying a real or virtual requirement."""
    package = selected.get(requirement.name)
    if package and package_satisfies(requirement, package):
        return package
    for package in selected.values():
        for provided in package.provides:
            if provider_satisfies(requirement, provided):
                return package
    return None


def candidate_packages(
    requirement: Requirement,
    packages: dict[str, list[Package]],
    providers: dict[str, list[tuple[Package, Requirement]]],
) -> list[Package]:
    """Return real packages that satisfy a requested package or virtual name."""
    candidates: list[Package] = [
        package
        for package in packages.get(requirement.name, [])
        if package_satisfies(requirement, package)
    ]
    candidates.extend(
        package
        for package, provided in providers.get(requirement.name, [])
        if provider_satisfies(requirement, provided)
    )

    by_name: dict[str, Package] = {}
    for package in sorted(candidates, key=lambda item: (item.installed_size, item.name)):
        by_name.setdefault(package.name, package)
    return list(by_name.values())


@dataclass(frozen=True)
class Estimate:
    """Estimated marginal cost and selected closure for one dependency choice."""

    cost: int
    selected: dict[str, Package]
    package: Package | None


def requirement_text(requirement: Requirement) -> str:
    """Render a dependency relationship for diagnostics."""
    if not requirement.operator:
        return requirement.name
    return f"{requirement.name} ({requirement.operator} {requirement.version})"


def selected_cache_key(selected: dict[str, Package]) -> tuple[tuple[str, str], ...]:
    """Build a stable cache key for the current selected package versions."""
    return tuple(sorted((name, package.version) for name, package in selected.items()))


def estimate_package_closure(
    package: Package,
    packages: dict[str, list[Package]],
    providers: dict[str, list[tuple[Package, Requirement]]],
    selected: dict[str, Package],
    ancestors: frozenset[str],
    memo: dict[tuple[Requirement, tuple[tuple[str, str], ...], frozenset[str]], Estimate],
) -> Estimate:
    """Estimate marginal cost for adding a package and its dependencies."""
    if package.name in ancestors:
        return Estimate(0, selected, package)

    next_selected = dict(selected)
    cost = 0
    existing = next_selected.get(package.name)
    if not existing or existing.version != package.version:
        cost = package.installed_size
        next_selected[package.name] = package

    next_ancestors = ancestors | {package.name}
    for group in package.depends:
        estimates = [
            estimate_requirement_closure(
                requirement, packages, providers, next_selected, next_ancestors, memo
            )
            for requirement in group
        ]
        best = min(
            estimates,
            key=lambda estimate: (
                estimate.cost,
                estimate.package.name if estimate.package else "",
            ),
        )
        cost += best.cost
        next_selected = best.selected

    return Estimate(cost, next_selected, package)


def estimate_requirement_closure(
    requirement: Requirement,
    packages: dict[str, list[Package]],
    providers: dict[str, list[tuple[Package, Requirement]]],
    selected: dict[str, Package],
    ancestors: frozenset[str],
    memo: dict[tuple[Requirement, tuple[tuple[str, str], ...], frozenset[str]], Estimate],
) -> Estimate:
    """Estimate the marginal closure for satisfying a package relationship."""
    selected_package = selected_package_for(requirement, selected)
    if selected_package:
        return Estimate(0, selected, selected_package)

    cache_key = (requirement, selected_cache_key(selected), ancestors)
    if cache_key in memo:
        return memo[cache_key]

    candidates = candidate_packages(requirement, packages, providers)
    if not candidates:
        result = Estimate(sys.maxsize // 4, selected, None)
        memo[cache_key] = result
        return result

    result = min(
        (
            estimate_package_closure(
                candidate, packages, providers, selected, ancestors, memo
            )
            for candidate in candidates
        ),
        key=lambda estimate: (
            estimate.cost,
            estimate.package.name if estimate.package else "",
        ),
    )
    memo[cache_key] = result
    return result


def pick_dependency(
    alternatives: tuple[Requirement, ...],
    packages: dict[str, list[Package]],
    providers: dict[str, list[tuple[Package, Requirement]]],
    selected: dict[str, Package],
    seen: frozenset[str],
    memo: dict[tuple[Requirement, tuple[tuple[str, str], ...], frozenset[str]], Estimate],
) -> Requirement | None:
    """Choose the smallest satisfiable option from a dependency alternative group."""
    scored = [
        (
            estimate_requirement_closure(
                alternative, packages, providers, selected, seen, memo
            ).cost,
            requirement_text(alternative),
            alternative,
        )
        for alternative in alternatives
        if candidate_packages(alternative, packages, providers)
        or selected_package_for(alternative, selected)
    ]
    if not scored:
        return None
    return min(scored)[2]


def resolve_targets(
    targets: list[str],
    packages: dict[str, list[Package]],
    providers: dict[str, list[tuple[Package, Requirement]]],
) -> Resolution:
    """Resolve target packages into a minimal dependency closure plus diagnostics."""
    resolution = Resolution(selected={}, edges={}, missing=[], conflicts=[], roots={})
    closure_size_memo: dict[
        tuple[Requirement, tuple[tuple[str, str], ...], frozenset[str]], Estimate
    ] = {}

    def add_package(
        requirement: Requirement,
        parent: str | None = None,
        stack: frozenset[str] = frozenset(),
    ) -> None:
        """Add one dependency and recursively expand its selected dependency choices."""
        selected_package = selected_package_for(requirement, resolution.selected)
        if selected_package:
            if parent:
                resolution.edges.setdefault(parent, []).append(selected_package.name)
            elif requirement.name not in resolution.roots:
                resolution.roots[requirement.name] = selected_package.name
            return

        candidates = candidate_packages(requirement, packages, providers)
        if not candidates:
            missing = requirement_text(requirement)
            resolution.missing.append(
                missing if parent is None else f"{parent} -> {missing}"
            )
            return

        package = min(
            candidates,
            key=lambda candidate: estimate_package_closure(
                candidate,
                packages,
                providers,
                dict(resolution.selected),
                stack,
                closure_size_memo,
            ).cost,
        )
        if parent is None:
            resolution.roots[requirement.name] = package.name
        if parent:
            resolution.edges.setdefault(parent, []).append(package.name)

        if package.name in stack or package.name in resolution.selected:
            return

        resolution.selected[package.name] = package
        next_stack = stack | {package.name}

        for group in package.depends:
            picked = pick_dependency(
                group,
                packages,
                providers,
                dict(resolution.selected),
                next_stack,
                closure_size_memo,
            )
            if not picked:
                resolution.missing.append(
                    f"{package.name} -> "
                    f"{' | '.join(requirement_text(item) for item in group)}"
                )
                continue
            add_package(picked, package.name, next_stack)

    for target in targets:
        add_package(Requirement(target))

    detect_conflicts(resolution)
    return resolution


def detect_conflicts(resolution: Resolution) -> None:
    """Populate conflict diagnostics for selected packages and provided virtual names."""
    selected = resolution.selected

    for package in selected.values():
        for conflict in sorted(package.conflicts, key=requirement_text):
            for other in selected.values():
                if other.name == package.name:
                    continue
                if package_satisfies(conflict, other) or any(
                    provider_satisfies(conflict, provided)
                    for provided in other.provides
                ):
                    resolution.conflicts.append(
                        f"{package.name} conflicts with {requirement_text(conflict)}"
                    )
                    break


def print_tree(name: str, edges: dict[str, list[str]], indent: str, path: frozenset[str]) -> None:
    """Print a dependency tree, avoiding infinite recursion on cycles."""
    print(f"{indent}- {name}")
    if name in path:
        print(f"{indent}  (cycle skipped)")
        return
    next_path = path | {name}
    for child in sorted(dict.fromkeys(edges.get(name, []))):
        print_tree(child, edges, f"{indent}  ", next_path)


def print_dot(resolution: Resolution) -> None:
    """Print the selected dependency graph in Graphviz DOT format."""
    print("digraph dependencies {")
    print('  rankdir="LR";')
    for name in sorted(resolution.selected):
        print(f'  "{name}";')
    for parent, children in sorted(resolution.edges.items()):
        for child in sorted(dict.fromkeys(children)):
            print(f'  "{parent}" -> "{child}";')
    print("}")


def print_summary(targets: list[str], resolution: Resolution, show_dot: bool) -> None:
    """Print a human-readable dependency plan and optional graph output."""
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
        print_tree(root, resolution.edges, "", frozenset())
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
    """Parse CLI arguments, run dependency resolution, and return a process status."""
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
