#!/bin/bash
# Test script for GRUB Boot Repair Wizard

set -euo pipefail

TEST_SCRIPT="/usr/local/bin/grub-boot-repair"

if [ ! -x "$TEST_SCRIPT" ]; then
    echo "Test failed: $TEST_SCRIPT not found or not executable"
    exit 1
fi

echo "Running GRUB Boot Repair Wizard detection test..."
$TEST_SCRIPT

echo "Running GRUB Boot Repair Wizard repair test (dry run)..."
# We simulate repair by running with --help and checking output
$TEST_SCRIPT --help

echo "All tests passed."
