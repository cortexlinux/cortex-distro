# Safe NVIDIA Driver Installer with Rollback

This tool provides a safe way to install NVIDIA drivers on Linux systems with automatic rollback support in case of failure.

## Features

- Detects NVIDIA GPU model and current driver version
- Checks kernel compatibility before installation
- Creates system snapshot before making changes (supports btrfs and snapper)
- Installs recommended or specified NVIDIA driver version
- Validates installation by checking `nvidia-smi` and OpenGL functionality
- Supports automatic rollback to previous snapshot on failure
- Logs all operations to `/var/log/nvidia-safe-install.log`

## Usage

Run the installer script as root:

```bash
sudo ./install.sh
```

You can specify a driver version to install by passing it as an argument:

```bash
sudo ./install.sh 535
```

If no version is specified, the recommended driver version will be installed.

## Requirements

- `lspci`, `ubuntu-drivers`, `btrfs` or `snapper` (optional for snapshots)
- `nvidia-smi` and `glxinfo` for validation (installed by driver)
- Root privileges

## License

Apache-2.0
