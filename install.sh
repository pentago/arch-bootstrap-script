#!/usr/bin/env bash
#
# Arch Linux install script — workstation setup
#
# Partition layout (nvme0n1):
#   p1-p4  — Windows (untouched)
#   p5     — 5G   XBOOTLDR (FAT32, label BOOT)  → /boot
#   p6     — rest LUKS2 → ext4 (label ROOT)       → /
#   p7     — 20G  Linux swap                      → swap (hibernate)
#
# Bootloader: systemd-boot (ESP at p1 /efi, XBOOTLDR at p5 /boot)
# Encryption: LUKS2 aes-xts-plain64 (passphrase only; enroll FIDO2 later)
# initramfs:  systemd-based hooks (sd-encrypt, sd-vconsole)
#
# After this script completes, boot into the new system and run aconfmgr
# to apply the full workstation configuration.
#
# Usage: boot from Arch ISO, then:
#   curl -LO <url>/install.sh && chmod +x install.sh && ./install.sh
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
DISK=/dev/nvme0n1
BOOT_PART="${DISK}p5"
ROOT_PART="${DISK}p6"
SWAP_PART="${DISK}p7"
ESP_PART="${DISK}p1"
CRYPT_NAME=cryptroot
BOOT_SIZE=5G
SWAP_SIZE=20G
HOSTNAME=workstation
TIMEZONE=Europe/Belgrade
LOCALE=en_US.UTF-8
VCONSOLE_FONT=ter-132n
USER_NAME=dzhi
USER_SHELL=/bin/zsh

# Kernel cmdline (nvidia, amd, hibernate, etc.)
# resume= and rd.luks.name= are set dynamically below
EXTRA_CMDLINE=""

PKGS=(
    base
    base-devel
    linux
    linux-headers
    linux-firmware
    amd-ucode
    dosfstools
    efibootmgr
    gptfdisk
    cryptsetup
    networkmanager
    terminus-font
    openssh
    sudo
    git
    rust
    neovim
    zsh
    tmux
    yazi
)

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
echo "==> Preflight checks"

[[ -d /sys/firmware/efi ]] || { echo "ERROR: Not booted in UEFI mode"; exit 1; }
[[ -b "$DISK" ]]           || { echo "ERROR: Disk $DISK not found"; exit 1; }
[[ $(id -u) -eq 0 ]]      || { echo "ERROR: Run as root"; exit 1; }

# Verify Windows partitions exist
for p in 1 2 3 4; do
    [[ -b "${DISK}p${p}" ]] || { echo "ERROR: Expected Windows partition ${DISK}p${p} not found"; exit 1; }
done

echo ""
echo "This will DESTROY partitions 5+ on $DISK and create:"
echo "  p5: ${BOOT_SIZE} boot (XBOOTLDR)"
echo "  p6: remaining space → LUKS2 → ext4 root"
echo "  p7: ${SWAP_SIZE} swap"
echo ""
echo "Windows partitions (p1-p4) will NOT be touched."
echo ""
read -rp "Type YES to continue: " confirm
[[ "$confirm" == "YES" ]] || { echo "Aborted."; exit 1; }

read -rsp "LUKS passphrase: " LUKS_PASS; echo
read -rsp "LUKS passphrase (confirm): " LUKS_PASS2; echo
[[ "$LUKS_PASS" == "$LUKS_PASS2" ]] || { echo "ERROR: LUKS passphrases do not match"; exit 1; }

read -rsp "Root password: " ROOT_PASS; echo
read -rsp "Root password (confirm): " ROOT_PASS2; echo
[[ "$ROOT_PASS" == "$ROOT_PASS2" ]] || { echo "ERROR: Root passwords do not match"; exit 1; }

read -rsp "Password for ${USER_NAME}: " USER_PASS; echo
read -rsp "Password for ${USER_NAME} (confirm): " USER_PASS2; echo
[[ "$USER_PASS" == "$USER_PASS2" ]] || { echo "ERROR: User passwords do not match"; exit 1; }

