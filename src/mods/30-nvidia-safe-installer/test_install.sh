#!/bin/bash
# Test script for Safe NVIDIA Driver Installer

set -euo pipefail

# Test detection of GPU
echo "Testing GPU detection..."
if ./install.sh --dry-run | grep -q "Detected GPU"; then
    echo "GPU detection test passed"
else
    echo "GPU detection test failed"
    exit 1
fi

# Test kernel compatibility check
echo "Testing kernel compatibility check..."
if ./install.sh --check-kernel 535; then
    echo "Kernel compatibility test passed"
else
    echo "Kernel compatibility test failed"
    exit 1
fi

echo "All tests passed"
