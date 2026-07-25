#!/bin/bash
# GRUB Boot Repair Wizard Installer Script
# Installs the GRUB Boot Repair Wizard tool for CX Linux
# Usage: Run this script as root to install the tool

set -euo pipefail

# Define installation directory
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/grub-boot-repair"
SERVICE_FILE="/etc/systemd/system/grub-boot-repair.service"

# Create config directory
mkdir -p "$CONFIG_DIR"

# Install the main script
cat > "$INSTALL_DIR/grub-boot-repair" << 'EOF'
#!/bin/bash
# GRUB Boot Repair Wizard
# Detects boot state, finds Linux partitions, repairs GRUB, validates boot entries
# Works from live USB or installed system

set -euo pipefail

log() {
    echo "[INFO] $*"
}

error() {
    echo "[ERROR] $*" >&2
}

detect_boot_state() {
    log "Detecting boot state..."
    if [ -d /sys/firmware/efi ]; then
        BOOT_MODE="UEFI"
    else
        BOOT_MODE="BIOS"
    fi

    if ! command -v grub-install >/dev/null 2>&1; then
        error "grub-install command not found"
        exit 1
    fi

    if ! command -v efibootmgr >/dev/null 2>&1 && [ "$BOOT_MODE" = "UEFI" ]; then
        error "efibootmgr command not found, required for UEFI boot repair"
        exit 1
    fi

    log "Boot mode detected: $BOOT_MODE"
}

find_linux_partitions() {
    log "Finding Linux partitions..."
    PARTITIONS=$(lsblk -ln -o NAME,FSTYPE | grep -E 'ext4|btrfs|xfs|f2fs|linux_raid_member' | awk '{print "/dev/" $1}')
    if [ -z "$PARTITIONS" ]; then
        error "No Linux partitions found"
        exit 1
    fi
    echo "$PARTITIONS"
}

repair_grub() {
    local root_partition="$1"
    log "Repairing GRUB on root partition $root_partition..."

    mountpoint -q /mnt || mount "$root_partition" /mnt
    mount --bind /dev /mnt/dev
    mount --bind /proc /mnt/proc
    mount --bind /sys /mnt/sys

    if [ "$BOOT_MODE" = "UEFI" ]; then
        mount --bind /sys/firmware/efi/efivars /mnt/sys/firmware/efi/efivars || true
    fi

    chroot /mnt /bin/bash -c "
        set -e
        grub-install --recheck
        update-grub
    "

    umount /mnt/sys/firmware/efi/efivars 2>/dev/null || true
    umount /mnt/sys
    umount /mnt/proc
    umount /mnt/dev
    umount /mnt

    log "GRUB repair completed."
}

validate_boot_entries() {
    log "Validating boot entries..."
    if [ "$BOOT_MODE" = "UEFI" ]; then
        efibootmgr -v
    else
        log "BIOS boot mode detected, no efibootmgr validation needed."
    fi
}

usage() {
    echo "Usage: $0 [--repair]"
    echo "  --repair    Attempt to repair GRUB bootloader"
    echo "  --help      Show this help message"
}

main() {
    detect_boot_state
    case "${1:-}" in
        --repair)
            PARTS=$(find_linux_partitions)
            for part in $PARTS; do
                repair_grub "$part"
            done
            validate_boot_entries
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "GRUB Boot Repair Wizard"
            echo "Boot mode: $BOOT_MODE"
            echo "Linux partitions found:"
            find_linux_partitions
            echo ""
            echo "Run with --repair to attempt repair."
            ;;
    esac
}

main "$@"
EOF

chmod +x "$INSTALL_DIR/grub-boot-repair"

# Create systemd service to run repair on boot if needed (optional)
cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=GRUB Boot Repair Wizard Service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/grub-boot-repair --repair
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable the service (optional)
systemctl daemon-reload
systemctl enable grub-boot-repair.service

echo "GRUB Boot Repair Wizard installed successfully."
echo "Use 'grub-boot-repair --help' for usage information."
