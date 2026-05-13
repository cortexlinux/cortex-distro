# CX Linux APT Repository

Official APT package repository for CX Linux.

**Repository URL:** https://repo.cxlinux.com

## Quick Install

```bash
# Add GPG signing key
curl -fsSL https://repo.cxlinux.com/pub.gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/cxlinux-archive-keyring.gpg

# Add repository (DEB822 format - recommended)
sudo tee /etc/apt/sources.list.d/cxlinux.sources << 'EOF'
Types: deb
URIs: https://repo.cxlinux.com
Suites: stable
Components: main
Signed-By: /usr/share/keyrings/cxlinux-archive-keyring.gpg
EOF

# Or use one-line format (legacy)
echo "deb [signed-by=/usr/share/keyrings/cxlinux-archive-keyring.gpg] https://repo.cxlinux.com stable main" \
    | sudo tee /etc/apt/sources.list.d/cxlinux.list

# Update and install packages
sudo apt update
sudo apt install cx-cli
```

## Repository Structure

```
apt-repo/
├── dists/
│   └── stable/
│       └── main/
│           └── binary-amd64/     # Package indices
│               ├── Packages
│               ├── Packages.gz
│               └── Release
├── pool/
│   └── main/
│       └── c/
│           └── cx/               # Actual .deb files
│               └── *.deb
├── conf/
│   └── distributions            # reprepro configuration
├── deploy/
│   └── pub.gpg                  # GPG public key
├── scripts/
│   └── sign-release.sh          # Release signing script
├── cxlinux.sources              # DEB822 sources file
└── cxlinux.list                 # Legacy sources.list entry
```

## How It Works

```
.deb packages  →  dpkg-scanpackages  →  Packages index  →  GPG signed  →  GitHub Pages
   (pool/)           (CI/CD)            (dists/)          (Release)     (repo.cxlinux.com)
```

1. Packages are stored in `pool/main/c/cx/`
2. GitHub Actions generates `Packages` index using `dpkg-scanpackages`
3. Release file is signed with GPG key
4. Everything is deployed to GitHub Pages

## Adding Packages

### Method 1: Direct commit

```bash
# Copy .deb to pool
cp mypackage_1.0.0_amd64.deb pool/main/c/cx/

# Commit and push
git add pool/
git commit -m "Add mypackage 1.0.0"
git push
```

### Method 2: Workflow dispatch

Go to Actions → Publish APT Repository → Run workflow

Enter the URL to a .deb package and it will be downloaded and added.

### Method 3: Cross-repo trigger

Other repositories can trigger a build:

```bash
curl -X POST \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  https://api.github.com/repos/OWNER/apt-repo/dispatches \
  -d '{
    "event_type": "package-ready",
    "client_payload": {
      "suite": "stable",
      "packages": [
        {"name": "cx-cli", "file": "cx-cli_1.0.0_amd64.deb", "url": "https://..."}
      ]
    }
  }'
```

## GPG Signing

### Generate a new key

```bash
# Generate key (RSA 4096, no expiration)
gpg --full-generate-key

# Get key ID
gpg --list-keys --keyid-format LONG

# Export public key
gpg --armor --export YOUR_KEY_ID > deploy/pub.gpg

# Export private key for GitHub secret
gpg --armor --export-secret-keys YOUR_KEY_ID
```

### GitHub Secrets required

| Secret | Description |
|--------|-------------|
| `GPG_PRIVATE_KEY` | Armored private GPG key |
| `GPG_PASSPHRASE` | Passphrase for the key (if any) |

### Manual signing

```bash
# Sign Release files manually
./scripts/sign-release.sh YOUR_KEY_ID
```

## Integrity Verification

Use `scripts/verify-integrity.sh` to validate repository metadata and package
artifacts before publishing or after downloading a repository snapshot.

```bash
# Verify Release.gpg / InRelease signatures and package checksums.
# ASCII-armored keys are dearmored into a temporary gpgv keyring automatically.
./scripts/verify-integrity.sh --keyring deploy/pub.gpg .

# Check package artifacts only when no trusted public key is available.
./scripts/verify-integrity.sh .
```

Without `--keyring`, verification is limited to artifact checksums and package
paths; it does not prove the repository metadata source or trust chain.

The verifier reports:

- SHA256 checksum mismatches for `.deb` files listed in `Packages` or
  `Packages.gz`
- Missing package files referenced by package indexes
- Unsafe package paths in repository metadata
- Invalid or missing `Release.gpg` / `InRelease` signatures when a keyring is
  provided

This check is read-only. It does not install packages or execute package
maintainer scripts.

## GitHub Pages Setup

1. Go to Settings → Pages
2. Source: Deploy from a branch
3. Branch: `gh-pages` / `/ (root)`
4. Custom domain: `repo.cxlinux.com`

Add DNS CNAME record:
```
repo.cxlinux.com  →  CNAME  →  allbots.github.io
```

## Distributions

| Suite | Codename | Description |
|-------|----------|-------------|
| stable | stable | Production-ready packages |
| testing | testing | Pre-release testing (future) |
| unstable | unstable | Development builds (future) |

## License

Apache-2.0 - See LICENSE in the main repository.
