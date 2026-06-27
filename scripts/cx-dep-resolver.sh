#!/usr/bin/env bash
# CX Linux dependency conflict resolver
# SPDX-License-Identifier: BUSL-1.1

set -euo pipefail

APT_GET_BIN="${APT_GET_BIN:-apt-get}"
APT_CACHE_BIN="${APT_CACHE_BIN:-apt-cache}"
APT_MARK_BIN="${APT_MARK_BIN:-apt-mark}"
DPKG_QUERY_BIN="${DPKG_QUERY_BIN:-dpkg-query}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    cat <<'EOF'
CX Linux dependency conflict resolver

Usage:
  scripts/cx-dep-resolver.sh [OPTIONS] PACKAGE...

Options:
  --tree-depth N     Dependency tree depth to print (default: 2)
  --no-color         Disable ANSI colors
  -h, --help         Show this help

Examples:
  scripts/cx-dep-resolver.sh docker.io
  scripts/cx-dep-resolver.sh --tree-depth 3 python3-pip nodejs

The resolver is read-only: it uses apt simulation and cache metadata. It does
not install, remove, or modify packages.
EOF
}

if [[ "${NO_COLOR:-}" == "1" ]]; then
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

info() { printf "%b[INFO]%b %s\n" "$BLUE" "$NC" "$*"; }
ok() { printf "%b[OK]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
bad() { printf "%b[RISK]%b %s\n" "$RED" "$NC" "$*"; }

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        bad "Required command not found: $1"
        exit 2
    fi
}

normalize_alt() {
    local value="$1"
    value="${value%% (*}"
    value="${value%%:*}"
    value="${value//|/}"
    value="${value//</}"
    value="${value//>/}"
    value="${value## }"
    value="${value%% }"
    printf "%s" "$value"
}

candidate_exists() {
    local package="$1"
    "$APT_CACHE_BIN" policy "$package" 2>/dev/null | awk '/Candidate:/ { found = ($2 && $2 != "(none)"); exit } END { exit !found }'
}

print_dependency_tree() {
    local package="$1"
    local depth="$2"
    local indent="${3:-}"
    local seen="${4:-}"

    printf "%s- %s\n" "$indent" "$package"

    if (( depth <= 0 )); then
        return 0
    fi

    if [[ ",$seen," == *",$package,"* ]]; then
        printf "%s  (cycle skipped)\n" "$indent"
        return 0
    fi

    local dependencies=()
    while read -r dependency; do
        dependencies+=("$dependency")
    done < <("$APT_CACHE_BIN" depends "$package" 2>/dev/null |
        awk '/^[[:space:]]*(PreDepends|Depends):/ {print $2}' |
        sed 's/[<>|]//g' |
        awk 'NF && !seen[$0]++' || true)

    for dependency in "${dependencies[@]}"; do
        print_dependency_tree "$dependency" "$((depth - 1))" "$indent  " "${seen},${package}"
    done
}

print_plain_english_summary() {
    local simulation="$1"
    local removals="$2"
    local held="$3"
    local broken="$4"

    if [[ -n "$broken" ]]; then
        bad "APT cannot compute a clean install plan. Review the broken-package lines below before installing."
        return 0
    fi

    if [[ -n "$removals" ]]; then
        bad "APT would remove existing packages. This is a high-risk install plan."
        return 0
    fi

    if [[ -n "$held" ]]; then
        warn "APT reports held or changed held packages. Manual review is recommended."
        return 0
    fi

    if grep -qE '^Inst ' <<<"$simulation"; then
        ok "APT simulation produced an install plan without removals or broken-package errors."
    else
        ok "No package changes are required, or all requested packages are already installed."
    fi
}

