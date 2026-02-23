#!/bin/bash
# CX Linux Installation & Upgrade Tests (P0)
# Run on clean Ubuntu 24.04 / Debian 12 VMs
# Copyright 2025 AI Venture Holdings LLC
# SPDX-License-Identifier: BUSL-1.1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/cx-install-test-$(date +%Y%m%d-%H%M%S).log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
PASS=0
FAIL=0
SKIP=0

# Helper functions
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }
pass() { echo -e "${GREEN}[PASS]${NC} $*" | tee -a "$LOG_FILE"; ((PASS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $*" | tee -a "$LOG_FILE"; ((FAIL++)); }
skip() { echo -e "${YELLOW}[SKIP]${NC} $*" | tee -a "$LOG_FILE"; ((SKIP++)); }
info() { echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$LOG_FILE"; }
section() { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"; echo -e "${BLUE}  $*${NC}" | tee -a "$LOG_FILE"; echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"; }

# Check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        fail "This script must be run as root"
        exit 1
    fi
}

# Detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
        OS_CODENAME="${VERSION_CODENAME:-unknown}"
        info "Detected: $PRETTY_NAME"
    else
        fail "Cannot detect OS"
        exit 1
    fi
}

# Verify clean system (no CX packages installed)
verify_clean_system() {
    section "Verifying Clean System"

    if dpkg -l | grep -q "^ii.*cx"; then
        fail "CX packages already installed - not a clean system"
        dpkg -l | grep cx | tee -a "$LOG_FILE"
        return 1
    else
        pass "System is clean (no CX packages)"
    fi

    if [ -f /etc/apt/sources.list.d/cx.list ]; then
        fail "CX repository already configured"
        return 1
    else
        pass "No existing CX repository"
    fi

    if [ -f /usr/share/keyrings/cx-archive-keyring.gpg ]; then
        fail "CX keyring already installed"
        return 1
    else
        pass "No existing CX keyring"
    fi
}

# Test: Add GPG key
test_add_gpg_key() {
    section "Test: Add GPG Key"

    info "Downloading GPG key from repo.cxlinux.com..."

    if curl -fsSL https://repo.cxlinux.com/key.gpg | gpg --dearmor -o /usr/share/keyrings/cx-archive-keyring.gpg 2>&1 | tee -a "$LOG_FILE"; then
        pass "GPG key downloaded and installed"
    else
        fail "Failed to download/install GPG key"
        return 1
    fi

    # Verify key
    if gpg --no-default-keyring --keyring /usr/share/keyrings/cx-archive-keyring.gpg --list-keys 2>&1 | tee -a "$LOG_FILE"; then
        pass "GPG key is valid"
    else
        fail "GPG key validation failed"
        return 1
    fi
}

# Test: Add APT repository
test_add_repository() {
    section "Test: Add APT Repository"

    local repo_line="deb [signed-by=/usr/share/keyrings/cx-archive-keyring.gpg] https://repo.cxlinux.com/apt stable main"

    echo "$repo_line" > /etc/apt/sources.list.d/cx.list

    if [ -f /etc/apt/sources.list.d/cx.list ]; then
        pass "Repository added to sources.list.d"
    else
        fail "Failed to add repository"
        return 1
    fi

    info "Running apt update..."
    if apt update 2>&1 | tee -a "$LOG_FILE"; then
        pass "apt update succeeded"
    else
        fail "apt update failed"
        return 1
    fi

    # Verify packages are available
    if apt-cache show cx-core 2>&1 | head -20 | tee -a "$LOG_FILE"; then
        pass "cx-core package available in repository"
    else
        fail "cx-core package not found"
        return 1
    fi
}

# Test: Install cx-core (minimal)
test_install_core() {
    section "Test: Install cx-core"

    info "Installing cx-core..."
    if DEBIAN_FRONTEND=noninteractive apt install -y cx-core 2>&1 | tee -a "$LOG_FILE"; then
        pass "cx-core installed successfully"
    else
        fail "Failed to install cx-core"
        return 1
    fi

    # Verify installation
    if dpkg -l | grep -q "^ii.*cx-core"; then
        pass "cx-core shows as installed"
    else
        fail "cx-core not properly installed"
        return 1
    fi

    # Check dependencies
    local deps_missing=0
    for dep in python3 curl gnupg firejail; do
        if command -v "$dep" &>/dev/null; then
            pass "Dependency installed: $dep"
        else
            fail "Missing dependency: $dep"
            ((deps_missing++))
        fi
    done

    if [ $deps_missing -gt 0 ]; then
        fail "$deps_missing dependencies missing"
        return 1
    fi
}

# Test: Install cx-full
test_install_full() {
    section "Test: Install cx-full"

    info "Installing cx-full..."
    if DEBIAN_FRONTEND=noninteractive apt install -y cx-full 2>&1 | tee -a "$LOG_FILE"; then
        pass "cx-full installed successfully"
    else
        fail "Failed to install cx-full"
        return 1
    fi

    # Verify installation
    if dpkg -l | grep -q "^ii.*cx-full"; then
        pass "cx-full shows as installed"
    else
        fail "cx-full not properly installed"
        return 1
    fi

    # Check additional deps
    for dep in docker htop tmux fzf ripgrep; do
        if command -v "$dep" &>/dev/null || dpkg -l | grep -q "^ii.*$dep"; then
            pass "Full package dependency: $dep"
        else
            info "Optional dependency not found: $dep"
        fi
    done
}

# Test: Install GPU packages
test_install_gpu() {
    section "Test: GPU Package Installation"

    # Detect GPU
    local gpu_type="none"
    if lspci 2>/dev/null | grep -qi nvidia; then
        gpu_type="nvidia"
    elif lspci 2>/dev/null | grep -qi "amd\|radeon"; then
        gpu_type="amd"
    fi

    if [ "$gpu_type" = "none" ]; then
        skip "No discrete GPU detected"
        return 0
    fi

    info "Detected GPU type: $gpu_type"

    if [ "$gpu_type" = "nvidia" ]; then
        if apt-cache show cx-gpu-nvidia &>/dev/null; then
            if DEBIAN_FRONTEND=noninteractive apt install -y cx-gpu-nvidia 2>&1 | tee -a "$LOG_FILE"; then
                pass "cx-gpu-nvidia installed"
            else
                fail "Failed to install cx-gpu-nvidia"
                return 1
            fi
        else
            skip "cx-gpu-nvidia not available in repository"
        fi
    elif [ "$gpu_type" = "amd" ]; then
        if apt-cache show cx-gpu-amd &>/dev/null; then
            if DEBIAN_FRONTEND=noninteractive apt install -y cx-gpu-amd 2>&1 | tee -a "$LOG_FILE"; then
                pass "cx-gpu-amd installed"
            else
                fail "Failed to install cx-gpu-amd"
                return 1
            fi
        else
            skip "cx-gpu-amd not available in repository"
        fi
    fi
}

# Test: apt upgrade cycle
test_apt_upgrade() {
    section "Test: APT Update/Upgrade Cycle"

    info "Running apt update..."
    if apt update 2>&1 | tee -a "$LOG_FILE"; then
        pass "apt update succeeded"
    else
        fail "apt update failed"
        return 1
    fi

    # Check for signature verification
    info "Verifying repository signatures..."
    if apt update 2>&1 | grep -i "NO_PUBKEY\|KEYEXPIRED\|REVOKED"; then
        fail "Repository signature issues detected"
        return 1
    else
        pass "Repository signatures valid"
    fi

    # Test upgrade
    info "Running apt upgrade..."
    if DEBIAN_FRONTEND=noninteractive apt upgrade -y 2>&1 | tee -a "$LOG_FILE"; then
        pass "apt upgrade succeeded"
    else
        fail "apt upgrade failed"
        return 1
    fi

    # Check for held packages
    if apt-mark showhold | grep -q cx; then
        info "Some CX packages are held"
        apt-mark showhold | tee -a "$LOG_FILE"
    else
        pass "No CX packages held back"
    fi
}

# Test: Version upgrade (v0.1 -> v0.2)
test_version_upgrade() {
    section "Test: Version Upgrade"

    # Get current version
    local current_version
    current_version=$(dpkg -l cx-core 2>/dev/null | grep "^ii" | awk '{print $3}' || echo "not installed")
    info "Current cx-core version: $current_version"

    # Check for available upgrades
    local available_version
    available_version=$(apt-cache policy cx-core 2>/dev/null | grep "Candidate:" | awk '{print $2}' || echo "unknown")
    info "Available version: $available_version"

    if [ "$current_version" = "$available_version" ]; then
        info "Already on latest version"
        pass "Version check complete (no upgrade needed)"
    else
        info "Upgrade available: $current_version -> $available_version"
        if DEBIAN_FRONTEND=noninteractive apt upgrade -y cx-core 2>&1 | tee -a "$LOG_FILE"; then
            pass "Upgrade succeeded"
        else
            fail "Upgrade failed"
            return 1
        fi
    fi
}

# Test: Uninstall/Purge
test_uninstall() {
    section "Test: Uninstallation"

    # Get list of installed cx packages
    local packages
    packages=$(dpkg -l | grep "^ii.*cx" | awk '{print $2}' | tr '\n' ' ')

    if [ -z "$packages" ]; then
        skip "No CX packages to uninstall"
        return 0
    fi

    info "Packages to remove: $packages"

    # Purge packages
    info "Purging CX packages..."
    # shellcheck disable=SC2086
    if apt purge -y $packages 2>&1 | tee -a "$LOG_FILE"; then
        pass "Packages purged successfully"
    else
        fail "Failed to purge packages"
        return 1
    fi

    # Autoremove dependencies
    if apt autoremove -y 2>&1 | tee -a "$LOG_FILE"; then
        pass "autoremove succeeded"
    fi

    # Check for leftover files
    info "Checking for leftover files..."
    local leftover_files=0

    local paths_to_check=(
        "/etc/cx"
        "/var/lib/cx"
        "/var/log/cx"
        "/usr/local/bin/cx"
        "/usr/share/cx"
        "/opt/cx"
    )

    for path in "${paths_to_check[@]}"; do
        if [ -e "$path" ]; then
            fail "Leftover found: $path"
            ((leftover_files++))
        fi
    done

    if [ $leftover_files -eq 0 ]; then
        pass "No leftover files found"
    else
        fail "$leftover_files leftover paths found"
    fi

    # Check for leftover processes
    if pgrep -f cx &>/dev/null; then
        fail "Leftover CX processes running"
        pgrep -af cx | tee -a "$LOG_FILE"
    else
        pass "No leftover CX processes"
    fi

    # Clean up repository config
    rm -f /etc/apt/sources.list.d/cx.list
    rm -f /usr/share/keyrings/cx-archive-keyring.gpg
    apt update &>/dev/null

    pass "Cleanup complete"
}

# Test: Offline installation (requires ISO)
test_offline_install() {
    section "Test: Offline Installation"

    local iso_path="${1:-}"

    if [ -z "$iso_path" ] || [ ! -f "$iso_path" ]; then
        skip "No ISO file provided for offline test"
        return 0
    fi

    info "Testing offline installation from: $iso_path"

    # Mount ISO
    local mount_point
    mount_point=$(mktemp -d)

    if mount -o loop,ro "$iso_path" "$mount_point" 2>&1 | tee -a "$LOG_FILE"; then
        pass "ISO mounted successfully"
    else
        fail "Failed to mount ISO"
        rmdir "$mount_point"
        return 1
    fi

    # Check for packages
    if [ -d "$mount_point/packages" ]; then
        local pkg_count
        pkg_count=$(find "$mount_point/packages" -name "*.deb" | wc -l)
        info "Found $pkg_count .deb packages"
        pass "Offline packages available"
    else
        fail "No packages directory in ISO"
    fi

    # Check for offline install script
    if [ -x "$mount_point/install.sh" ]; then
        pass "Offline installer script present"
    else
        info "No install.sh in ISO root"
    fi

    umount "$mount_point"
    rmdir "$mount_point"
}

# Summary
print_summary() {
    section "Test Summary"

    echo ""
    echo "Results:"
    echo -e "  ${GREEN}Passed:${NC}  $PASS"
    echo -e "  ${RED}Failed:${NC}  $FAIL"
    echo -e "  ${YELLOW}Skipped:${NC} $SKIP"
    echo ""
    echo "Log file: $LOG_FILE"
    echo ""

    if [ $FAIL -gt 0 ]; then
        echo -e "${RED}OVERALL: FAILED${NC}"
        return 1
    else
        echo -e "${GREEN}OVERALL: PASSED${NC}"
        return 0
    fi
}

# Usage
usage() {
    cat <<EOF
CX Linux Installation Tests (P0)

Usage: $0 [OPTIONS] [TEST...]

Options:
    -h, --help          Show this help
    -o, --offline ISO   Test offline installation with ISO file
    --skip-install      Skip installation tests (for debugging)
    --skip-uninstall    Skip uninstall tests (keep packages)

Tests (run in order):
    clean       Verify clean system
    gpg         Add GPG key
    repo        Add APT repository
    core        Install cx-core
    full        Install cx-full
    gpu         Install GPU packages
    upgrade     Test apt upgrade cycle
    version     Test version upgrade
    uninstall   Test uninstallation

Examples:
    $0                           # Run all tests
    $0 clean gpg repo core       # Run specific tests
    $0 --offline cx-1.0.iso  # Test offline installation
    $0 --skip-uninstall          # Don't uninstall at end

EOF
}

# Main
main() {
    local offline_iso=""
    local skip_install=false
    local skip_uninstall=false
    local specific_tests=()

    # Parse args
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -o|--offline)
                offline_iso="$2"
                shift 2
                ;;
            --skip-install)
                skip_install=true
                shift
                ;;
            --skip-uninstall)
                skip_uninstall=true
                shift
                ;;
            *)
                specific_tests+=("$1")
                shift
                ;;
        esac
    done

    # Header
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║           CX LINUX INSTALLATION TEST SUITE (P0)                       ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo ""

    check_root
    detect_os

    # Determine which tests to run
    if [ ${#specific_tests[@]} -eq 0 ]; then
        # Run all tests
        verify_clean_system || true
        test_add_gpg_key || true
        test_add_repository || true

        if [ "$skip_install" = false ]; then
            test_install_core || true
            test_install_full || true
            test_install_gpu || true
            test_apt_upgrade || true
            test_version_upgrade || true
        fi

        if [ -n "$offline_iso" ]; then
            test_offline_install "$offline_iso" || true
        fi

        if [ "$skip_uninstall" = false ]; then
            test_uninstall || true
        fi
    else
        # Run specific tests
        for test in "${specific_tests[@]}"; do
            case $test in
                clean) verify_clean_system || true ;;
                gpg) test_add_gpg_key || true ;;
                repo) test_add_repository || true ;;
                core) test_install_core || true ;;
                full) test_install_full || true ;;
                gpu) test_install_gpu || true ;;
                upgrade) test_apt_upgrade || true ;;
                version) test_version_upgrade || true ;;
                uninstall) test_uninstall || true ;;
                *) info "Unknown test: $test" ;;
            esac
        done
    fi

    print_summary
}

main "$@"
