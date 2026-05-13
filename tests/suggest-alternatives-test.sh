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
gzip -c "$INDEX" > "$INDEX.gz"

run_suggest() {
    "$ROOT_DIR/apt/scripts/suggest-alternatives.py" --index "$INDEX" "$@"
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

output="$(run_suggest apache-server)"
assert_contains "$output" "Package 'apache-server' was not found."
assert_contains "$output" "apache2"
assert_contains "$output" "nginx"
assert_contains "$output" "compatibility=recommended"

output="$(run_suggest postgresql)"
assert_contains "$output" "Package 'postgresql' is available"

output="$(run_suggest hardening)"
assert_contains "$output" "cx-secops"
assert_contains "$output" "security alternative"

output="$("$ROOT_DIR/apt/scripts/suggest-alternatives.py" --index "$INDEX.gz" cuda)"
assert_contains "$output" "cx-gpu-nvidia"

json_output="$("$ROOT_DIR/apt/scripts/suggest-alternatives.py" --index "$INDEX" --json apache-server)"
assert_contains "$json_output" '"available": false'
assert_contains "$json_output" '"package": "apache2"'
python3 -m json.tool <<< "$json_output" > /dev/null

output="$(run_suggest no-such-package)"
assert_contains "$output" "No close alternatives found"

if "$ROOT_DIR/apt/scripts/suggest-alternatives.py" --index "$TMP_DIR/missing" apache-server 2> "$TMP_DIR/missing.err"; then
    echo "Expected missing index to fail" >&2
    exit 1
fi
assert_contains "$(cat "$TMP_DIR/missing.err")" "package index not found"

echo "suggest-alternatives-test.sh: all assertions passed"
