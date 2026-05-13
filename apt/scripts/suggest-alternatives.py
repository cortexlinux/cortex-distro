#!/usr/bin/env python3
"""Suggest installable alternatives when a requested package is unavailable."""

from __future__ import annotations

import argparse
import gzip
import json
import re
import sys
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path


PACKAGE_GROUPS = {
    "web-server": {
        "aliases": {"apache-server", "apache", "httpd", "web-server", "web server"},
        "packages": {
            "apache2": "drop-in Apache HTTP Server package on Debian-compatible systems",
            "nginx": "modern reverse proxy and static web server alternative",
            "caddy": "automatic HTTPS web server alternative",
        },
    },
    "database": {
        "aliases": {"postgres", "postgresql-server", "sql-server", "database", "db"},
        "packages": {
            "postgresql": "default PostgreSQL server package",
            "mariadb-server": "MySQL-compatible relational database server",
            "sqlite3": "embedded SQL database CLI and library",
        },
    },
    "container": {
        "aliases": {"docker", "containers", "container-runtime", "oci"},
        "packages": {
            "podman": "daemonless OCI container engine",
            "docker.io": "Debian-packaged Docker engine",
            "containerd": "low-level container runtime",
        },
    },
    "gpu": {
        "aliases": {"cuda", "nvidia-driver", "graphics-driver", "gpu-driver"},
        "packages": {
            "cx-gpu-nvidia": "CX NVIDIA GPU enablement helpers",
            "cx-gpu-amd": "CX AMD GPU enablement helpers",
            "nvidia-driver": "Debian NVIDIA driver metapackage",
        },
    },
    "security": {
        "aliases": {"hardening", "secops", "security-tools", "firewall"},
        "packages": {
            "cx-secops": "CX security hardening and sandbox tooling",
            "ufw": "simple host firewall frontend",
            "fail2ban": "log-driven intrusion prevention service",
        },
    },
}


@dataclass(frozen=True)
class Package:
    name: str
    version: str
    description: str
    fields: dict[str, str]


@dataclass(frozen=True)
class Suggestion:
    package: Package
    score: int
    reason: str
    compatibility: str
    feature_notes: tuple[str, ...]


def normalize(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", value.lower()).strip()


def tokens(value: str) -> set[str]:
    return {token for token in normalize(value).split() if token}


@lru_cache(maxsize=4096)
def levenshtein(a: str, b: str) -> int:
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)

    previous = list(range(len(b) + 1))
    for i, char_a in enumerate(a, 1):
        current = [i]
        for j, char_b in enumerate(b, 1):
            current.append(
                min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (char_a != char_b),
                )
            )
        previous = current
    return previous[-1]


def open_index(path: Path):
    if path.suffix == ".gz":
        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
    return path.open("r", encoding="utf-8", errors="replace")


def parse_packages_index(path: Path) -> list[Package]:
    packages: list[Package] = []
    current: dict[str, str] = {}
    last_key: str | None = None

    with open_index(path) as handle:
        for raw_line in handle:
            line = raw_line.rstrip("\n")
            if not line:
                if current:
                    packages.append(package_from_fields(current))
                    current = {}
                    last_key = None
                continue

            if line.startswith(" ") and last_key:
                current[last_key] = f"{current[last_key]}\n{line.strip()}"
                continue

            key, separator, value = line.partition(":")
            if separator:
                last_key = key
                current[key] = value.strip()

    if current:
        packages.append(package_from_fields(current))

    return packages


def package_from_fields(fields: dict[str, str]) -> Package:
    package_name = fields.get("Package")
    if not package_name:
        raise ValueError("missing Package field in stanza")

    return Package(
        name=package_name,
        version=fields.get("Version", ""),
        description=fields.get("Description", ""),
        fields=dict(fields),
    )


def default_index_paths(repo_root: Path) -> list[Path]:
    dists = repo_root / "dists"
    if not dists.exists():
        return []

    plain_indexes = sorted(dists.glob("**/Packages"))
    plain_dirs = {path.parent for path in plain_indexes}
    gzip_only_indexes = sorted(
        path for path in dists.glob("**/Packages.gz") if path.parent not in plain_dirs
    )
    return plain_indexes + gzip_only_indexes


def load_packages(repo_root: Path, indexes: list[Path]) -> list[Package]:
    paths = indexes or default_index_paths(repo_root)
    packages: list[Package] = []
    seen_paths: set[Path] = set()
    seen_packages: set[tuple[str, str, str]] = set()
    for path in paths:
        path_key = path.resolve()
        if path_key in seen_paths:
            continue
        seen_paths.add(path_key)

        if not path.exists():
            raise FileNotFoundError(f"package index not found: {path}")
        for package in parse_packages_index(path):
            package_key = (package.name, package.version, package.description)
            if package_key in seen_packages:
                continue
            seen_packages.add(package_key)
            packages.append(package)
    return packages


