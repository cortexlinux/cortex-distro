#!/bin/bash
# Safe NVIDIA Driver Installer with Rollback
#
# This script installs NVIDIA drivers safely by:
# 1. Detecting GPU model and current driver state
# 2. Checking kernel compatibility
# 3. Creating a system snapshot before installation
# 4. Validating installation success
# 5. Rolling back automatically on failure
#
# Usage: sudo ./nvidia-installer.sh [driver-version]
#
# Requires: btrfs, snapper, dkms, nvidia-driver packages, and systemd

set -euo pipefail

# Configuration
SNAPPER_CONFIG="root"
SNAPSHOT_DESCRIPTION="Pre-NVIDIA-driver-install-$(date +%Y%m%d%H%M%S)"
VALIDATION_TIMEOUT=30

function print_info() {
    echo -e "\e[34m[INFO]\e[0m $*"
}

function print_warn() {
    echo -e "\e[33m[WARN]\e[0m $*"
}

function print_error() {
    echo -e "\e[31m[ERROR]\e[0m $*" >&2
}

function detect_gpu() {
    print_info "Detecting NVIDIA GPU..."
    if ! command -v lspci &>/dev/null; then
        print_error "lspci command not found. Please install pciutils."
        exit 1
    fi
    GPU_INFO=$(lspci | grep -i nvidia || true)
    if [[ -z "$GPU_INFO" ]]; then
        print_warn "No NVIDIA GPU detected. Exiting."
        exit 0
    fi
    print_info "Detected NVIDIA GPU: $GPU_INFO"
}

function check_kernel_compatibility() {
    print_info "Checking kernel compatibility..."
    KERNEL_VERSION=$(uname -r)
    # Check if kernel headers are installed
    if ! dpkg -s "linux-headers-$KERNEL_VERSION" &>/dev/null; then
        print_error "Kernel headers for $KERNEL_VERSION not installed."
        print_error "Please install linux-headers-$KERNEL_VERSION package."
        exit 1
    fi
    print_info "Kernel headers for $KERNEL_VERSION found."
}

function create_snapshot() {
    print_info "Creating system snapshot before NVIDIA driver installation..."
    if ! command -v snapper &>/dev/null; then
        print_error "snapper not installed. Please install snapper."
        exit 1
    fi
    SNAPSHOT_ID=$(snapper create --description "$SNAPSHOT_DESCRIPTION" --command "NVIDIA driver install snapshot")
    if [[ -z "$SNAPSHOT_ID" ]]; then
        print_error "Failed to create snapper snapshot."
        exit 1
    fi
    print_info "Created snapshot ID: $SNAPSHOT_ID"
}

function install_nvidia_driver() {
    local driver_version="$1"
    print_info "Installing NVIDIA driver version: $driver_version"
    # Use ubuntu-drivers to install recommended driver if no version specified
    if [[ -z "$driver_version" ]]; then
        print_info "No driver version specified, installing recommended driver..."
        ubuntu-drivers autoinstall
    else
        print_info "Installing specified driver version: $driver_version"
        apt-get update
        apt-get install -y "nvidia-driver-$driver_version"
    fi
}

function validate_installation() {
    print_info "Validating NVIDIA driver installation..."
    local timeout=$VALIDATION_TIMEOUT
    local interval=3
    local elapsed=0
    while (( elapsed < timeout )); do
        if command -v nvidia-smi &>/dev/null; then
            if nvidia-smi &>/dev/null; then
                print_info "nvidia-smi responded successfully."
                return 0
            fi
        fi
        print_warn "nvidia-smi not responding yet, waiting..."
        sleep $interval
        ((elapsed+=interval))
    done
    print_error "NVIDIA driver validation failed after $timeout seconds."
    return 1
}

function rollback_snapshot() {
    print_warn "Rolling back to snapshot ID: $SNAPSHOT_ID"
    snapper undochange "$SNAPSHOT_ID"
    print_warn "Rollback complete. Please reboot your system."
}

function main() {
    detect_gpu
    check_kernel_compatibility
    create_snapshot

    DRIVER_VERSION="${1:-}"

    install_nvidia_driver "$DRIVER_VERSION"

    if validate_installation; then
        print_info "NVIDIA driver installed and validated successfully."
        print_info "You can remove the snapshot if desired: snapper delete $SNAPSHOT_ID"
    else
        print_error "Validation failed. Rolling back changes..."
        rollback_snapshot
        exit 1
    fi
}

main "$@"
