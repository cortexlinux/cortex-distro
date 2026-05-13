#!/bin/bash
# Tests for apt/scripts/verify-integrity.sh.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/apt/scripts/verify-integrity.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

assert_success() {
    local name="$1"
    shift

    if "$@" >"$TMP_DIR/${name}.out" 2>"$TMP_DIR/${name}.err"; then
        printf 'PASS %s\n' "$name"
    else
        printf 'FAIL %s\n' "$name" >&2
        cat "$TMP_DIR/${name}.out" >&2 || true
        cat "$TMP_DIR/${name}.err" >&2 || true
        exit 1
    fi
}

assert_failure() {
    local name="$1"
    shift

    if "$@" >"$TMP_DIR/${name}.out" 2>"$TMP_DIR/${name}.err"; then
        printf 'FAIL %s unexpectedly succeeded\n' "$name" >&2
        cat "$TMP_DIR/${name}.out" >&2 || true
        exit 1
    else
        printf 'PASS %s\n' "$name"
    fi
}

build_fixture() {
    local fixture="$1"

    mkdir -p "$fixture/dists/stable/main/binary-amd64"
    mkdir -p "$fixture/pool/main/c/cx"

    printf 'package payload\n' > "$fixture/pool/main/c/cx/cx-test_1.0.0_all.deb"
    local checksum
    checksum="$(sha256sum "$fixture/pool/main/c/cx/cx-test_1.0.0_all.deb" | awk '{print $1}')"

    cat > "$fixture/dists/stable/main/binary-amd64/Packages" <<EOF
Package: cx-test
Version: 1.0.0
Architecture: all
Filename: pool/main/c/cx/cx-test_1.0.0_all.deb
SHA256: $checksum

EOF

    cat > "$fixture/dists/stable/Release" <<'EOF'
Origin: repo.cxlinux.com
Label: CX Linux
Suite: stable
Codename: stable
Architectures: amd64
Components: main
EOF
}

GOOD_REPO="$TMP_DIR/good"
BAD_REPO="$TMP_DIR/bad"
MISSING_REPO="$TMP_DIR/missing"

build_fixture "$GOOD_REPO"
cp -R "$GOOD_REPO" "$BAD_REPO"
cp -R "$GOOD_REPO" "$MISSING_REPO"

printf 'tampered payload\n' > "$BAD_REPO/pool/main/c/cx/cx-test_1.0.0_all.deb"
rm "$MISSING_REPO/pool/main/c/cx/cx-test_1.0.0_all.deb"

assert_success "valid-checksum" "$SCRIPT" "$GOOD_REPO"
assert_failure "tampered-package" "$SCRIPT" "$BAD_REPO"
assert_failure "missing-package" "$SCRIPT" "$MISSING_REPO"
