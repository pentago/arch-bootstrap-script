#!/usr/bin/env bash
#
# Arch Linux install script — VM test variant
#
# Partition layout (whole disk, no Windows):
#   p1     — 512M  EFI System Partition (FAT32)    → /efi
#   p2     — 2G    XBOOTLDR (FAT32, label BOOT)   → /boot
#   p3     — rest  LUKS2 → ext4 (label ROOT)       → /
#   p4     — 4G    Linux swap                      → swap
#
# Bootloader: systemd-boot (ESP at p1 /efi, XBOOTLDR at p2 /boot)
# Encryption: LUKS2 aes-xts-plain64 (passphrase only)
# initramfs:  systemd-based hooks (sd-encrypt, sd-vconsole)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
DISK=/dev/vda
ESP_PART="${DISK}1"
BOOT_PART="${DISK}2"
ROOT_PART="${DISK}3"
SWAP_PART="${DISK}4"
CRYPT_NAME=cryptroot
ESP_SIZE=512M
BOOT_SIZE=2G
SWAP_SIZE=1G
HOSTNAME=workstation
TIMEZONE=Europe/Belgrade
LOCALE=en_US.UTF-8
VCONSOLE_FONT=ter-132n
USER_NAME=dzhi
USER_SHELL=/bin/zsh

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
echo "  p1: ${ESP_SIZE} ESP"
echo "  p2: ${BOOT_SIZE} boot (XBOOTLDR)"
echo "  p3: remaining space → LUKS2 → ext4 root"
echo "  p4: ${SWAP_SIZE} swap"
echo ""
read -rp "Type YES to continue: " confirm
[[ "$confirm" == "YES" ]] || {
  echo "Aborted."
  exit 1
}

read -rsp "LUKS passphrase: " LUKS_PASS
echo
read -rsp "LUKS passphrase (confirm): " LUKS_PASS2
echo
[[ "$LUKS_PASS" == "$LUKS_PASS2" ]] || {
  echo "ERROR: LUKS passphrases do not match"
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

swapoff "$SWAP_PART" 2>/dev/null || true
umount -R /mnt 2>/dev/null || true
cryptsetup close "$CRYPT_NAME" 2>/dev/null || true

sgdisk -Z "$DISK"

sgdisk \
  -n 1:0:+${ESP_SIZE} -t 1:ef00 -c 1:"EFI system partition" \
  -n 2:0:+${BOOT_SIZE} -t 2:ea00 -c 2:"Linux extended boot" \
  -n 3:0:-${SWAP_SIZE} -t 3:8300 -c 3:"Linux filesystem" \
  -n 4:0:0 -t 4:8200 -c 4:"Linux swap" \
  "$DISK"

partprobe "$DISK"
udevadm settle

# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------
echo "==> Formatting partitions"

mkfs.fat -F32 "$ESP_PART"

mkfs.fat -F32 -n BOOT "$BOOT_PART"

mkswap -L SWAP "$SWAP_PART"
swapon "$SWAP_PART"

echo "==> Setting up LUKS encryption on $ROOT_PART"
echo -n "$LUKS_PASS" | cryptsetup luksFormat --batch-mode --type luks2 \
  --cipher aes-xts-plain64 \
  --key-size 512 \
  --pbkdf argon2id \
  "$ROOT_PART"

echo -n "$LUKS_PASS" | cryptsetup open "$ROOT_PART" "$CRYPT_NAME"

mkfs.ext4 -L ROOT "/dev/mapper/${CRYPT_NAME}"

# ---------------------------------------------------------------------------
# Mount
# ---------------------------------------------------------------------------
echo "==> Mounting filesystems"

mount "/dev/mapper/${CRYPT_NAME}" /mnt
mount --mkdir "$BOOT_PART" /mnt/boot
mount --mkdir "$ESP_PART" /mnt/efi

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

if ! grep -q '^LABEL=SWAP' /mnt/etc/fstab; then
  echo "LABEL=SWAP          	none      	swap      	defaults  	0 0" >>/mnt/etc/fstab
fi

sed -i '/\/efi/s/fmask=0022,dmask=0022/fmask=0077,dmask=0077/' /mnt/etc/fstab

# ---------------------------------------------------------------------------
# chroot configuration
# ---------------------------------------------------------------------------
echo "==> Configuring system in chroot"

LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")
SWAP_UUID=$(blkid -s UUID -o value "$SWAP_PART")
[[ -z "$LUKS_UUID" ]] && { echo "ERROR: Failed to get LUKS UUID for $ROOT_PART"; exit 1; }
[[ -z "$SWAP_UUID" ]] && { echo "ERROR: Failed to get swap UUID for $SWAP_PART"; exit 1; }

arch-chroot /mnt /bin/bash -e <<CHROOT
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

echo "${LOCALE} UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

echo "FONT=${VCONSOLE_FONT}" > /etc/vconsole.conf

echo "${HOSTNAME}" > /etc/hostname

cat > /etc/mkinitcpio.conf <<'MKINIT'
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base systemd autodetect microcode modconf keyboard keymap sd-vconsole block sd-encrypt filesystems fsck)
MKINIT