# ---------------------------------------------------------------------------
# Time sync (needed for pacman signature verification)
# ---------------------------------------------------------------------------
echo "==> Syncing time"
timedatectl set-ntp true

# ---------------------------------------------------------------------------
# Partitioning
# ---------------------------------------------------------------------------
echo "==> Partitioning $DISK"

swapoff "$SWAP_PART" 2>/dev/null || true
umount -R /mnt 2>/dev/null || true
cryptsetup close "$CRYPT_NAME" 2>/dev/null || true

# Delete existing Linux partitions (5+) and create new ones
sgdisk -d 5 -d 6 "$DISK" 2>/dev/null || true
# Also try deleting p7 in case it exists from a previous run
sgdisk -d 7 "$DISK" 2>/dev/null || true

sgdisk \
    -n 5:0:+${BOOT_SIZE} -t 5:ea00 -c 5:"Linux extended boot" \
    -n 6:0:-${SWAP_SIZE} -t 6:8300 -c 6:"Linux filesystem" \
    -n 7:0:0             -t 7:8200 -c 7:"Linux swap" \
    "$DISK"

# Inform kernel of partition table changes
partprobe "$DISK"
udevadm settle

# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------
echo "==> Formatting partitions"

# Boot (XBOOTLDR)
mkfs.fat -F32 -n BOOT "$BOOT_PART"

# Swap
mkswap -L SWAP "$SWAP_PART"
swapon "$SWAP_PART"

# LUKS
echo "==> Setting up LUKS encryption on $ROOT_PART"
echo -n "$LUKS_PASS" | cryptsetup luksFormat --batch-mode --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --pbkdf argon2id \
    "$ROOT_PART"

echo -n "$LUKS_PASS" | cryptsetup open "$ROOT_PART" "$CRYPT_NAME"

# Root filesystem
mkfs.ext4 -L ROOT "/dev/mapper/${CRYPT_NAME}"

# ---------------------------------------------------------------------------
# Mount
# ---------------------------------------------------------------------------
echo "==> Mounting filesystems"

mount "/dev/mapper/${CRYPT_NAME}" /mnt
mount --mkdir "$BOOT_PART" /mnt/boot
mount --mkdir "$ESP_PART" /mnt/efi

# ---------------------------------------------------------------------------
# Pacstrap — minimal set to boot + run aconfmgr
# ---------------------------------------------------------------------------
echo "==> Installing base system"

pacstrap -K /mnt "${PKGS[@]}"

# ---------------------------------------------------------------------------
# fstab
# ---------------------------------------------------------------------------
echo "==> Generating fstab"
genfstab -L /mnt >> /mnt/etc/fstab

# Add swap entry if not already present
if ! grep -q '^LABEL=SWAP' /mnt/etc/fstab; then
    echo "LABEL=SWAP          	none      	swap      	defaults  	0 0" >> /mnt/etc/fstab
fi

# Fix ESP mount options (restrict permissions)
sed -i '/\/efi/s/fmask=0022,dmask=0022/fmask=0077,dmask=0077/' /mnt/etc/fstab

# ---------------------------------------------------------------------------
# chroot configuration
# ---------------------------------------------------------------------------
echo "==> Configuring system in chroot"

# Get the LUKS UUID for kernel cmdline
LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")
SWAP_UUID=$(blkid -s UUID -o value "$SWAP_PART")

arch-chroot /mnt /bin/bash -e <<CHROOT
# Timezone
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# Locale
echo "${LOCALE} UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# Console font
echo "FONT=${VCONSOLE_FONT}" > /etc/vconsole.conf

# Hostname
echo "${HOSTNAME}" > /etc/hostname

# mkinitcpio — systemd-based with sd-encrypt
cat > /etc/mkinitcpio.conf <<'MKINIT'
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base systemd autodetect microcode modconf keyboard keymap sd-vconsole block sd-encrypt filesystems fsck)
MKINIT

mkinitcpio -P

# systemd-boot
bootctl --esp-path=/efi --boot-path=/boot install

# Boot loader config
cat > /boot/loader/loader.conf <<'LOADER'
default arch.conf
timeout 5
console-mode auto
editor no
LOADER

