#!/bin/bash
# Framework-Aware CUDA/cuDNN Installer for CX Linux
# Detects installed ML frameworks and installs matching CUDA/cuDNN versions
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Supported frameworks and their CUDA requirements
declare -A FRAMEWORK_CUDA_VERSIONS=(
    ["pytorch"]="11.8"
    ["tensorflow"]="12.1"
    ["jax"]="11.7"
)

# Detect installed Python frameworks and their CUDA requirements
detect_framework_cuda() {
    local framework
    local cuda_version=""
    for framework in "${!FRAMEWORK_CUDA_VERSIONS[@]}"; do
        if python3 -c "import ${framework}" &>/dev/null; then
            cuda_version="${FRAMEWORK_CUDA_VERSIONS[$framework]}"
            echo "$framework:$cuda_version"
            return 0
        fi
    done
    return 1
}

# Check if NVIDIA driver is installed and get its version
get_nvidia_driver_version() {
    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1
    else
        echo ""
    fi
}

# Install CUDA toolkit and cuDNN matching the required CUDA version
install_cuda_cudnn() {
    local cuda_version="$1"
    echo "Installing CUDA toolkit and cuDNN for CUDA version $cuda_version..."

    # Add NVIDIA CUDA repository key and repo
    if ! dpkg-query -W cuda-keyring &>/dev/null; then
        echo "Adding NVIDIA CUDA keyring..."
        curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.0-1_all.deb -o /tmp/cuda-keyring.deb
        sudo dpkg -i /tmp/cuda-keyring.deb
        rm -f /tmp/cuda-keyring.deb
    fi

    echo "Adding CUDA repository..."
    sudo apt-get update
    sudo apt-get install -y cuda-toolkit-$cuda_version libcudnn8 libcudnn8-dev

    echo "CUDA toolkit and cuDNN installed for CUDA $cuda_version"
}

main() {
    echo "Detecting installed ML frameworks and CUDA requirements..."
    local detected
    if detected=$(detect_framework_cuda); then
        local framework="${detected%%:*}"
        local cuda_version="${detected#*:}"
        echo "Detected framework: $framework requires CUDA $cuda_version"

        local driver_version
        driver_version=$(get_nvidia_driver_version)
        if [[ -z "$driver_version" ]]; then
            echo "Warning: NVIDIA driver not detected. Please install NVIDIA driver first."
            exit 1
        fi
        echo "NVIDIA driver version detected: $driver_version"

        # TODO: Add driver compatibility check here if needed

        install_cuda_cudnn "$cuda_version"
        echo "Installation complete."
    else
        echo "No supported ML frameworks detected. Skipping CUDA/cuDNN installation."
        exit 0
    fi
}

main "$@"
