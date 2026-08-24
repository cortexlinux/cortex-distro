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

Package: no-description
Version: 1.0
Installed-Size: 3

Package: tab-dep-root
Version: 1.0
Installed-Size: 4
Depends:
	shared-lib
Description: dependency continued with a tab

Package: renamed-self
Version: 1.0
Installed-Size: 12
Provides: old-self
Conflicts: old-self
Description: package that conflicts only with its own virtual package

Package: renamed-tool
Version: 1.0
Installed-Size: 100
Provides: old-tool
Description: larger obsolete provider

Package: renamed-tool
Version: 2.0
Installed-Size: 10
Description: smaller replacement that no longer provides old-tool

Package: diamond-root
Version: 1.0
Installed-Size: 1
Depends: diamond-left, diamond-right
Description: root with shared transitive dependency

Package: diamond-left
Version: 1.0
Installed-Size: 1
Depends: diamond-shared
Description: left dependency

Package: diamond-right
Version: 1.0
Installed-Size: 1
Depends: diamond-shared
Description: right dependency

Package: diamond-shared
Version: 1.0
Installed-Size: 1
Description: shared dependency

Package: versioned-root
Version: 1.0
Installed-Size: 1
Depends: versioned-lib (>= 2.0)
Description: package requiring a newer direct dependency

Package: versioned-lib
Version: 1.0
Installed-Size: 1
Description: incompatible older direct dependency

Package: versioned-lib
Version: 2.0
Installed-Size: 20
Description: compatible newer direct dependency

Package: ordered-version-root
Version: 1.0
Installed-Size: 1
Depends: ordered-version-lib (>= 2.0)
Description: package requiring a newer direct dependency listed before an older one

Package: ordered-version-lib
Version: 2.0
Installed-Size: 20
Description: compatible direct dependency listed first

Package: ordered-version-lib
Version: 1.0
Installed-Size: 1
Description: incompatible older direct dependency listed last

Package: virtual-version-root
Version: 1.0
Installed-Size: 1
Depends: virtual-api (>= 2.0)
Description: package requiring a versioned virtual dependency

Package: provider-old
Version: 1.0
Installed-Size: 1
Provides: virtual-api (= 1.0)
Description: incompatible virtual provider

Package: provider-new
Version: 1.0
Installed-Size: 20
Provides: virtual-api (= 2.0)
Description: compatible virtual provider

Package: same-provider-root
Version: 1.0
Installed-Size: 1
Depends: same-virtual (>= 2.0)
Description: package requiring a virtual dependency provided by a later version

Package: same-provider
Version: 1.0
Installed-Size: 1
Description: smaller same-name package without the virtual provide

Package: same-provider
Version: 2.0
Installed-Size: 20
Provides: same-virtual (= 2.0)
Description: larger same-name package with the versioned virtual provide

Package: duplicate-alt-root
Version: 1.0
Installed-Size: 1
Depends: shared-lib | shared-lib
Description: root with duplicate alternatives

Package: digit-letter-root
Version: 1.0
Installed-Size: 1
Depends: digit-letter-lib (<< 1.a)
Description: root with a dependency that compares digits against non-digits

Package: digit-letter-lib
Version: 1.2
Installed-Size: 1
Description: version whose digit segment sorts before the letter segment

Package: digit-letter-lib
Version: 1.a
Installed-Size: 20
Description: version whose letter segment sorts after the digit segment

Package: marginal-root
Version: 1.0
Installed-Size: 1
Depends: shared-parent, shared-runtime | tiny-alt
Description: root with sibling dependencies sharing a runtime

Package: shared-parent
Version: 1.0
Installed-Size: 1
Depends: shared-runtime
Description: parent that already pulls the shared runtime

Package: shared-runtime
Version: 1.0
Installed-Size: 100
Description: large runtime shared by siblings

Package: tiny-alt
Version: 1.0
Installed-Size: 60
Description: smaller standalone alternative before deduplication
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

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "Expected output not to contain: $needle" >&2
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

output="$(run_optimizer no-description)"
assert_contains "$output" "Selected packages: 1"
assert_contains "$output" "no-description 1.0"

output="$(run_optimizer tab-dep-root)"
assert_contains "$output" "Selected packages: 2"
assert_contains "$output" "shared-lib 2.0"

output="$(run_optimizer renamed-self)"
assert_contains "$output" "renamed-self 1.0"
assert_contains "$output" "Conflicts: none"

if run_optimizer old-tool > "$TMP_DIR/stale-provider.out" 2>&1; then
    echo "Expected stale virtual provider lookup to fail" >&2
    cat "$TMP_DIR/stale-provider.out" >&2
    exit 1
fi
assert_contains "$(cat "$TMP_DIR/stale-provider.out")" "Missing dependencies:"

output="$(run_optimizer diamond-root)"
assert_contains "$output" "diamond-shared 1.0"
assert_not_contains "$output" "(cycle skipped)"

output="$(run_optimizer versioned-root)"
assert_contains "$output" "versioned-lib 2.0"
assert_not_contains "$output" "versioned-lib 1.0"

output="$(run_optimizer ordered-version-root)"
assert_contains "$output" "ordered-version-lib 2.0"
assert_not_contains "$output" "ordered-version-lib 1.0"

output="$(run_optimizer virtual-version-root)"
assert_contains "$output" "provider-new 1.0"
assert_not_contains "$output" "provider-old 1.0"

output="$(run_optimizer same-provider-root)"
assert_contains "$output" "same-provider 2.0"
assert_not_contains "$output" "same-provider 1.0"

output="$(run_optimizer duplicate-alt-root)"
assert_contains "$output" "shared-lib 2.0"

output="$(run_optimizer digit-letter-root)"
assert_contains "$output" "digit-letter-lib 1.2"
assert_not_contains "$output" "digit-letter-lib 1.a"

output="$(run_optimizer marginal-root)"
assert_contains "$output" "Total Installed-Size: 102 KiB"
assert_contains "$output" "shared-runtime 1.0"
assert_not_contains "$output" "tiny-alt 1.0"

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
