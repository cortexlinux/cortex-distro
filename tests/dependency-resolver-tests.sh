#!/usr/bin/env bash
# CX Linux dependency resolver tests
# SPDX-License-Identifier: BUSL-1.1

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

write_mock_tools() {
    cat >"$TMP_DIR/apt-cache" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
    policy)
        if [[ "$2" == "missing-package" ]]; then
            echo "  Candidate: (none)"
        else
            echo "  Candidate: 1.0"
        fi
        ;;
    depends)
        case "$2" in
            cx-demo)
                echo "  Depends: libc6"
                echo "  Depends: curl"
                ;;
            libc6|curl)
                ;;
        esac
        ;;
    show)
        if [[ "$2" == "cx-demo" ]]; then
            echo "Provides: cx-demo-virtual, demo-runner"
        fi
        ;;
    search)
        echo "cx-demo-tools - demo helper tools"
        ;;
esac
MOCK

    cat >"$TMP_DIR/apt-get" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"danger-package"* ]]; then
    echo "The following packages will be REMOVED:"
    echo "  important-package"
    echo "Remv important-package [1.0]"
    exit 0
fi
echo "The following NEW packages will be installed:"
echo "  cx-demo libc6 curl"
echo "Inst cx-demo (1.0 local [all])"
echo "Conf cx-demo (1.0 local [all])"
MOCK

    cat >"$TMP_DIR/apt-mark" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "libc6"
echo "curl"
MOCK

    cat >"$TMP_DIR/dpkg-query" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "ii "
MOCK

    chmod +x "$TMP_DIR/apt-cache" "$TMP_DIR/apt-get" "$TMP_DIR/apt-mark" "$TMP_DIR/dpkg-query"
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

write_mock_tools

output="$(
    PATH="$TMP_DIR:$PATH" \
    APT_GET_BIN="$TMP_DIR/apt-get" \
    APT_CACHE_BIN="$TMP_DIR/apt-cache" \
    APT_MARK_BIN="$TMP_DIR/apt-mark" \
    DPKG_QUERY_BIN="$TMP_DIR/dpkg-query" \
    "$ROOT_DIR/scripts/cx-dep-resolver.sh" --no-color cx-demo
)"

assert_contains "$output" "Dependency tree:"
assert_contains "$output" "- cx-demo"
assert_contains "$output" "APT simulation produced an install plan without removals"
assert_contains "$output" "Alternatives/provided names for cx-demo"
assert_contains "$output" "Automatically installed packages to review"

if PATH="$TMP_DIR:$PATH" \
    APT_GET_BIN="$TMP_DIR/apt-get" \
    APT_CACHE_BIN="$TMP_DIR/apt-cache" \
    APT_MARK_BIN="$TMP_DIR/apt-mark" \
    DPKG_QUERY_BIN="$TMP_DIR/dpkg-query" \
    "$ROOT_DIR/scripts/cx-dep-resolver.sh" --no-color danger-package >"$TMP_DIR/cx-dep-danger.log" 2>&1; then
    echo "Expected resolver to fail when apt simulation removes packages" >&2
    cat "$TMP_DIR/cx-dep-danger.log" >&2
    exit 1
fi

if PATH="$TMP_DIR:$PATH" \
    APT_GET_BIN="$TMP_DIR/apt-get" \
    APT_CACHE_BIN="$TMP_DIR/apt-cache" \
    APT_MARK_BIN="$TMP_DIR/apt-mark" \
    DPKG_QUERY_BIN="$TMP_DIR/dpkg-query" \
    "$ROOT_DIR/scripts/cx-dep-resolver.sh" --no-color missing-package >"$TMP_DIR/cx-dep-missing.log" 2>&1; then
    echo "Expected resolver to fail when no candidate exists" >&2
    cat "$TMP_DIR/cx-dep-missing.log" >&2
    exit 1
fi

echo "dependency resolver tests passed"
