# AGENTS.md

## Purpose

Two scripts automate Arch Linux installation up to the point where `aconfmgr apply` takes over full system configuration. Both scripts also drop an Arch ISO recovery boot entry into `/boot` as their final step.

- `install.sh` — real workstation (dual-boot Windows, nvme0n1)
- `install-vm.sh` — VM test variant (full disk wipe, /dev/vda)

## Scripts

### install.sh (workstation)

Partition layout (nvme0n1):
- p1-p4: Windows (never touched)
- p5: 5G XBOOTLDR FAT32 → `/boot` (kernels, initramfs, ISOs)
- p6: LUKS2 → ext4 → `/` (all remaining space minus swap)
- p7: 20G swap partition (hibernate)

ESP (p1) is shared with Windows at `/efi`. systemd-boot uses XBOOTLDR discovery for `/boot`.

Post-install output includes step-by-step instructions for:
1. Enrolling YubiKey FIDO2 on the LUKS partition
2. Syncing machine-specific files into aconfmgr before first apply
3. Updating `arch.conf` UUIDs and removing swapfile `resume_offset`

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
- **Pre-partition cleanup** — both scripts swapoff, umount `/mnt`, and close any open LUKS before partitioning, so they can be re-run safely.
- **ISO boot entry outside chroot** — the Arch ISO download, extraction, and boot entry creation operate on `/mnt/boot/` directly from the live environment, not inside a chroot heredoc.
- **blkid guarded** — UUID extraction aborts with a clear error if blkid returns empty, preventing broken boot entries.

## aconfmgr integration

The aconfmgr config (`~/.config/aconfmgr`) manages several machine-specific files that must be updated after a fresh install before running `aconfmgr apply`. Both scripts print the exact commands in their post-install output.

| File | Why | How |
|------|-----|-----|
| `/etc/fstab` | New UUIDs, swap partition instead of old swapfile | `cp /etc/fstab` |
| `/etc/machine-id` | Must be unique per install | `cp /etc/machine-id` |
| `/etc/crypttab.initramfs` | New LUKS UUID, fido2-device=auto after enrollment | Generate with `echo` + `blkid` |
| `/etc/passwd`, `/etc/shadow`, `/etc/group`, `/etc/gshadow` | New UIDs and password hashes | `cp /etc/{passwd,shadow,group,gshadow}` |
| `/boot/loader/entries/arch.conf` | LUKS UUID, swap UUID, remove swapfile `resume_offset` | `sed` the UUIDs, strip `resume_offset` |

aconfmgr also manages `/etc/mkinitcpio.conf` (nvidia modules, libfido2) and the rest of `arch.conf` (nvidia kernel params) — these are fine to overwrite since aconfmgr installs nvidia packages first.

## Editing rules

- These scripts run from a live Arch ISO as root. They will never be linted or type-checked.
- Section divider comments are intentional — the scripts are read linearly during a manual install.
- Test changes by reading the script, not by running it (destructive).
- Keep both scripts in sync for shared logic (LUKS setup, mkinitcpio hooks, bootctl flags, fstab fixups, chroot config, paru/aconfmgr install, ISO boot entry, post-install instructions).
