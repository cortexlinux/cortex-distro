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
UNSAFE_REPO="$TMP_DIR/unsafe"
SIGNED_REPO="$TMP_DIR/signed"
BAD_SIGNATURE_REPO="$TMP_DIR/bad-signature"
ARMORED_KEY="$TMP_DIR/integrity-test.asc"

build_fixture "$GOOD_REPO"
cp -R "$GOOD_REPO" "$BAD_REPO"
cp -R "$GOOD_REPO" "$MISSING_REPO"
cp -R "$GOOD_REPO" "$UNSAFE_REPO"
cp -R "$GOOD_REPO" "$SIGNED_REPO"
cp -R "$GOOD_REPO" "$BAD_SIGNATURE_REPO"

printf 'tampered payload\n' > "$BAD_REPO/pool/main/c/cx/cx-test_1.0.0_all.deb"
rm "$MISSING_REPO/pool/main/c/cx/cx-test_1.0.0_all.deb"
cat > "$UNSAFE_REPO/dists/stable/main/binary-amd64/Packages" <<'EOF'
Package: cx-malicious
Version: 1.0.0
Architecture: all
Filename: ../../../../etc/passwd
SHA256: 0000000000000000000000000000000000000000000000000000000000000000

EOF

if command -v gpg >/dev/null 2>&1 && command -v gpgv >/dev/null 2>&1; then
    GNUPGHOME="$TMP_DIR/gnupg"
    export GNUPGHOME
    mkdir -p "$GNUPGHOME"
    chmod 700 "$GNUPGHOME"

    cat > "$TMP_DIR/gpg-batch" <<'EOF'
%no-protection
Key-Type: RSA
Key-Length: 2048
Name-Real: CX Integrity Test
Name-Email: integrity-test@example.invalid
Expire-Date: 0
%commit
EOF

    gpg --batch --generate-key "$TMP_DIR/gpg-batch" >/dev/null 2>&1
    gpg --batch --armor --export integrity-test@example.invalid > "$ARMORED_KEY"
    gpg --batch --yes --armor --detach-sign \
        --output "$SIGNED_REPO/dists/stable/Release.gpg" \
        "$SIGNED_REPO/dists/stable/Release" >/dev/null 2>&1
    cp "$SIGNED_REPO/dists/stable/Release.gpg" "$BAD_SIGNATURE_REPO/dists/stable/Release.gpg"
    printf '\nTampered: yes\n' >> "$BAD_SIGNATURE_REPO/dists/stable/Release"
else
    printf 'SKIP signature fixtures require gpg and gpgv\n'
fi

assert_success "valid-checksum" "$SCRIPT" "$GOOD_REPO"
assert_failure "tampered-package" "$SCRIPT" "$BAD_REPO"
assert_failure "missing-package" "$SCRIPT" "$MISSING_REPO"
assert_failure "unsafe-path-rejected" "$SCRIPT" "$UNSAFE_REPO"
assert_failure "missing-keyring" "$SCRIPT" --keyring "$TMP_DIR/missing.gpg" "$GOOD_REPO"
if [[ -f "$ARMORED_KEY" ]]; then
    assert_success "valid-signature-armored-key" "$SCRIPT" --keyring "$ARMORED_KEY" "$SIGNED_REPO"
    assert_failure "bad-signature-rejected" "$SCRIPT" --keyring "$ARMORED_KEY" "$BAD_SIGNATURE_REPO"
fi
