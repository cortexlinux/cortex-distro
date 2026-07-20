#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

INDEX="$TMP_DIR/Packages"
GZ_INDEX="$TMP_DIR/Packages.gz"

cat > "$INDEX" <<'EOF'
Package: cx-demo
Version: 1.0
Installed-Size: 30
Depends: heavy-runtime | tiny-runtime, shared-lib
Description: demo application

Package: heavy-runtime
Version: 1.0
Installed-Size: 800
Description: large runtime

Package: tiny-runtime
Version: 1.0
Installed-Size: 45
Provides: runtime-virtual
Description: compact runtime

Package: shared-lib
Version: 2.0
Installed-Size: 10
Description: shared library

Package: conflict-tool
Version: 1.0
Installed-Size: 5
Conflicts: shared-lib
Description: package that conflicts with the shared library

Package: virtual-consumer
Version: 1.0
Installed-Size: 20
Depends: runtime-virtual
Description: virtual package consumer
EOF

gzip -c "$INDEX" > "$GZ_INDEX"

assert_contains() {
    local haystack="$1"
    local needle="$2"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "Expected output to contain: $needle" >&2
        echo "$haystack" >&2
        exit 1
    fi
}

run_optimizer() {
    "$ROOT_DIR/apt/scripts/optimize-dependency-tree.py" --index "$INDEX" "$@"
}

output="$(run_optimizer cx-demo)"
assert_contains "$output" "Selected packages: 3"
assert_contains "$output" "Total Installed-Size: 85 KiB"
assert_contains "$output" "tiny-runtime 1.0"
if [[ "$output" == *"heavy-runtime 1.0"* ]]; then
    echo "Expected optimizer to choose tiny-runtime instead of heavy-runtime" >&2
    echo "$output" >&2
    exit 1
fi
assert_contains "$output" "Missing dependencies: none"
assert_contains "$output" "Conflicts: none"

output="$(run_optimizer --dot cx-demo)"
assert_contains "$output" "digraph dependencies"
assert_contains "$output" "\"cx-demo\" -> \"tiny-runtime\""

output="$(run_optimizer virtual-consumer)"
assert_contains "$output" "virtual-consumer 1.0"
assert_contains "$output" "tiny-runtime 1.0"

output="$(run_optimizer runtime-virtual)"
assert_contains "$output" "- tiny-runtime"
assert_contains "$output" "Total Installed-Size: 45 KiB"

if run_optimizer cx-demo conflict-tool > "$TMP_DIR/conflict.out" 2>&1; then
    echo "Expected conflicting plan to fail" >&2
    cat "$TMP_DIR/conflict.out" >&2
    exit 1
fi
assert_contains "$(cat "$TMP_DIR/conflict.out")" "conflict-tool conflicts with shared-lib"

if run_optimizer missing-package > "$TMP_DIR/missing.out" 2>&1; then
    echo "Expected missing dependency plan to fail" >&2
    cat "$TMP_DIR/missing.out" >&2
    exit 1
fi
assert_contains "$(cat "$TMP_DIR/missing.out")" "Missing dependencies:"

output="$("$ROOT_DIR/apt/scripts/optimize-dependency-tree.py" --index "$GZ_INDEX" cx-demo)"
assert_contains "$output" "Total Installed-Size: 85 KiB"

echo "optimize-dependency-tree-test.sh: all assertions passed"
