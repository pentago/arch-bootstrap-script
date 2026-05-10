# AGENTS.md

## Purpose

Two scripts automate Arch Linux installation up to the point where `aconfmgr apply` takes over full system configuration.

- `install.sh` — real workstation (dual-boot Windows, nvme0n1)
- `install-vm.sh` — VM test variant (full disk wipe, /dev/vda)

## Scripts

### install.sh (workstation)

Partition layout (nvme0n1):
- p1-p4: Windows (never touched)
- p5: 5G XBOOTLDR FAT32 → `/boot` (kernels, initramfs, ISOs)
- p6: LUKS2 → ext4 → `/` (all remaining space minus swap)
- p7: 20G swap (hibernate)

ESP (p1) is shared with Windows at `/efi`. systemd-boot uses XBOOTLDR discovery for `/boot`.

Post-install output includes step-by-step instructions for:
1. Enrolling YubiKey FIDO2 on the LUKS partition
2. Syncing machine-specific files into aconfmgr before first apply (fstab, machine-id, crypttab, passwd/shadow/group/gshadow)

### install-vm.sh (VM testing)

Partition layout (vda, whole disk):
- p1: 512M ESP → `/efi`
- p2: 2G XBOOTLDR → `/boot`
- p3: LUKS2 → ext4 → `/`
- p4: 1G swap

Differences from main script:
- Creates its own ESP (no shared Windows ESP)
- Smaller boot (2G) and swap (1G)
- Enables sshd with `PermitRootLogin yes` for testing
- No YubiKey/FIDO2 instructions in post-install output
- Needs 4G+ RAM for paru source build (LTO link is memory-hungry)

## Design constraints

- **Barebones only** — no GPU drivers, no desktop, no extra kernel params. aconfmgr handles all of that post-boot.
- **Config section at top** — all tunables (disk, sizes, user, locale, packages) live in variables at the top of the script. Don't scatter magic values.
- **LUKS passphrase only** — FIDO2 enrollment happens post-install via systemd-cryptenroll, before first aconfmgr apply.
- **Passwords collected upfront** — LUKS, root, and user passwords are read with confirmation at the start, then piped non-interactively to cryptsetup/chpasswd. Never use interactive `passwd` inside heredocs.
- **initramfs uses systemd hooks** (`sd-encrypt`, `sd-vconsole`) not busybox (`encrypt`).
- **sudoers via drop-in** (`/etc/sudoers.d/wheel`), never edit `/etc/sudoers` directly.
- **paru built from source** — `paru-bin` links against specific `libalpm.so` version that mismatches on newer ISOs. `rust` is in PKGS for this reason.
- **Interactive commands outside heredocs** — `passwd`, `makepkg -si`, and anything needing stdin must run as separate `arch-chroot` calls, not inside `<<HEREDOC` blocks.

## aconfmgr integration

The aconfmgr config (`~/.config/aconfmgr`) manages several machine-specific files that must be updated after a fresh install before running `aconfmgr apply`:

| File | Why |
|------|-----|
| `/etc/fstab` | New UUIDs, swap partition instead of old swapfile |
| `/etc/machine-id` | Must be unique per install |
| `/etc/crypttab.initramfs` | New LUKS UUID, fido2-device=auto after enrollment |
| `/etc/passwd`, `/etc/shadow`, `/etc/group`, `/etc/gshadow` | New UIDs and password hashes |

aconfmgr also manages `/etc/mkinitcpio.conf` (nvidia modules, libfido2) and `/boot/loader/entries/arch.conf` (nvidia kernel params) — these are fine to overwrite since aconfmgr installs nvidia packages first.

## Editing rules

- These scripts run from a live Arch ISO as root. They will never be linted or type-checked.
- Section divider comments are intentional — the scripts are read linearly during a manual install.
- Test changes by reading the script, not by running it (destructive).
- Keep both scripts in sync for shared logic (LUKS setup, mkinitcpio hooks, bootctl flags, fstab fixups, chroot config, paru/aconfmgr install).
