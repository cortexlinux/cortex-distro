# CX Linux Distribution - Copilot Instructions

## Repository Overview

**cx-distro** is the Debian-based distribution build system for CX Linux, an AI-native operating system. This repository handles ISO generation, package repository management, automated installation, and supply-chain security.

**Size**: ~2,100 lines of code (scripts/tools)  
**Language**: Bash (build scripts), Debian packaging  
**Target**: Debian 13 (Trixie) / Ubuntu 24.04 base  
**Build Host**: Requires Debian/Ubuntu with root access  
**Output**: Bootable ISO images (~2-4GB) and .deb packages

## Critical Build Requirements

### System Requirements
- **OS**: Debian 12+ or Ubuntu 24.04+ (native, not WSL)
- **Disk Space**: 10GB+ free (ISO builds need substantial space)
- **Network**: Internet connection for package downloads
- **Access**: Root/sudo access required for live-build
- **Tools**: Must be installed BEFORE any build

### Installing Dependencies

**ALWAYS run this first** before building anything:
```bash
sudo apt-get update
sudo apt-get install -y \
    live-build \
    debootstrap \
    squashfs-tools \
    xorriso \
    isolinux \
    syslinux-efi \
    grub-pc-bin \
    grub-efi-amd64-bin \
    mtools \
    dosfstools \
    dpkg-dev \
    devscripts \
    debhelper \
    fakeroot \
    gnupg
```

Or use: `sudo make deps` (does the same thing)

## Build System

### Package Building (Fastest, Start Here)

**Build a single package** (recommended for testing):
```bash
cd packages/cx-core
dpkg-buildpackage -us -uc -b
# Output: cx-core_*.deb in packages/
```

**Build all packages**:
```bash
make package
# or
./scripts/build.sh packages
```

**Common build failure**: `Unmet build dependencies: build-essential debhelper-compat (= 13)`
- **Fix**: Install build deps first (see above)
- Packages are built in packages/ directory, NOT in the package subdirectory

### ISO Building (Slow, ~30-60 minutes)

**IMPORTANT**: ISO builds use `live-build` which requires root and takes significant time.

```bash
# Full offline ISO with all packages
sudo ./scripts/build.sh offline
# or
sudo make iso

# Network installer (minimal, faster)
sudo ./scripts/build.sh netinst
# or
sudo make iso-netinst
```

**Expected output**: `output/cx-linux-0.1.0-amd64-*.iso` with checksums

**Common failures**:
1. "lb: command not found" → Install dependencies (live-build)
2. "E: Permission denied" → Must use sudo for ISO builds
3. Build hangs → Normal for ISO builds, wait 30-60 minutes
4. "No space left on device" → Need 10GB+ free

### Testing

**Package verification** (no dependencies needed):
```bash
./tests/verify-packages.sh
# Tests: debian/control, debian/changelog, debian/rules existence
```

**ISO verification** (requires ISO file):
```bash
./tests/verify-iso.sh output/cx-linux-*.iso
```

**Full test suite**:
```bash
make test
# Runs all verification scripts
```

## Project Layout

```
cx-distro/
├── .github/
│   └── workflows/           # CI/CD pipelines
│       ├── build-iso.yml           # Main ISO build (runs in Docker)
│       ├── installation-tests.yml  # APT repo install tests
│       └── reproducible-builds.yml # Builds packages twice, compares
├── Makefile                 # Primary build interface
├── scripts/
│   └── build.sh             # Master build script (all-in-one)
├── packages/                # Debian package definitions
│   ├── cx-archive-keyring/  # GPG keyring for APT trust
│   ├── cx-core/             # Minimal install meta-package
│   ├── cx-full/             # Full install meta-package
│   ├── cx-gpu-nvidia/       # NVIDIA GPU support
│   ├── cx-gpu-amd/          # AMD GPU support
│   ├── cx-llm/              # Local LLM packaging
│   └── cx-secops/           # Security operations tools
├── iso/
│   ├── live-build/          # Debian live-build configuration
│   │   ├── auto/            # lb config automation
│   │   │   ├── config       # Sets distribution, architecture
│   │   │   ├── build        # Build hooks
│   │   │   └── clean        # Cleanup hooks
│   │   └── config/
│   │       ├── package-lists/     # Packages to include in ISO
│   │       ├── hooks/             # First-boot customization
│   │       └── includes.chroot/   # Files to copy into ISO
│   └── preseed/
│       └── cx.preseed       # Automated installation config
├── repository/
│   └── scripts/
│       └── repo-manage.sh   # APT repository management
├── sbom/
│   └── generate-sbom.sh     # Software Bill of Materials
├── tests/
│   ├── verify-packages.sh   # Debian package structure checks
│   ├── verify-iso.sh        # ISO integrity checks
│   ├── verify-preseed.sh    # Preseed syntax validation
│   └── installation-tests.sh # Full install test suite
└── docs/
    ├── HARDWARE-COMPATIBILITY.md
    ├── KEY-MANAGEMENT-RUNBOOK.md
    └── KEY-ROTATION-RUNBOOK.md
```