# Boot entry
cat > /boot/loader/entries/arch.conf <<EOF
title Arch Linux
linux /vmlinuz-linux
initrd /amd-ucode.img
initrd /initramfs-linux.img
options rd.luks.name=${LUKS_UUID}=${CRYPT_NAME} root=LABEL=ROOT rw resume=UUID=${SWAP_UUID} ${EXTRA_CMDLINE}
EOF

# Arch ISO boot entry
curl -L -o /boot/archlinux-x86_64.iso https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso
mkdir -p /tmp/archiso
mount -o loop /boot/archlinux-x86_64.iso /tmp/archiso
cp /tmp/archiso/arch/boot/x86_64/vmlinuz-linux /boot/vmlinuz-linux-archiso
cp /tmp/archiso/arch/boot/x86_64/initramfs-linux.img /boot/initramfs-linux-archiso.img
umount /tmp/archiso

cat > /boot/loader/entries/archiso.conf <<EOF
title Arch Linux ISO
linux /vmlinuz-linux-archiso
initrd /initramfs-linux-archiso.img
options img_dev=/dev/disk/by-label/BOOT img_loop=/archlinux-x86_64.iso earlymodules=loop
EOF

# Enable NetworkManager
systemctl enable NetworkManager

# Create user (same as current)
useradd -m -G wheel -s ${USER_SHELL} ${USER_NAME}

# Allow wheel group sudo
mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel
CHROOT

echo "==> Setting root password"
echo "root:${ROOT_PASS}" | arch-chroot /mnt chpasswd

echo "==> Setting password for ${USER_NAME}"
echo "${USER_NAME}:${USER_PASS}" | arch-chroot /mnt chpasswd

echo "==> Installing paru and aconfmgr"
arch-chroot /mnt /bin/bash -e <<PARU
cd /tmp
su - ${USER_NAME} -c 'cd /tmp && git clone https://aur.archlinux.org/paru.git && cd paru && makepkg --noconfirm'
pacman -U --noconfirm /tmp/paru/paru-*.pkg.tar.zst
rm -rf /tmp/paru
su - ${USER_NAME} -c 'paru -S --noconfirm aconfmgr-git'
PARU

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "========================================="
echo "  Installation complete!"
echo "========================================="
echo ""
echo "Next steps:"
echo "  1. umount -R /mnt"
echo "  2. reboot"
echo "  3. Log in as ${USER_NAME}"
echo "  4. Enroll YubiKey FIDO2 for LUKS unlock:"
echo "    sudo systemd-cryptenroll ${ROOT_PART} --fido2-device=auto"
echo ""
echo "  5. Clone your aconfmgr config: git clone <your-repo> ~/git/personal/aconfmgr"
echo "  5a. ln -sf ~/git/personal/aconfmgr ~/.config/aconfmgr"
echo ""
echo "  Before running 'aconfmgr apply', copy machine-specific files into the repo:"
echo ""
echo "    # Machine-unique ID (must not be shared across installs)"
echo "    cp /etc/machine-id ~/.config/aconfmgr/files/etc/machine-id"
echo ""
echo "    # fstab — new UUIDs, swap partition instead of swapfile"
echo "    cp /etc/fstab ~/.config/aconfmgr/files/etc/fstab"
echo ""
echo "    # User/password databases — UIDs and hashes from this install"
echo "    cp /etc/{passwd,shadow,group,gshadow} ~/.config/aconfmgr/files/etc/"
echo ""
echo "    # crypttab — new LUKS UUID (fido2-device=auto works since YubiKey is already enrolled)"
echo "    echo 'cryptroot UUID=\$(blkid -s UUID -o value ${ROOT_PART}) - fido2-device=auto,password-echo=no,no-read-workqueue,no-write-workqueue' \\"
echo "      > ~/.config/aconfmgr/files/etc/crypttab.initramfs"
echo ""
echo "    # Commit, then apply"
echo "    cd ~/.config/aconfmgr && git add -A && git commit -m 'sync for fresh install'"
echo "    aconfmgr apply"
echo ""
