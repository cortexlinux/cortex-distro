#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

INDEX="$TMP_DIR/Packages"

cat > "$INDEX" <<'EOF'
Package: nginx
Version: 1.24.0-1
Description: small, powerful, scalable web server

Package: apache2
Version: 2.4.58-1
Description: Apache HTTP server

Package: postgresql
Version: 16+257
Description: object-relational SQL database

Package: cx-secops
Version: 0.1.0-1
Description: CX Linux security hardening and sandbox tools

Package: cx-gpu-nvidia
Version: 0.1.0-1
Description: NVIDIA GPU runtime helpers for CX Linux
EOF

run_search() {
    "$ROOT_DIR/apt/scripts/search-packages.py" --index "$INDEX" "$@"
}

assert_contains() {
    local haystack="$1"
    local needle="$2"

    if [[ "$haystack" != *"$needle"* ]]; then
        echo "Expected output to contain: $needle" >&2
        echo "$haystack" >&2
        exit 1
    fi
}

output="$(run_search postgress)"
assert_contains "$output" "postgresql"
assert_contains "$output" "fuzzy"

output="$(run_search "web server")"
assert_contains "$output" "nginx"
assert_contains "$output" "apache2"

output="$(run_search "graphics card")"
assert_contains "$output" "cx-gpu-nvidia"

output="$(run_search hardening)"
assert_contains "$output" "cx-secops"

output="$(run_search "not-a-real-package")"
assert_contains "$output" "No matching packages found."

if "$ROOT_DIR/apt/scripts/search-packages.py" --index "$TMP_DIR/missing" postgresql 2> "$TMP_DIR/missing.err"; then
    echo "Expected missing index to fail" >&2
    exit 1
fi
assert_contains "$(cat "$TMP_DIR/missing.err")" "package index not found"

echo "search-packages-test.sh: all assertions passed"
