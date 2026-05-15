# Safe NVIDIA Driver Installer

`cx-nvidia-safe-install` installs NVIDIA drivers through a guarded workflow that
keeps a rollback point before package changes and validates the resulting driver
state before marking the install successful.

## Commands

```bash
# Inspect the detected GPU, current driver, and latest rollback snapshot.
cx-nvidia-safe-install status

# Simulate the complete plan without changing packages.
sudo cx-nvidia-safe-install install --dry-run

# Install the recommended driver from ubuntu-drivers, or the newest apt driver.
sudo cx-nvidia-safe-install install

# Install a specific driver package.
sudo cx-nvidia-safe-install install --driver nvidia-driver-545

# Roll back to the latest saved snapshot.
sudo cx-nvidia-safe-install rollback

# Roll back to a named snapshot.
sudo cx-nvidia-safe-install rollback --snapshot 20260103T120000Z
```

## What The Installer Checks

- NVIDIA hardware from `nvidia-smi -L` or `lspci`.
- Current driver state from `nvidia-smi` or installed `nvidia-driver*` packages.
- Running kernel version and matching module/header availability.
- DKMS visibility for rebuilding out-of-tree NVIDIA modules.
- Secure Boot state through `mokutil --sb-state`.
- APT candidate and simulated install plan before making package changes.

If Secure Boot is enabled, the installer stops unless `--force` is supplied. This
prevents silently installing unsigned modules on machines that will reject them
at boot.

## Rollback Snapshot Contents

Snapshots are written under `/var/lib/cx/nvidia-installer/snapshots/<id>` and
include:

- GPU and `nvidia-smi` output.
- NVIDIA, CUDA, and libnvidia package versions.
- Full `dpkg --get-selections` output.
- Manual and automatic apt-mark state.
- DKMS and loaded module state.
- NVIDIA or nouveau modprobe configuration files.

Rollback purges NVIDIA/CUDA packages that were not present in the snapshot,
reinstalls previously recorded NVIDIA/CUDA package versions with
`--allow-downgrades`, restores NVIDIA-related manual apt marks, and refreshes
initramfs when `update-initramfs` is available.

## Validation

After install, the validation suite checks:

- `nvidia-smi` responds.
- `modprobe -n nvidia` can resolve the kernel module.
- DKMS does not report failed or broken NVIDIA module state.
- Kernel taint is reported. With `--strict-taint`, expected NVIDIA proprietary
  and out-of-tree module bits are allowed, while other taint bits fail
  validation.
- OpenGL renderer output when `glxinfo` and `DISPLAY` are available.

Headless servers often do not have an OpenGL display stack. Use
`--skip-opengl` when validating those systems.

## Test And Image Build Notes

For ISO/image build systems or CI that do not expose GPU hardware, use
`--dry-run --force` to confirm package availability and snapshot creation without
touching the system. The test suite uses `CX_NVIDIA_STATE_DIR` and
`CX_NVIDIA_LOG_FILE` to redirect all state into a temporary directory.
