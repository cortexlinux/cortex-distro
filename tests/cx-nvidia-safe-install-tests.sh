#!/usr/bin/env bash
# Mocked unit tests for cx-nvidia-safe-install.
# Copyright 2026 AI Venture Holdings LLC
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/packages/cx-gpu-nvidia/usr/sbin/cx-nvidia-safe-install"
TEST_ROOT="$(mktemp -d)"
FAKEBIN="$TEST_ROOT/bin"
STATE_DIR="$TEST_ROOT/state"
LOG_FILE="$TEST_ROOT/install.log"
FAKE_APT_LOG="$TEST_ROOT/apt.log"
FAKE_INSTALLED_NEW="$TEST_ROOT/installed-new"
FAKE_TAINT_FILE="$TEST_ROOT/tainted"
PASS=0
FAIL=0

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$FAKEBIN" "$STATE_DIR"

write_fake() {
    local name="$1"
    cat > "$FAKEBIN/$name"
    chmod +x "$FAKEBIN/$name"
}

write_fake nvidia-smi <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-L" ]; then
    echo "GPU 0: NVIDIA RTX 4090 (UUID: GPU-test)"
    exit 0
fi
if [[ "${1:-}" == --query-gpu=* ]]; then
    echo "535.154.05"
    exit 0
fi
if [ "${1:-}" = "-q" ]; then
    echo "Driver Version                      : 535.154.05"
    exit 0
fi
if [ "${FAKE_NVIDIA_SMI_FAIL_EMPTY:-0}" = "1" ]; then
    echo "nvidia-smi validation failure" >&2
    exit 1
fi
echo "NVIDIA-SMI mock ok"
SH

write_fake lspci <<'SH'
#!/usr/bin/env bash
echo "01:00.0 VGA compatible controller [0300]: NVIDIA Corporation AD102 [10de:2684]"
SH

write_fake uname <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-r" ]; then
    echo "6.5.0-generic"
else
    /usr/bin/uname "$@"
fi
SH

write_fake ubuntu-drivers <<'SH'
#!/usr/bin/env bash
cat <<EOF
driver   : nvidia-driver-545 - distro non-free recommended
EOF
SH

write_fake apt-cache <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    policy)
        echo "$2:"
        echo "  Installed: (none)"
        echo "  Candidate: 545.29.06-0ubuntu1"
        ;;
    search)
        echo "nvidia-driver-535 - NVIDIA driver"
        echo "nvidia-driver-545 - NVIDIA driver"
        ;;
esac
SH

write_fake apt-get <<'SH'
#!/usr/bin/env bash
echo "apt-get $*" >> "$FAKE_APT_LOG"
case " $* " in
    *" install "*)
        touch "$FAKE_INSTALLED_NEW"
        ;;
    *" purge "*|*" remove "*)
        rm -f "$FAKE_INSTALLED_NEW"
        ;;
esac
exit 0
SH

write_fake dpkg-query <<'SH'
#!/usr/bin/env bash
if [[ " $* " == *" linux-headers-"* ]]; then
    echo "linux-headers-6.5.0-generic	6.5.0.1	ii "
    exit 0
fi
echo "nvidia-driver-535	535.154.05-0ubuntu1	ii "
echo "libnvidia-compute-535	535.154.05-0ubuntu1	ii "
if [ -f "$FAKE_INSTALLED_NEW" ]; then
    echo "nvidia-driver-545	545.29.06-0ubuntu1	ii "
fi
SH

write_fake dpkg <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--get-selections" ]; then
    echo "nvidia-driver-535	install"
    echo "libnvidia-compute-535	install"
fi
SH

write_fake apt-mark <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    showmanual)
        echo "nvidia-driver-535"
        ;;
    showauto)
        echo "libnvidia-compute-535"
        ;;
    manual)
        echo "apt-mark manual ${2:-}" >> "$FAKE_APT_LOG"
        ;;
esac
SH

write_fake mokutil <<'SH'
#!/usr/bin/env bash
echo "SecureBoot disabled"
SH

write_fake dkms <<'SH'
#!/usr/bin/env bash
echo "nvidia/535.154.05, 6.5.0-generic, x86_64: installed"
SH

write_fake modprobe <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-n" ] && [ "${2:-}" = "nvidia" ]; then
    exit 0
fi
exit 1
SH