mkinitcpio -P

bootctl --esp-path=/efi --boot-path=/boot install

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
options rd.luks.name=${LUKS_UUID}=${CRYPT_NAME} root=LABEL=ROOT rw resume=UUID=${SWAP_UUID}${EXTRA_CMDLINE:+ $EXTRA_CMDLINE}
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

echo "==> Installing paru and aconfmgr"
arch-chroot /mnt /bin/bash -e <<PARU
cd /tmp
su - ${USER_NAME} -c 'cd /tmp && git clone https://aur.archlinux.org/paru.git && cd paru && makepkg --noconfirm'
pacman -U --noconfirm /tmp/paru/paru-*.pkg.tar.zst
rm -rf /tmp/paru
su - ${USER_NAME} -c 'paru -S --noconfirm aconfmgr-git'
PARU

# ---------------------------------------------------------------------------
# Arch ISO boot entry
# ---------------------------------------------------------------------------
echo "==> Adding Arch ISO boot entry"
curl -L -# -o /mnt/boot/archlinux-x86_64.iso https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso
mkdir -p /tmp/archiso
mount -o loop /mnt/boot/archlinux-x86_64.iso /tmp/archiso
cp /tmp/archiso/arch/boot/x86_64/vmlinuz-linux /mnt/boot/vmlinuz-linux-archiso
cp /tmp/archiso/arch/boot/x86_64/initramfs-linux.img /mnt/boot/initramfs-linux-archiso.img
umount /tmp/archiso

cat > /mnt/boot/loader/entries/archiso.conf <<EOF
title Arch Linux ISO
linux /vmlinuz-linux-archiso
initrd /initramfs-linux-archiso.img
options img_dev=/dev/disk/by-label/BOOT img_loop=/archlinux-x86_64.iso earlymodules=loop
EOF

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
echo "  4. Clone your aconfmgr config: git clone <your-repo> ~/git/personal/aconfmgr"
echo "  4a. ln -sf ~/git/personal/aconfmgr ~/.config/aconfmgr"
echo ""
echo "  Before running 'aconfmgr apply', sync machine-specific files into the repo:"
echo ""
echo "    cp /etc/machine-id ~/.config/aconfmgr/files/etc/machine-id"
echo "    cp /etc/fstab ~/.config/aconfmgr/files/etc/fstab"
echo "    cp /etc/{passwd,shadow,group,gshadow} ~/.config/aconfmgr/files/etc/"
echo ""
echo "    # crypttab — new LUKS UUID"
echo "    echo 'cryptroot UUID=\$(blkid -s UUID -o value ${ROOT_PART}) - password-echo=no,no-read-workqueue,no-write-workqueue' \\"
echo "      > ~/.config/aconfmgr/files/etc/crypttab.initramfs"
echo ""
echo "    # arch.conf — update LUKS UUID and resume UUID for this install"
echo "    sed -i 's/rd.luks.name=[^ ]*/rd.luks.name='\$(blkid -s UUID -o value ${ROOT_PART})'=cryptroot/' \\"
echo "      ~/.config/aconfmgr/files/boot/loader/entries/arch.conf"
echo "    sed -i 's/resume=UUID=[^ ]*/resume=UUID='\$(blkid -s UUID -o value ${SWAP_PART})'/' \\"
echo "      ~/.config/aconfmgr/files/boot/loader/entries/arch.conf"
echo "    sed -i 's/ resume_offset=[^ ]*//' \\"
echo "      ~/.config/aconfmgr/files/boot/loader/entries/arch.conf"
echo ""
echo "    cd ~/.config/aconfmgr && git add -A && git commit -m 'sync for fresh install'"
echo "    aconfmgr apply"
echo ""
