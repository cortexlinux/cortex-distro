#!/bin/bash
# verify-integrity.sh - Verify CX Linux APT repository package integrity
#
# Checks repository metadata signatures and validates package checksums from
# Packages indexes without installing or executing package contents.
#
# Usage:
#   ./apt/scripts/verify-integrity.sh [repo-root]
#   ./apt/scripts/verify-integrity.sh --keyring /path/to/pub.gpg [repo-root]
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

KEYRING=""
REPO_ROOT=""

usage() {
    cat <<'EOF'
Usage: verify-integrity.sh [--keyring KEYRING] [REPO_ROOT]

Verify a CX Linux APT repository:
  - Release.gpg detached signatures when a keyring is supplied
  - InRelease clearsigned metadata when a keyring is supplied
  - SHA256 checksums listed in Packages and Packages.gz indexes
  - Missing or tampered .deb files referenced by package indexes

Arguments:
  REPO_ROOT          Repository root containing dists/ and pool/.
                     Defaults to the parent of this script's directory.

Options:
  --keyring PATH     Public GPG keyring or armored key used for signature checks.
  -h, --help         Show this help text.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keyring)
            if [[ $# -lt 2 ]]; then
                echo "Error: --keyring requires a path" >&2
                exit 2
            fi
            KEYRING="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Error: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [[ -n "$REPO_ROOT" ]]; then
                echo "Error: multiple repository roots provided" >&2
                exit 2
            fi
            REPO_ROOT="$1"
            shift
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

if [[ ! -d "$REPO_ROOT" ]]; then
    echo "Error: repository root does not exist: $REPO_ROOT" >&2
    exit 2
fi

DISTS_DIR="$REPO_ROOT/dists"
POOL_DIR="$REPO_ROOT/pool"

if [[ ! -d "$DISTS_DIR" ]]; then
    echo "Error: missing dists directory: $DISTS_DIR" >&2
    exit 2
fi

PASS=0
FAIL=0
WARN=0

pass() {
    printf 'PASS %s\n' "$1"
    PASS=$((PASS + 1))
}

fail() {
    printf 'FAIL %s\n' "$1" >&2
    FAIL=$((FAIL + 1))
}

warn() {
    printf 'WARN %s\n' "$1" >&2
    WARN=$((WARN + 1))
}

verify_signature() {
    local release_file="$1"
    local dist_dir
    dist_dir="$(dirname "$release_file")"

    if [[ -z "$KEYRING" ]]; then
        warn "signature checks skipped for ${release_file#$REPO_ROOT/}; no --keyring supplied"
        return
    fi

    if [[ ! -f "$KEYRING" ]]; then
        fail "keyring not found: $KEYRING"
        return
    fi

    if [[ -f "$dist_dir/Release.gpg" ]]; then
        if gpgv --keyring "$KEYRING" "$dist_dir/Release.gpg" "$release_file" >/dev/null 2>&1; then
            pass "detached signature valid: ${dist_dir#$REPO_ROOT/}/Release.gpg"
        else
            fail "detached signature invalid: ${dist_dir#$REPO_ROOT/}/Release.gpg"
        fi
    else
        warn "missing detached signature: ${dist_dir#$REPO_ROOT/}/Release.gpg"
    fi

    if [[ -f "$dist_dir/InRelease" ]]; then
        if gpgv --keyring "$KEYRING" "$dist_dir/InRelease" >/dev/null 2>&1; then
            pass "clearsigned metadata valid: ${dist_dir#$REPO_ROOT/}/InRelease"
        else
            fail "clearsigned metadata invalid: ${dist_dir#$REPO_ROOT/}/InRelease"
        fi
    else
        warn "missing clearsigned metadata: ${dist_dir#$REPO_ROOT/}/InRelease"
    fi
}

packages_stream() {
    local package_index="$1"

    case "$package_index" in
        *.gz) gzip -cd "$package_index" ;;
        *) cat "$package_index" ;;
    esac
}

verify_packages_index() {
    local package_index="$1"
    local index_dir filename sha256 package_path actual

    index_dir="$(dirname "$package_index")"

    while IFS=$'\t' read -r filename sha256; do
        if [[ -z "$filename" || -z "$sha256" ]]; then
            continue
        fi

        if [[ "$filename" = /* || "$filename" == *".."* ]]; then
            fail "unsafe package path in ${package_index#$REPO_ROOT/}: $filename"
            continue
        fi

        package_path="$REPO_ROOT/$filename"
        if [[ ! -f "$package_path" ]]; then
            fail "missing package referenced by ${package_index#$REPO_ROOT/}: $filename"
            continue
        fi

        actual="$(sha256sum "$package_path" | awk '{print $1}')"
        if [[ "$actual" == "$sha256" ]]; then
            pass "checksum valid: $filename"
        else
            fail "checksum mismatch: $filename expected $sha256 got $actual"
        fi
    done < <(packages_stream "$package_index" | awk '
        /^Filename: / { filename=$2 }
        /^SHA256: / { sha256=$2 }
        /^$/ {
            if (filename != "" && sha256 != "") {
                print filename "\t" sha256
            }
            filename=""
            sha256=""
        }
        END {
            if (filename != "" && sha256 != "") {
                print filename "\t" sha256
            }
        }
    ')

    pass "parsed package index: ${package_index#$REPO_ROOT/}"

    if [[ ! -d "$POOL_DIR" ]]; then
        warn "pool directory missing while package index exists: ${index_dir#$REPO_ROOT/}"
    fi
}

while IFS= read -r release_file; do
    verify_signature "$release_file"
done < <(find "$DISTS_DIR" -type f -name Release | sort)

package_indexes_found=0
while IFS= read -r package_index; do
    package_indexes_found=$((package_indexes_found + 1))
    verify_packages_index "$package_index"
done < <(find "$DISTS_DIR" -type f \( -name Packages -o -name Packages.gz \) | sort)

if [[ "$package_indexes_found" -eq 0 ]]; then
    warn "no package indexes found under ${DISTS_DIR#$REPO_ROOT/}"
fi

printf '\nIntegrity report: %d passed, %d warnings, %d failed\n' "$PASS" "$WARN" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
