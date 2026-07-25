#!/bin/bash
# Test script for framework-aware CUDA/cuDNN installer

set -euo pipefail

# Test detection of frameworks
test_detect_framework_cuda() {
    echo "Testing framework detection..."

    # Create a temporary Python environment with dummy modules
    TMPDIR=$(mktemp -d)
    trap "rm -rf $TMPDIR" EXIT

    # Create dummy modules for pytorch and tensorflow
    mkdir -p "$TMPDIR/lib/python3.11/site-packages"
    echo "print('dummy pytorch')" > "$TMPDIR/lib/python3.11/site-packages/torch.py"
    echo "print('dummy tensorflow')" > "$TMPDIR/lib/python3.11/site-packages/tensorflow.py"

    # Run detection with PYTHONPATH set
    PYTHONPATH="$TMPDIR/lib/python3.11/site-packages" bash -c '
        source ./repository/scripts/cuda-installer.sh
        detect_framework_cuda
    '
}

# Test NVIDIA driver version detection
test_get_nvidia_driver_version() {
    echo "Testing NVIDIA driver version detection..."
    if command -v nvidia-smi &>/dev/null; then
        version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)
        echo "NVIDIA driver version: $version"
    else
        echo "nvidia-smi not found, skipping driver version test."
    fi
}

# Run all tests
main() {
    test_detect_framework_cuda
    test_get_nvidia_driver_version
    echo "All tests passed."
}

main "$@"
