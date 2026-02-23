# P0 Installation Test Results

**Date:** 2025-01-25
**Tested By:** AI Worker (Claude)

---

## Test Infrastructure Created

### 1. Installation Test Script
**File:** `tests/installation-tests.sh`

Comprehensive bash script that tests:
- Clean system verification (no pre-existing CX packages)
- GPG key download and verification
- APT repository configuration
- cx-core installation (minimal)
- cx-full installation (complete)
- GPU package installation (NVIDIA/AMD detection)
- apt update/upgrade cycle with signature verification
- Version upgrade path testing
- Complete uninstallation with leftover file detection

**Usage:**
```bash
# Run all tests (requires root on target VM)
sudo ./tests/installation-tests.sh

# Run specific tests
sudo ./tests/installation-tests.sh clean gpg repo core

# Skip uninstall for debugging
sudo ./tests/installation-tests.sh --skip-uninstall

# Test offline ISO
sudo ./tests/installation-tests.sh --offline /path/to/cx.iso
```

### 2. Vagrant VM Configuration
**File:** `tests/Vagrantfile`

Pre-configured VMs for testing:
- `vagrant up ubuntu` - Ubuntu 24.04 LTS
- `vagrant up debian` - Debian 12 (Bookworm)
- `vagrant up nvidia` - GPU passthrough test (manual setup)

### 3. GitHub Actions Workflow
**File:** `.github/workflows/installation-tests.yml`

Automated CI/CD testing:
- Ubuntu 24.04 fresh install job
- Debian 12 container install job
- Version upgrade test job
- Minimal vs Full comparison job
- Repository signature verification job

---

## Package Structure Verification

| Package | debian/control | debian/changelog | debian/rules |
|---------|----------------|------------------|--------------|
| cx-archive-keyring | ✅ | ✅ | ✅ |
| cx-core | ✅ | ✅ | ✅ |
| cx-full | ✅ | ✅ | ✅ |
| cx-gpu-nvidia | ✅ | ✅ | ✅ |
| cx-gpu-amd | ✅ | ✅ | ✅ |
| cx-llm | ✅ | ✅ | ✅ |
| cx-secops | ✅ | ✅ | ✅ |

---

## Test Matrix

### Platform Support

| Test | Ubuntu 24.04 | Debian 12 | Status |
|------|--------------|-----------|--------|
| Fresh Install | ✅ | ✅ | Script Ready |
| GPG Key Import | ✅ | ✅ | Script Ready |
| Repository Add | ✅ | ✅ | Script Ready |
| cx-core | ✅ | ✅ | Script Ready |
| cx-full | ✅ | ✅ | Script Ready |
| Upgrade (v0.1→v0.2) | ✅ | ✅ | Script Ready |
| Uninstall/Purge | ✅ | ✅ | Script Ready |

### GPU Support

| Test | NVIDIA | AMD | Status |
|------|--------|-----|--------|
| Detection | ✅ | ✅ | Script Ready |
| Driver Install | 🔸 | 🔸 | Requires Hardware |
| cx-gpu-nvidia | 🔸 | N/A | Requires Hardware |
| cx-gpu-amd | N/A | 🔸 | Requires Hardware |

### Special Tests

| Test | Status | Notes |
|------|--------|-------|
| Offline ISO Install | 🔸 | Requires ISO file |
| Key Rotation | ✅ | Script checks expiration |
| Signature Verification | ✅ | CI workflow tests |

Legend: ✅ Automated | 🔸 Requires specific environment | ❌ Not supported

---

## How to Run Tests

### Local VM Testing (Vagrant)

```bash
cd cx-distro/tests

# Start Ubuntu VM and run tests
vagrant up ubuntu

# Check results
cat results-ubuntu-*.log

# SSH for debugging
vagrant ssh ubuntu

# Destroy after testing
vagrant destroy -f
```

### CI/CD Testing (GitHub Actions)

Push to `main` or `develop` branch, or manually trigger:
1. Go to Actions tab
2. Select "P0 Installation Tests"
3. Click "Run workflow"
4. Optionally check "Skip cleanup" for debugging

### Manual Testing on Real Hardware

```bash
# Download test script
curl -fsSL https://raw.githubusercontent.com/cxlinux-ai/cx-distro/main/tests/installation-tests.sh -o /tmp/test.sh
chmod +x /tmp/test.sh

# Run as root
sudo /tmp/test.sh
```

---

## Known Limitations

1. **GPU Tests** - Require actual GPU hardware, cannot run in standard VMs
2. **Offline ISO** - Requires pre-built ISO file
3. **Signature Tests** - Require published repository with signed Release files
4. **Package Availability** - Tests may show "not available" until packages are published to repo.cxlinux.com/apt

## Current Status

**Repository Status:** NOT YET DEPLOYED
- `repo.cxlinux.com/apt` is not resolving (DNS not configured or GitHub Pages not enabled)
- APT repository at `https://github.com/cxlinux-ai/apt-repo` exists but not deployed

**Pre-deployment Testing:**
- Package structure validation: ✅ PASS (all debian/ files present)
- Test scripts created and ready
- CI/CD workflow ready to run once packages are published

**To Deploy Repository:**
1. Enable GitHub Pages on `apt-repo` repository (Settings → Pages → Deploy from branch: `deploy`)
2. Configure DNS CNAME: `repo.cxlinux.com/apt` → `cxlinux-ai.github.io`
3. Build packages: `cd cx-distro && make packages`
4. Add packages to repo: `cd apt-repo && reprepro -b . includedeb cx ../cx-distro/*.deb`
5. Sign and push: `git add . && git commit -m "Add packages" && git push`

---

## Next Steps

1. Build and publish packages to APT repository
2. Run full test suite on actual VMs
3. Set up GPU test hardware (NVIDIA/AMD machines)
4. Create ISO and test offline installation
5. Test key rotation procedure

---

## Files Created

```
cx-distro/
├── tests/
│   ├── installation-tests.sh    # Main test script (NEW)
│   ├── Vagrantfile              # VM configuration (NEW)
│   ├── TEST_RESULTS.md          # This file (NEW)
│   ├── verify-iso.sh            # ISO verification (existing)
│   ├── verify-packages.sh       # Package verification (existing)
│   └── verify-preseed.sh        # Preseed verification (existing)
├── .github/workflows/
│   └── installation-tests.yml   # CI/CD workflow (NEW)
```
