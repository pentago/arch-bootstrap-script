#!/usr/bin/env bash
#
# Arch Linux install script — plain VM test variant (no LUKS, no swap)
#
# Partition layout (whole disk):
#   p1  — BOOT_SIZE  EFI System Partition (FAT32, label BOOT) → /boot
#   p2  — rest       ext4 (label ROOT)                         → /
#
# Bootloader: systemd-boot (single ESP at p1, doubles as /boot — no XBOOTLDR)
# initramfs:  systemd-based hooks (sd-vconsole)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
DISK=/dev/vda

BOOT_SIZE=512M
# Root gets remaining space after boot is carved out.

HOSTNAME=archvm
TIMEZONE=Europe/Belgrade
LOCALE=en_US.UTF-8
VCONSOLE_FONT=ter-132n

USER_NAME=dzhi
USER_SHELL=/bin/zsh

EXTRA_CMDLINE=""

# Partition suffix differs between disk naming schemes (vda1 vs nvme0n1p1).
if [[ "$DISK" =~ [0-9]$ ]]; then
  PART_PREFIX="p"
else
  PART_PREFIX=""
fi
BOOT_PART="${DISK}${PART_PREFIX}1"
ROOT_PART="${DISK}${PART_PREFIX}2"

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
  networkmanager
  terminus-font
  openssh
  sudo
  atuin
  bat
  btop
  direnv
  fd
  fzf
  git
  lazygit
  neovim
  ripgrep
  rust
  tmux
  yazi
  zoxide
  zsh
  7zip
  ntfs-3g
)

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
echo "==> Preflight checks"

[[ -d /sys/firmware/efi ]] || {
  echo "ERROR: Not booted in UEFI mode"
  exit 1
}
[[ -b "$DISK" ]] || {
  echo "ERROR: Disk $DISK not found"
  exit 1
}
[[ $(id -u) -eq 0 ]] || {
  echo "ERROR: Run as root"
  exit 1
}

echo ""
echo "This will WIPE $DISK entirely and create:"
echo "  p1: ${BOOT_SIZE} boot (ESP)"
echo "  p2: remaining space → ext4 root"
echo ""
read -rp "Type YES to continue: " confirm
[[ "$confirm" == "YES" ]] || {
  echo "Aborted."
  exit 1
}

read -rsp "Root password: " ROOT_PASS
echo
read -rsp "Root password (confirm): " ROOT_PASS2
echo
[[ "$ROOT_PASS" == "$ROOT_PASS2" ]] || {
  echo "ERROR: Root passwords do not match"
  exit 1
}

read -rsp "Password for ${USER_NAME}: " USER_PASS
echo
read -rsp "Password for ${USER_NAME} (confirm): " USER_PASS2
echo
[[ "$USER_PASS" == "$USER_PASS2" ]] || {
  echo "ERROR: User passwords do not match"
  exit 1
}

# ---------------------------------------------------------------------------
# Time sync (needed for pacman signature verification)
# ---------------------------------------------------------------------------
echo "==> Syncing time"
timedatectl set-ntp true

# ---------------------------------------------------------------------------
# Partitioning
# ---------------------------------------------------------------------------
echo "==> Partitioning $DISK"

swapoff -a 2>/dev/null || true
umount -R /mnt 2>/dev/null || true

sgdisk -Z "$DISK"

sgdisk \
  -n 1:0:+${BOOT_SIZE} -t 1:ef00 -c 1:"EFI system partition" \
  -n 2:0:0 -t 2:8304 -c 2:"Linux root" \
  "$DISK"

partprobe "$DISK"
udevadm settle

# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------
echo "==> Formatting partitions"

mkfs.fat -F32 -n BOOT "$BOOT_PART"
mkfs.ext4 -L ROOT "$ROOT_PART"

# ---------------------------------------------------------------------------
# Mount
# ---------------------------------------------------------------------------
echo "==> Mounting filesystems"

mount "$ROOT_PART" /mnt
mount --mkdir "$BOOT_PART" /mnt/boot

# ---------------------------------------------------------------------------
# Pacstrap
# ---------------------------------------------------------------------------
echo "==> Installing base system"

pacstrap -K /mnt "${PKGS[@]}"

# ---------------------------------------------------------------------------
# fstab
# ---------------------------------------------------------------------------
echo "==> Generating fstab"
genfstab -L /mnt >>/mnt/etc/fstab

sed -i '/\/boot/s/fmask=0022,dmask=0022/fmask=0077,dmask=0077/' /mnt/etc/fstab

# ---------------------------------------------------------------------------
# chroot configuration
# ---------------------------------------------------------------------------
echo "==> Configuring system in chroot"

arch-chroot /mnt /usr/bin/bash -e <<CHROOT
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

echo "${LOCALE} UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

echo "FONT=${VCONSOLE_FONT}" > /etc/vconsole.conf

echo "${HOSTNAME}" > /etc/hostname

sed -i '/^HOOKS=/c\HOOKS=(base systemd autodetect microcode modconf keyboard keymap sd-vconsole block filesystems fsck)' /etc/mkinitcpio.conf

mkinitcpio -P

bootctl --esp-path=/boot install

cat > /boot/loader/loader.conf <<'LOADER'
default arch.conf
timeout 5
console-mode auto
editor no
LOADER

cat > /boot/loader/entries/arch.conf <<EOF
title Arch Linux
linux /vmlinuz-linux
initrd /amd-ucode.img
initrd /initramfs-linux.img
options root=LABEL=ROOT rw${EXTRA_CMDLINE:+ $EXTRA_CMDLINE}
EOF

systemctl enable NetworkManager sshd

mkdir -p /etc/ssh/sshd_config.d
echo "PermitRootLogin yes" > /etc/ssh/sshd_config.d/99-root.conf

useradd -m -G wheel -s ${USER_SHELL} ${USER_NAME}

mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel
CHROOT

echo "==> Setting root password"
echo "root:${ROOT_PASS}" | arch-chroot /mnt chpasswd

echo "==> Setting password for ${USER_NAME}"
echo "${USER_NAME}:${USER_PASS}" | arch-chroot /mnt chpasswd

echo "==> Installing paru"
arch-chroot /mnt /bin/bash -e <<PARU
cd /tmp
su - ${USER_NAME} -c 'cd /tmp && git clone https://aur.archlinux.org/paru.git && cd paru && makepkg --noconfirm'
pacman -U --noconfirm /tmp/paru/paru-*.pkg.tar.zst
rm -rf /tmp/paru
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
echo "  3. Log in as ${USER_NAME} (or SSH as root)"
echo "  4. Install aconfmgr: paru -S aconfmgr-git"
echo "  5. Clone your aconfmgr config: git clone <your-repo> ~/git/personal/aconfmgr"
echo "  5a. ln -sf ~/git/personal/aconfmgr ~/.config/aconfmgr"
echo ""
echo "  Before running 'aconfmgr apply', sync machine-specific files into the repo:"
echo ""
echo "    cp /etc/machine-id ~/.config/aconfmgr/files/etc/machine-id"
echo "    cp /etc/fstab ~/.config/aconfmgr/files/etc/fstab"
echo "    cp /etc/{passwd,shadow,group,gshadow} ~/.config/aconfmgr/files/etc/"
echo ""
echo "    cd ~/.config/aconfmgr && git add -A && git commit -m 'sync for fresh install'"
echo "    aconfmgr apply"
echo ""
