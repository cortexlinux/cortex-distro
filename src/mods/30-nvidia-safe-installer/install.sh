#!/bin/bash
# Safe NVIDIA Driver Installer with Rollback
# Implements detection, compatibility check, snapshot, install, validation, rollback
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Constants
SNAPSHOT_DIR="/var/snapshots/nvidia-driver"
LOG_FILE="/var/log/nvidia-safe-install.log"
RETRY_LIMIT=3

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $*"
    exit 1
}

# Detect NVIDIA GPU model
detect_gpu() {
    if ! command -v lspci &>/dev/null; then
        error_exit "lspci command not found"
    fi
    local gpu_info
    gpu_info=$(lspci | grep -i nvidia || true)
    if [[ -z "$gpu_info" ]]; then
        error_exit "No NVIDIA GPU detected"
    fi
    echo "$gpu_info"
}

# Detect current NVIDIA driver version
detect_current_driver() {
    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 || echo "none"
    else
        echo "none"
    fi
}

# Check kernel compatibility for driver version
check_kernel_compatibility() {
    local kernel_version
    kernel_version=$(uname -r)
    # For simplicity, assume all drivers >= 450 support kernels >= 5.4
    # This can be extended with a real compatibility matrix or ubuntu-drivers info
    local recommended_driver_version=$1
    local kernel_major=${kernel_version%%.*}
    local kernel_minor=$(echo "$kernel_version" | cut -d. -f2)
    if (( kernel_major < 5 )) || { (( kernel_major == 5 )) && (( kernel_minor < 4 )); }; then
        log "Warning: Kernel version $kernel_version may not be compatible with NVIDIA driver $recommended_driver_version"
        return 1
    fi
    return 0
}

# Create snapshot before installation
create_snapshot() {
    log "Creating system snapshot at $SNAPSHOT_DIR"
    if ! command -v btrfs &>/dev/null && ! command -v snapper &>/dev/null; then
        log "Warning: No snapshot tool (btrfs or snapper) found, skipping snapshot creation"
        return 0
    fi
    mkdir -p "$SNAPSHOT_DIR"
    # Try btrfs snapshot if root is btrfs
    if mount | grep -q "on / type btrfs"; then
        local snapshot_name="nvidia-driver-$(date +%Y%m%d%H%M%S)"
        btrfs subvolume snapshot / "$SNAPSHOT_DIR/$snapshot_name"
        log "Created btrfs snapshot: $SNAPSHOT_DIR/$snapshot_name"
        return 0
    fi
    # Try snapper snapshot if available
    if command -v snapper &>/dev/null; then
        snapper create --description "Pre NVIDIA driver install snapshot"
        log "Created snapper snapshot"
        return 0
    fi
    log "No snapshot created"
}

# Install NVIDIA driver package
install_driver() {
    local driver_version=$1
    log "Installing NVIDIA driver version $driver_version"
    # Use ubuntu-drivers to install recommended driver or specific version
    if command -v ubuntu-drivers &>/dev/null; then
        if [[ "$driver_version" == "recommended" ]]; then
            ubuntu-drivers autoinstall
        else
            apt-get update
            apt-get install -y "nvidia-driver-$driver_version"
        fi
    else
        error_exit "ubuntu-drivers command not found, cannot install driver"
    fi
}

# Validate installation
validate_installation() {
    log "Validating NVIDIA driver installation"
    # Check nvidia-smi responds
    if ! command -v nvidia-smi &>/dev/null; then
        error_exit "nvidia-smi command not found after installation"
    fi
    if ! nvidia-smi &>/dev/null; then
        error_exit "nvidia-smi failed to respond"
    fi
    # Check OpenGL works (glxinfo)
    if command -v glxinfo &>/dev/null; then
        if ! glxinfo | grep "OpenGL renderer string" &>/dev/null; then
            error_exit "OpenGL test failed"
        fi
    else
        log "glxinfo not found, skipping OpenGL validation"
    fi
    # Check kernel taints (dmesg)
    if dmesg | grep -i taint &>/dev/null; then
        log "Warning: Kernel taints detected after driver install"
    fi
    log "Validation successful"
}

# Rollback to previous snapshot
rollback() {
    log "Rolling back NVIDIA driver installation"
    if mount | grep -q "on / type btrfs"; then
        # Find latest snapshot and rollback
        local latest_snapshot
        latest_snapshot=$(ls -1dt "$SNAPSHOT_DIR"/nvidia-driver-* 2>/dev/null | head -1 || true)
        if [[ -z "$latest_snapshot" ]]; then
            error_exit "No btrfs snapshot found for rollback"
        fi
        log "Rolling back to snapshot $latest_snapshot"
        # This requires reboot or manual rollback steps; here we just notify
        echo "Rollback snapshot available at $latest_snapshot. Please reboot and restore manually."
        exit 0
    fi
    if command -v snapper &>/dev/null; then
        log "Rolling back using snapper"
        snapper rollback
        log "Rollback done. Please reboot."
        exit 0
    fi
    error_exit "No snapshot tool available for rollback"
}

# Main logic
main() {
    log "Starting safe NVIDIA driver installer"

    local gpu_info
    gpu_info=$(detect_gpu)
    log "Detected GPU: $gpu_info"

    local current_driver
    current_driver=$(detect_current_driver)
    log "Current NVIDIA driver version: $current_driver"

    # Determine recommended driver version (simplified)
    local recommended_driver="recommended"
    if command -v ubuntu-drivers &>/dev/null; then
        recommended_driver=$(ubuntu-drivers devices | grep -m1 "recommended" | grep -oP 'nvidia-driver-\K[0-9]+' || echo "recommended")
    fi
    log "Recommended NVIDIA driver version: $recommended_driver"

    if ! check_kernel_compatibility "$recommended_driver"; then
        log "Kernel compatibility check failed. Aborting installation."
        exit 1
    fi

    create_snapshot

    local attempt=0
    while (( attempt < RETRY_LIMIT )); do
        ((attempt++))
        log "Installation attempt $attempt"
        if install_driver "$recommended_driver"; then
            if validate_installation; then
                log "NVIDIA driver installed and validated successfully"
                exit 0
            else
                log "Validation failed after installation attempt $attempt"
            fi
        else
            log "Installation failed on attempt $attempt"
        fi
        rollback
    done

    error_exit "Failed to install NVIDIA driver after $RETRY_LIMIT attempts"
}

main "$@"
