# CX Distro

**Debian-based Distribution Engineering for CX Linux**

[![License](https://img.shields.io/badge/license-BSL%201.1-orange.svg)](LICENSE)
[![Debian](https://img.shields.io/badge/base-Debian%2013%20trixie-A81D33.svg)](https://debian.org)
[![Build](https://img.shields.io/github/actions/workflow/status/cxlinux-ai/cx-distro/build-iso.yml?branch=main)](https://github.com/cxlinux-ai/cx-distro/actions)

## Overview

`cx-distro` handles everything related to building and distributing CX Linux as a Debian-based operating system. This includes ISO generation, package repository management, automated installation, and supply-chain security.

**CX Linux** is an AI-native operating system that translates natural language commands into Linux operations, eliminating traditional documentation complexity for server management.

## Quick Start

### Build ISO (Debian/Ubuntu host required)

```bash
# Clone repository
git clone https://github.com/cxlinux-ai/cx-distro.git
cd cx-distro

# Install dependencies (requires sudo)
sudo apt-get install -y live-build debootstrap squashfs-tools xorriso \
    isolinux syslinux-efi grub-pc-bin grub-efi-amd64-bin \
    mtools dosfstools dpkg-dev devscripts debhelper fakeroot gnupg

# Build offline ISO (recommended)
chmod +x scripts/build.sh
sudo ./scripts/build.sh offline

# Or use Makefile
make deps  # Install dependencies
make iso   # Build ISO
```

### Output

After a successful build:
```
output/
├── cx-linux-0.1.0-amd64-offline.iso      # Bootable ISO
├── cx-linux-0.1.0-amd64-offline.iso.sha256
├── packages/
│   ├── cx-archive-keyring_*.deb
│   ├── cx-core_*.deb
│   └── cx-full_*.deb
└── sbom/
    ├── cx-linux-0.1.0.cdx.json           # CycloneDX SBOM
    └── cx-linux-0.1.0.spdx.json          # SPDX SBOM
```

## Architecture

```
cx-distro/
├── iso/                        # ISO build configuration
│   ├── live-build/             # Debian live-build configs
│   │   ├── auto/               # Build automation scripts
│   │   └── config/             # Package lists, hooks, includes
│   └── preseed/                # Automated installation preseeds
├── packages/                   # Debian package definitions
│   ├── cx-archive-keyring/ # GPG keyring package
│   ├── cx-core/            # Minimal installation meta-package
│   └── cx-full/            # Full installation meta-package
├── repository/                 # APT repository tooling
│   └── scripts/                # repo-manage.sh
├── sbom/                       # SBOM generation (CycloneDX/SPDX)
├── branding/                   # Plymouth theme, wallpapers
├── scripts/                    # Build automation
│   └── build.sh                # Master build script
├── tests/                      # Verification tests
│   ├── verify-iso.sh
│   ├── verify-packages.sh
│   └── verify-preseed.sh
├── .github/workflows/          # CI/CD pipelines
├── Makefile                    # Build targets
└── README.md
```

## Key Components

| Component | Description |
|-----------|-------------|
| **ISO Builder** | Reproducible ISO image pipeline using Debian live-build |
| **APT Repository** | Signed package repository with GPG key management |
| **Meta-packages** | cx-core (minimal), cx-full (complete) |
| **First-boot** | Preseed automation and idempotent provisioning |
| **SBOM** | Software Bill of Materials (CycloneDX/SPDX) |

## Installation Profiles

### cx-core (Minimal)
- Base system with Python 3.11+
- Security sandbox (Firejail, AppArmor)
- SSH server
- CX package manager dependencies

### cx-full (Recommended)
Everything in cx-core plus:
- Docker and container tools
- Network security (nftables, fail2ban)
- Monitoring (Prometheus node exporter)
- Web server (nginx) and TLS (certbot)
- GPU support prerequisites
- Modern CLI tools (htop, btop, fzf, ripgrep, bat)

## Automated Installation

CX Linux supports fully unattended installation via preseed:

```bash
# Boot parameter for automated install
preseed/file=/cdrom/preseed/cx.preseed
```

### Preseed Features
- UEFI and BIOS support
- LVM partitioning (default)
- Optional LUKS encryption
- SSH key injection
- Admin user creation
- CX repository configuration

## APT Repository

CX uses a signed APT repository with deb822 format:

```
# /etc/apt/sources.list.d/cx.sources
Types: deb
URIs: https://repo.cxlinux.com/apt/apt
Suites: cx cx-updates cx-security
Components: main
Signed-By: /usr/share/keyrings/cx-archive-keyring.gpg
```

### Repository Management

```bash
# Initialize repository
./repository/scripts/repo-manage.sh init

# Add package
./repository/scripts/repo-manage.sh add packages/cx-core_0.1.0-1_all.deb

# Publish (sign and generate metadata)
CX_GPG_KEY_ID=ABCD1234 ./repository/scripts/repo-manage.sh publish

# Create snapshot
./repository/scripts/repo-manage.sh snapshot

# Export for offline use
./repository/scripts/repo-manage.sh export cx-offline-repo
```

## Security

### Supply Chain
- Signed ISO images (SHA256/SHA512)
- Signed APT repository (GPG)
- SBOM generation (CycloneDX, SPDX)
- Reproducible builds (goal)

### System Hardening
- AppArmor profiles
- Firejail sandboxing
- Secure sysctl defaults
- SSH hardening
- nftables firewall

## Build Targets

```bash
make help           # Show all targets
make iso            # Build full offline ISO
make iso-netinst    # Build minimal network installer
make package        # Build all Debian packages
make package PKG=cx-core  # Build specific package
make sbom           # Generate SBOM
make test           # Run verification tests
make clean          # Remove build artifacts
make deps           # Install build dependencies
```

## Topics Covered

This repository implements 9 major topics from the CX Linux planning:

- [x] Automated installation and first-boot provisioning
- [x] CX package repository and apt trust model
- [x] Debian base selection and compatibility contract
- [ ] Debian packaging strategy for CX components
- [ ] GPU driver enablement and packaging (NVIDIA/AMD)
- [x] ISO image build system (live-build)
- [ ] Kernel, firmware, and hardware enablement plan
- [x] Reproducible builds, artifact signing, and SBOM outputs
- [ ] Upgrade, rollback, and version pinning

## Requirements

### Build Host
- Debian 12+ or Ubuntu 24.04+
- 10GB+ free disk space
- Internet connection (for package downloads)
- Root/sudo access

### Target Hardware
- x86_64 (amd64) architecture
- UEFI or Legacy BIOS
- 2GB+ RAM (4GB+ recommended)
- 20GB+ storage

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

### Development Workflow

1. Fork the repository
2. Create a feature branch
3. Make changes
4. Run tests: `make test`
5. Submit PR

## Related Repositories

- [cx-terminal](https://github.com/cxlinux-ai/cx-core) - AI-powered terminal emulator
- [website](https://github.com/cxlinux-ai/website) - cxlinux-ai.com

## License

BSL 1.1 - See [LICENSE](LICENSE)

## Support

- Documentation: https://cxlinux.com/docs
- Issues: https://github.com/cxlinux-ai/cx-distro/issues
- Discord: https://discord.gg/cxlinux-ai

---

**Copyright 2025 AI Venture Holdings LLC**