### Key Files

**Root directory**:
- `Makefile` - Build targets (iso, package, test, clean, deps)
- `README.md` - Comprehensive project documentation
- `LICENSE` - BSL 1.1 license

**Package structure** (each package has):
- `debian/control` - Package metadata, dependencies
- `debian/changelog` - Version history (Debian format)
- `debian/rules` - Build instructions (must be executable)

## CI/CD Workflows

### build-iso.yml
Triggered by: pushes to main, PRs, tags (v*), manual dispatch

**Jobs**:
1. **build-packages**: Builds all .deb packages in Debian container
   - Runs `dpkg-buildpackage` for each package
   - Uploads packages as artifacts
2. **build-iso**: Builds ISO in privileged Debian container
   - Downloads packages from previous job
   - Runs `lb config && lb build` (takes ~30 min)
   - Generates SHA256/SHA512 checksums
   - Uploads ISO as artifact
3. **release**: Creates GitHub release on version tags

**Important**: Uses Docker with `--privileged` flag for live-build

### installation-tests.yml
Triggered by: pushes to main/develop, PRs

**Jobs**: Tests installation on Ubuntu 24.04 and Debian 12
- Adds APT repository
- Installs cx-core and cx-full
- Tests upgrade path
- Verifies GPG signatures
- Tests uninstall/cleanup

### reproducible-builds.yml
Triggered by: changes to packages/

**Jobs**: Builds packages twice and compares checksums
- Uses sbuild in clean chroot
- Runs lintian checks
- Generates diffoscope reports if builds differ

## Common Workflows

### Making Changes to a Package

1. Edit files in `packages/PACKAGE_NAME/`
2. Update `debian/changelog` (using `dch` from devscripts):
   ```bash
   cd packages/PACKAGE_NAME
   dch -i "Description of change"
   ```
3. Build and test:
   ```bash
   dpkg-buildpackage -us -uc -b
   ```
4. Verify output .deb file exists in `packages/`

### Testing ISO Changes

1. Modify files in `iso/live-build/config/`
2. Clean previous build:
   ```bash
   cd iso/live-build && sudo lb clean --purge
   ```
3. Rebuild:
   ```bash
   cd ../.. && sudo make iso
   ```
4. Test in VM (QEMU/VirtualBox/Vagrant)

### Updating Package Lists

Edit `iso/live-build/config/package-lists/*.list.chroot`:
- `cx-core.list.chroot` - Minimal installation packages
- `cx-full.list.chroot` - Full installation packages

## Build Artifacts and Cleanup

### Generated Files (DO NOT COMMIT)
- `packages/*.deb`, `packages/*.buildinfo`, `packages/*.changes`
- `output/` directory (ISOs, checksums, SBOM)
- `build/`, `build-*.log`
- `iso/live-build/chroot/`, `iso/live-build/binary/`, `iso/live-build/*.iso`

### Cleaning Up
```bash
make clean           # Removes all build artifacts
cd iso/live-build && sudo lb clean --purge  # Deep clean ISO build
```

**After making changes**: Always clean before rebuilding ISOs to avoid stale configs

## Important Notes

### Live-build Quirks
- **Must use sudo** for `lb config`, `lb build`, `lb clean`
- Configuration in `iso/live-build/auto/config` runs before build
- Uses **bookworm (Debian 12)** as base (defined in auto/config)
- Changes to config/ require `lb clean --purge` to take effect

### Package Building
- Build deps error is normal if tools not installed
- Built packages appear in repository root's `packages/` directory (not within individual package subdirectories)
- Use `-us -uc` flags to skip signing during development
- Production builds need GPG signing (`-k KEYID`)
- **Note**: Repository deployment status - repo.cxlinux-ai.com is not yet available. Installation tests in CI will show "package not available" until the repository is deployed.

### Repository Management
When repository is deployed:
```bash
./repository/scripts/repo-manage.sh init
./repository/scripts/repo-manage.sh add packages/*.deb
CX_GPG_KEY_ID=YOUR_KEY ./repository/scripts/repo-manage.sh publish
```

### Testing Gotchas
- Installation tests expect published repository (will show "not available" locally)
- ISO verification requires actual ISO file
- GPU tests need real hardware (skip in CI)

## Validation Before PR

1. **Build packages**: `make package` (or specific package)
2. **Run tests**: `./tests/verify-packages.sh`
3. **Check Debian package standards**:
   - All packages have `debian/control`, `debian/changelog`, `debian/rules`
   - `debian/rules` is executable (`chmod +x`)
4. **If ISO changes**: Build and boot-test in VM
5. **Review changes**: Ensure no build artifacts committed

## Trust These Instructions

These instructions are comprehensive and tested. Only search for additional information if:
- Instructions are incomplete for your specific task
- You encounter an error not documented here
- You need details about a specific package's dependencies

For routine builds, testing, and package changes, follow the workflows above without additional exploration.
