#!/usr/bin/env python3
"""View, search, compare, and export Debian package changelogs.

The command is intentionally offline-first for distro-builder workflows: it reads
local ``packages/<name>/debian/changelog`` files by default, while also allowing
an explicit changelog file path for tests and ad-hoc package audits.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable, cast

CHANGELOG_HEADER = re.compile(
    r"^(?P<package>[\w.+-]+) \((?P<version>[^)]+)\) (?P<distribution>[^;]+); urgency=(?P<urgency>\S+)"
)
SECURITY_RE = re.compile(r"\b(CVE-\d{4}-\d{4,}|security|vulnerab|exploit|privilege|auth)\b", re.I)
BULLET_RE = re.compile(r"^\s{2,}[*-]\s?(?P<text>.*)$")
MAINTAINER_RE = re.compile(r"^ -- (?P<maintainer>.+?)\s{2,}(?P<date>.+)$")


@dataclass(frozen=True)
class ChangelogEntry:
    """Structured representation of one Debian changelog release block."""

    package: str
    version: str
    distribution: str
    urgency: str
    changes: tuple[str, ...]
    maintainer: str = ""
    date: str = ""

    @property
    def has_security_fix(self) -> bool:
        """Return whether any recorded change looks security-related."""
        return any(SECURITY_RE.search(change) for change in self.changes)


def repo_root() -> Path:
    """Return the repository root relative to this helper script."""
    return Path(__file__).resolve().parents[1]


def default_changelog_path(package: str, root: Path | None = None) -> Path:
    """Build the conventional local Debian changelog path for a package."""
    base = root or repo_root()
    return base / "packages" / package / "debian" / "changelog"


def parse_changelog(text: str) -> list[ChangelogEntry]:
    """Parse Debian changelog text into newest-first structured entries."""
    entries: list[ChangelogEntry] = []
    current: dict[str, object] | None = None
    changes: list[str] = []

    def flush() -> None:
        """Persist the current changelog block and reset parser state."""
        nonlocal current, changes
        if not current:
            return
        entries.append(
            ChangelogEntry(
                package=str(current["package"]),
                version=str(current["version"]),
                distribution=str(current["distribution"]),
                urgency=str(current["urgency"]),
                changes=tuple(changes),
                maintainer=str(current.get("maintainer", "")),
                date=str(current.get("date", "")),
            )
        )
        current = None
        changes = []

    for raw_line in text.splitlines():
        header = CHANGELOG_HEADER.match(raw_line)
        if header:
            flush()
            current = cast(dict[str, object], header.groupdict())
            continue
        if current is None:
            continue
        maintainer = MAINTAINER_RE.match(raw_line)
        if maintainer:
            current.update(maintainer.groupdict())
            flush()
            continue
        bullet = BULLET_RE.match(raw_line)
        if bullet:
            changes.append(bullet.group("text").strip())
        elif changes and raw_line.startswith("    "):
            changes[-1] = f"{changes[-1]} {raw_line.strip()}".strip()
    flush()
    return entries


def load_entries(package: str | None, changelog: Path | None = None) -> list[ChangelogEntry]:
    """Load changelog entries from an explicit file or package default path."""
    path = changelog or (default_changelog_path(package) if package else None)
    if not path:
        raise ValueError("Either package or changelog file must be specified")
    if not path.exists():
        msg = f"No changelog found for {package!r}: {path}" if package else f"No changelog found: {path}"
        raise FileNotFoundError(msg)
    return parse_changelog(path.read_text(encoding="utf-8"))


def filter_entries(entries: Iterable[ChangelogEntry], query: str | None = None) -> list[ChangelogEntry]:
    """Return entries whose version or change text contains the query."""
    entries = list(entries)
    if not query:
        return entries
    needle = query.lower()
    return [entry for entry in entries if needle in entry.version.lower() or any(needle in change.lower() for change in entry.changes)]


def compare_entries(entries: Iterable[ChangelogEntry], older: str, newer: str) -> list[ChangelogEntry]:
    """Select the contiguous changelog range from newer down to older."""
    materialized = list(entries)
    versions = [entry.version for entry in materialized]
    if older not in versions or newer not in versions:
        raise ValueError(f"compare bounds not found: older={older!r}, newer={newer!r}")

    selected: list[ChangelogEntry] = []
    capture = False
    for entry in materialized:
        if entry.version == newer:
            capture = True
        if capture:
            selected.append(entry)
        if entry.version == older:
            break
    if not selected or selected[-1].version != older:
        raise ValueError(f"newer version {newer!r} must appear before older version {older!r}")
    return selected


def format_entries(entries: Iterable[ChangelogEntry]) -> str:
    """Render changelog entries as readable CLI output with security markers."""
    lines: list[str] = []
    for entry in entries:
        marker = "🔐 " if entry.has_security_fix else ""
        lines.append(f"{marker}{entry.package} {entry.version} ({entry.date or entry.distribution})")
        for change in entry.changes or ("No bullet items recorded.",):
            prefix = "   🔐 Security:" if SECURITY_RE.search(change) else "   -"
            lines.append(f"{prefix} {change}")
        lines.append("")
    return "\n".join(lines).rstrip()


def export_entries(entries: Iterable[ChangelogEntry], output: Path) -> None:
    """Write entries to JSON, including computed security-fix metadata."""
    data = []
    for entry in entries:
        item = asdict(entry)
        item["has_security_fix"] = entry.has_security_fix
        data.append(item)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def build_parser() -> argparse.ArgumentParser:
    """Create the changelog viewer command-line parser."""
    parser = argparse.ArgumentParser(description="View/search package changelogs")
    parser.add_argument("package", nargs="?", help="package directory name under packages/")
    parser.add_argument("older", nargs="?", help="older version for compare mode")
    parser.add_argument("newer", nargs="?", help="newer version for compare mode")
    parser.add_argument("--file", type=Path, help="read a specific changelog file")
    parser.add_argument("--search", help="filter changes by text or version")
    parser.add_argument("--security", action="store_true", help="show only entries with security-related changes")
    parser.add_argument("--export", type=Path, help="write selected entries as JSON")
    return parser


def main(argv: list[str] | None = None) -> int:
    """Run the changelog viewer CLI and return a process exit code."""
    args = build_parser().parse_args(argv)
    if not args.package and not args.file:
        build_parser().error("Either package or --file must be specified.")
    try:
        entries = load_entries(args.package, args.file)
    except FileNotFoundError as exc:
        print(exc, file=sys.stderr)
        return 2

    if args.older or args.newer:
        if not (args.older and args.newer):
            print("compare mode requires both older and newer versions", file=sys.stderr)
            return 2
        try:
            entries = compare_entries(entries, args.older, args.newer)
        except ValueError as exc:
            print(exc, file=sys.stderr)
            return 2

    entries = filter_entries(entries, args.search)
    if args.security:
        entries = [entry for entry in entries if entry.has_security_fix]

    if args.export:
        try:
            export_entries(entries, args.export)
        except OSError as exc:
            print(f"failed to export JSON: {exc}", file=sys.stderr)
            return 2

    output = format_entries(entries)
    if output:
        print(output)
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
