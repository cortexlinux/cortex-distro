#!/usr/bin/env python3
"""Search CX APT package indexes with fuzzy and synonym-aware ranking."""

from __future__ import annotations

import argparse
import gzip
import re
import sys
from dataclasses import dataclass
from pathlib import Path


SYNONYMS = {
    "database": {"database", "db", "sql", "postgres", "postgresql", "mysql"},
    "gpu": {"gpu", "nvidia", "amd", "graphics", "cuda", "rocm"},
    "monitoring": {"monitoring", "metrics", "observability", "prometheus"},
    "security": {"security", "hardening", "firewall", "sandbox", "secops"},
    "web": {"web", "http", "server", "nginx", "apache", "caddy"},
}


@dataclass(frozen=True)
class Package:
    name: str
    version: str
    description: str
    fields: dict[str, str]


@dataclass(frozen=True)
class SearchResult:
    package: Package
    score: int
    reason: str


def normalize(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", value.lower()).strip()


def tokens(value: str) -> set[str]:
    return {token for token in normalize(value).split() if token}


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


def expanded_query_terms(query: str) -> set[str]:
    query_terms = tokens(query)
    expanded = set(query_terms)
    for term in query_terms:
        for group in SYNONYMS.values():
            if term in group:
                expanded.update(group)
    return expanded


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
    return Package(
        name=fields.get("Package", ""),
        version=fields.get("Version", ""),
        description=fields.get("Description", ""),
        fields=dict(fields),
    )


def score_package(package: Package, query: str) -> SearchResult | None:
    query_norm = normalize(query)
    query_terms = expanded_query_terms(query)
    name_norm = normalize(package.name)
    package_terms = tokens(f"{package.name} {package.description}")

    score = 0
    reasons: list[str] = []

    if query_norm == name_norm:
        score += 100
        reasons.append("exact name")
    elif query_norm in name_norm:
        score += 75
        reasons.append("name contains query")

    overlap = query_terms & package_terms
    if overlap:
        score += 12 * len(overlap)
        reasons.append("matched " + ", ".join(sorted(overlap)[:4]))

    closest_distance = min(
        (levenshtein(term, package.name) for term in tokens(query)),
        default=99,
    )
    if closest_distance <= 2:
        score += 45 - (closest_distance * 10)
        reasons.append("fuzzy name")

    for query_term in tokens(query):
        if len(query_term) < 4:
            continue
        for package_term in package_terms:
            if len(package_term) < 4:
                continue
            similar_length = abs(len(query_term) - len(package_term)) <= 2
            similar_spelling = levenshtein(query_term, package_term) <= 2
            if similar_length and similar_spelling:
                score += 8
                reasons.append("fuzzy term")
                break

    if score <= 0:
        return None

    return SearchResult(package=package, score=score, reason="; ".join(dict.fromkeys(reasons)))


def search(packages: list[Package], query: str, limit: int) -> list[SearchResult]:
    results = [result for package in packages if (result := score_package(package, query))]
    return sorted(results, key=lambda result: (-result.score, result.package.name))[:limit]


def default_index_paths(repo_root: Path) -> list[Path]:
    dists = repo_root / "dists"
    if not dists.exists():
        return []
    return sorted(dists.glob("**/Packages")) + sorted(dists.glob("**/Packages.gz"))


def load_packages(repo_root: Path, indexes: list[Path]) -> list[Package]:
    paths = indexes or default_index_paths(repo_root)
    packages: list[Package] = []
    for path in paths:
        if not path.exists():
            raise FileNotFoundError(f"package index not found: {path}")
        packages.extend(parse_packages_index(path))
    return packages


def print_results(results: list[SearchResult]) -> None:
    if not results:
        print("No matching packages found.")
        return

    print("Results:")
    for index, result in enumerate(results, 1):
        package = result.package
        print(f"  {index}. {package.name} ({package.version or 'unknown version'})")
        if package.description:
            first_line = package.description.splitlines()[0]
            print(f"     {first_line}")
        print(f"     score={result.score} reason={result.reason}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("query", help="Package name, typo, synonym, or natural-language query")
    parser.add_argument("--repo-root", type=Path, default=Path.cwd(), help="APT repository root")
    parser.add_argument("--index", type=Path, action="append", default=[], help="Packages or Packages.gz file")
    parser.add_argument("--limit", type=int, default=5, help="Maximum results to show")
    args = parser.parse_args(argv)

    try:
        packages = load_packages(args.repo_root, args.index)
    except OSError as error:
        print(error, file=sys.stderr)
        return 2

    if not packages:
        print("No package indexes found. Pass --index or run from an APT repository root.", file=sys.stderr)
        return 2

    print_results(search(packages, args.query, args.limit))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