def matched_group_names(query: str) -> set[str]:
    query_norm = normalize(query)
    query_terms = tokens(query)
    matches: set[str] = set()

    for group_name, group in PACKAGE_GROUPS.items():
        aliases = group["aliases"] | set(group["packages"])
        for alias in aliases:
            alias_norm = normalize(alias)
            alias_terms = tokens(alias)
            if query_norm == alias_norm or query_terms & alias_terms:
                matches.add(group_name)
                break
            if (
                len(query_norm) >= 4
                and abs(len(query_norm) - len(alias_norm)) <= 3
                and levenshtein(query_norm, alias_norm) <= 3
            ):
                matches.add(group_name)
                break

    return matches


def package_available(packages: list[Package], requested: str) -> Package | None:
    requested_norm = normalize(requested)
    for package in packages:
        if normalize(package.name) == requested_norm:
            return package
    return None


def score_package(package: Package, requested: str, group_names: set[str]) -> Suggestion | None:
    package_terms = tokens(f"{package.name} {package.description}")
    requested_terms = tokens(requested)
    package_name_norm = normalize(package.name)
    requested_norm = normalize(requested)

    score = 0
    reasons: list[str] = []
    feature_notes: list[str] = []

    if requested_terms & package_terms:
        score += 35
        reasons.append("shared package terms")

    distance = (
        levenshtein(requested_norm, package_name_norm)
        if abs(len(requested_norm) - len(package_name_norm)) <= 3
        else 99
    )
    if distance <= 3:
        score += 40 - (distance * 8)
        reasons.append("similar package name")

    for group_name in group_names:
        group_packages = PACKAGE_GROUPS[group_name]["packages"]
        if package.name in group_packages:
            score += 80
            reasons.append(f"{group_name} alternative")
            feature_notes.append(group_packages[package.name])

    description_overlap = requested_terms & tokens(package.description)
    if description_overlap:
        score += 10 * len(description_overlap)
        reasons.append("description overlap")

    if score <= 0:
        return None

    compatibility = "high"
    if "alternative" in " ".join(reasons):
        compatibility = "recommended"
    elif distance > 2 and not description_overlap:
        compatibility = "possible"

    if package.description:
        feature_notes.append(package.description.splitlines()[0])

    return Suggestion(
        package=package,
        score=score,
        reason="; ".join(dict.fromkeys(reasons)),
        compatibility=compatibility,
        feature_notes=tuple(dict.fromkeys(feature_notes)),
    )


def suggest_alternatives(packages: list[Package], requested: str, limit: int) -> list[Suggestion]:
    group_names = matched_group_names(requested)
    suggestions = [
        suggestion
        for package in packages
        if (suggestion := score_package(package, requested, group_names))
    ]
    return sorted(suggestions, key=lambda item: (-item.score, item.package.name))[:limit]


def print_human(requested: str, installed: Package | None, suggestions: list[Suggestion]) -> None:
    if installed:
        print(f"Package '{requested}' is available as {installed.name} ({installed.version or 'unknown version'}).")
        return

    print(f"Package '{requested}' was not found.")
    if not suggestions:
        print("No close alternatives found in the configured package indexes.")
        return

    print("")
    print("Did you mean:")
    for index, suggestion in enumerate(suggestions, 1):
        package = suggestion.package
        print(f"  {index}. {package.name} ({package.version or 'unknown version'})")
        print(f"     compatibility={suggestion.compatibility} score={suggestion.score}")
        print(f"     reason={suggestion.reason}")
        if suggestion.feature_notes:
            print(f"     features={suggestion.feature_notes[0]}")


def print_json(requested: str, installed: Package | None, suggestions: list[Suggestion]) -> None:
    payload = {
        "requested": requested,
        "available": installed is not None,
        "matched_package": installed.name if installed else None,
        "suggestions": [
            {
                "package": suggestion.package.name,
                "version": suggestion.package.version,
                "score": suggestion.score,
                "reason": suggestion.reason,
                "compatibility": suggestion.compatibility,
                "features": list(suggestion.feature_notes),
            }
            for suggestion in suggestions
        ],
    }
    print(json.dumps(payload, indent=2, sort_keys=True))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", help="Requested package name")
    parser.add_argument("--repo-root", type=Path, default=Path("apt"), help="APT repository root")
    parser.add_argument("--index", type=Path, action="append", default=[], help="Packages index path")
    parser.add_argument("--limit", type=int, default=5, help="Maximum suggestions to show")
    parser.add_argument("--json", action="store_true", help="Print machine-readable suggestions")
    args = parser.parse_args(argv)

    try:
        packages = load_packages(args.repo_root, args.index)
    except OSError as error:
        print(str(error), file=sys.stderr)
        return 2

    installed = package_available(packages, args.package)
    suggestions: list[Suggestion] = []
    if not installed:
        suggestions = suggest_alternatives(packages, args.package, args.limit)

    if args.json:
        print_json(args.package, installed, suggestions)
    else:
        print_human(args.package, installed, suggestions)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