write_fake lsmod <<'SH'
#!/usr/bin/env bash
echo "nvidia 123456 0"
SH

write_fake update-initramfs <<'SH'
#!/usr/bin/env bash
echo "update-initramfs $*" >> "$FAKE_APT_LOG"
SH

export PATH="$FAKEBIN:$PATH"
export CX_NVIDIA_STATE_DIR="$STATE_DIR"
export CX_NVIDIA_LOG_FILE="$LOG_FILE"
export CX_NVIDIA_SKIP_ROOT=1
export CX_NVIDIA_TAINT_FILE="$FAKE_TAINT_FILE"
export FAKE_APT_LOG
export FAKE_INSTALLED_NEW

reset_state() {
    rm -rf "$STATE_DIR"
    mkdir -p "$STATE_DIR"
    : > "$FAKE_APT_LOG"
    echo "0" > "$FAKE_TAINT_FILE"
    rm -f "$FAKE_INSTALLED_NEW"
    unset FAKE_NVIDIA_SMI_FAIL_EMPTY || true
}

assert_file() {
    [ -f "$1" ] || {
        echo "missing expected file: $1" >&2
        return 1
    }
}

assert_grep() {
    local pattern="$1"
    local file="$2"
    grep -q "$pattern" "$file" || {
        echo "pattern '$pattern' not found in $file" >&2
        return 1
    }
}

run_case() {
    local name="$1"
    shift
    if "$@"; then
        echo "[PASS] $name"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $name" >&2
        FAIL=$((FAIL + 1))
    fi
}

test_dry_run_install_creates_snapshot() {
    reset_state
    bash "$SCRIPT" install --dry-run --driver nvidia-driver-545 --force --no-update > "$TEST_ROOT/dry-run.out" 2>&1
    assert_file "$STATE_DIR/latest"
    local latest
    latest="$(cat "$STATE_DIR/latest")"
    assert_file "$STATE_DIR/snapshots/$latest/meta.env"
    assert_grep "target_driver=nvidia-driver-545" "$STATE_DIR/snapshots/$latest/meta.env"
    assert_grep "apt-get -s install nvidia-driver-545" "$FAKE_APT_LOG"
}

test_status_reports_latest_snapshot() {
    reset_state
    bash "$SCRIPT" install --dry-run --driver nvidia-driver-545 --force --no-update > /dev/null 2>&1
    bash "$SCRIPT" status > "$TEST_ROOT/status.out" 2>&1
    assert_grep "Latest snapshot:" "$TEST_ROOT/status.out"
    assert_grep "Current driver: 535.154.05" "$TEST_ROOT/status.out"
}

test_validation_failure_triggers_rollback() {
    reset_state
    export FAKE_NVIDIA_SMI_FAIL_EMPTY=1
    if bash "$SCRIPT" install --driver nvidia-driver-545 --force --no-update > "$TEST_ROOT/fail.out" 2>&1; then
        echo "install unexpectedly succeeded" >&2
        return 1
    fi
    assert_grep "apt-get install -y .*nvidia-driver-545" "$FAKE_APT_LOG"
    assert_grep "apt-get purge -y .*nvidia-driver-545" "$FAKE_APT_LOG"
    assert_grep "Validation failed" "$TEST_ROOT/fail.out"
}

test_validate_success() {
    reset_state
    bash "$SCRIPT" validate --skip-opengl > "$TEST_ROOT/validate.out" 2>&1
    assert_grep "nvidia-smi responded successfully" "$TEST_ROOT/validate.out"
}

test_strict_taint_allows_expected_nvidia_bits() {
    reset_state
    echo "4097" > "$FAKE_TAINT_FILE"
    bash "$SCRIPT" validate --strict-taint --skip-opengl > "$TEST_ROOT/strict-taint.out" 2>&1
    assert_grep "only expected NVIDIA" "$TEST_ROOT/strict-taint.out"
}

run_case "dry-run install creates rollback snapshot" test_dry_run_install_creates_snapshot
run_case "status reports latest snapshot" test_status_reports_latest_snapshot
run_case "validation failure triggers rollback" test_validation_failure_triggers_rollback
run_case "validate succeeds with mocked NVIDIA stack" test_validate_success
run_case "strict taint allows expected NVIDIA bits" test_strict_taint_allows_expected_nvidia_bits

echo "Passed: $PASS"
echo "Failed: $FAIL"

[ "$FAIL" -eq 0 ]