print_alternatives() {
    local package="$1"
    local alternatives

    alternatives=$("$APT_CACHE_BIN" show "$package" 2>/dev/null |
        awk -F': ' '/^Provides:/ {print $2}' |
        tr ',' '\n' |
        while read -r alt; do normalize_alt "$alt"; printf "\n"; done |
        awk 'NF && !seen[$0]++' |
        head -10)

    if [[ -n "$alternatives" ]]; then
        printf "Alternatives/provided names for %s:\n" "$package"
        sed 's/^/  - /' <<<"$alternatives"
        return 0
    fi

    local prefix="${package%%-*}"
    if [[ "$prefix" != "$package" && -n "$prefix" ]]; then
        alternatives=$("$APT_CACHE_BIN" search "^${prefix}" 2>/dev/null |
            awk '{print $1}' |
            grep -Fvx "${package}" |
            head -10 || true)
    fi

    if [[ -n "$alternatives" ]]; then
        printf "Possible alternatives related to %s:\n" "$package"
        sed 's/^/  - /' <<<"$alternatives"
    else
        printf "No obvious alternatives found for %s.\n" "$package"
    fi
}

print_orphan_candidates() {
    local auto_packages
    auto_packages=$("$APT_MARK_BIN" showauto 2>/dev/null | head -30 || true)

    if [[ -z "$auto_packages" ]]; then
        printf "No automatically installed package candidates were reported.\n"
        return 0
    fi

    printf "Automatically installed packages to review before cleanup:\n"
    while read -r package; do
        [[ -z "$package" ]] && continue
        if "$DPKG_QUERY_BIN" -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^ii'; then
            printf "  - %s\n" "$package"
        fi
    done <<<"$auto_packages"
    printf "Run 'sudo apt autoremove --dry-run' for the final orphan-removal plan.\n"
}

tree_depth=2
packages=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tree-depth)
            if [[ $# -lt 2 ]]; then
                bad "Option --tree-depth requires an argument"
                exit 2
            fi
            tree_depth="$2"
            shift 2
            ;;
        --no-color)
            RED=''
            GREEN=''
            YELLOW=''
            BLUE=''
            NC=''
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            bad "Unknown option: $1"
            usage
            exit 2
            ;;
        *)
            packages+=("$1")
            shift
            ;;
    esac
done

if [[ $# -gt 0 ]]; then
    packages+=("$@")
fi

if [[ ${#packages[@]} -eq 0 ]]; then
    usage
    exit 2
fi

if ! [[ "$tree_depth" =~ ^[0-9]+$ ]]; then
    bad "--tree-depth must be a non-negative integer"
    exit 2
fi

require_command "$APT_GET_BIN"
require_command "$APT_CACHE_BIN"
require_command "$APT_MARK_BIN"
require_command "$DPKG_QUERY_BIN"

info "Resolving dependency plan for: ${packages[*]}"

for package in "${packages[@]}"; do
    if candidate_exists "$package"; then
        ok "Candidate available for $package"
    else
        bad "No install candidate found for $package"
        print_alternatives "$package"
        exit 1
    fi
done

simulation="$("$APT_GET_BIN" -s install "${packages[@]}" 2>&1 || true)"
removals="$(grep -E '^(Remv|The following packages will be REMOVED:)' <<<"$simulation" || true)"
held="$(grep -Ei 'held|kept back|changed held' <<<"$simulation" || true)"
broken="$(grep -Ei 'broken packages|unmet dependencies|conflicts with|but it is not going to be installed|^E:' <<<"$simulation" || true)"

printf "\nDependency tree:\n"
for package in "${packages[@]}"; do
    print_dependency_tree "$package" "$tree_depth"
done

printf "\nAPT simulation summary:\n"
grep -E '^(Inst|Remv|Conf|The following|[0-9]+ upgraded|E:|N:)' <<<"$simulation" || printf "%s\n" "$simulation"

printf "\nPlain-English risk assessment:\n"
print_plain_english_summary "$simulation" "$removals" "$held" "$broken"

printf "\nAlternative package hints:\n"
for package in "${packages[@]}"; do
    print_alternatives "$package"
done

printf "\nOrphan cleanup review:\n"
print_orphan_candidates

if [[ -n "$broken" || -n "$removals" ]]; then
    exit 1
fi
