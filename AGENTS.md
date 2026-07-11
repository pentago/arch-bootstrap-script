# AGENTS.md

## Purpose

Scripts to automate Arch Linux installation up to the point where `aconfmgr apply` takes over full system configuration. Both drop an Arch ISO recovery boot entry into `/boot` as their final step.

- `install.sh` — Custom partitions variant (whole disk wipe, disk-agnostic, LUKS on root/swap/home)
- `install-vm.sh` — VM test variant (whole disk wipe, /dev/vda, plain swap, sshd enabled)

## Scripts

### install.sh (custom partitions)

Partition layout (whole disk, no Windows):
- p1: `BOOT_SIZE` ESP (FAT32) → `/boot` (single partition, no XBOOTLDR split)
- p2: `ROOT_SIZE` LUKS2 → ext4 (label ROOT) → `/`
- p3: `SWAP_SIZE` LUKS2 → swap
- p4: remaining space (elastic, absorbs what's left) LUKS2 → ext4 (label HOME) → `/home`

All sizes are config variables at the top. `/home` is elastic via sgdisk negative-size trick.

Key traits:
- Disk-agnostic: derives `p`-vs-no-`p` suffix from whether `$DISK` ends in a digit
- Two-file crypttab split, matching the systemd-cryptsetup-generator boot stages:
  - **root** → `/etc/crypttab.initramfs` (`cryptroot UUID=... -`), which `sd-encrypt` embeds into the initramfs image and unlocks before switch-root. This is the only passphrase prompt. No `rd.luks.name=`/`rd.luks.uuid=` on the kernel cmdline — setting one would flip the generator into allowlist mode, silently ignoring any crypttab entry not also named on the cmdline (this is what broke home/swap unlock during development; see git history)
  - **home/swap** → plain `/etc/crypttab` (`crypthome UUID=... -`, `cryptswap UUID=... -`), processed by the regular systemd instance after switch-root (real root already mounted). Each gets a random keyfile (`dd if=/dev/urandom`) added as an *extra* LUKS key slot via `cryptsetup luksAddKey` — the original passphrase slot from `luksFormat` is never removed, so both the keyfile and the LUKS passphrase unlock either volume. Keyfiles are named `/etc/cryptsetup-keys.d/<volume-name>.key`, matching crypttab(5)'s documented auto-discovery convention (hence the `-` in the key-file field) — keyfile tried first (silent), falls back to an interactive passphrase prompt if it's ever missing/unreadable. Keyfiles live on the root filesystem, only readable once root itself is decrypted
  - `arch.conf`'s kernel cmdline carries no LUKS-related params at all — just `root=LABEL=ROOT rw`
- `bootctl --esp-path=/boot install` (single ESP, no XBOOTLDR)
- No `resume=` in arch.conf (suspend-only, no hibernation)
- No ISO boot entry section (removed on rewrite)
- blkid guarded for all three LUKS UUIDs (root/home/swap) — an empty UUID would silently produce a broken crypttab entry, with no error at install time

### install-vm.sh (VM testing)

Partition layout (vda, whole disk):
- p1: 512M ESP → `/efi`
- p2: 2G XBOOTLDR (FAT32, label BOOT) → `/boot`
- p3: LUKS2 → ext4 (label ROOT) → `/`
- p4: 1G plain swap (not LUKS-encrypted)

Key traits:
- Separate ESP + XBOOTLDR (`bootctl --esp-path=/efi --boot-path=/boot`)
- Plain swap with `mkswap -L SWAP` + `swapon` (no LUKS)
- `resume=UUID=` in arch.conf (hibernation enabled)
- blkid guarded: `[[ -z "$LUKS_UUID" ]] && { echo "ERROR: ..."; exit 1; }`
- Enables sshd with `PermitRootLogin yes` for testing
- Has Arch ISO boot entry section (download + extract + boot entry)
- No YubiKey/FIDO2 instructions in post-install output
- Needs 4G+ RAM for paru source build (LTO link is memory-hungry)
- Post-install: single crypttab entry (root only), sed for both LUKS UUID and resume UUID

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
- **blkid guarded** — UUID extraction aborts with a clear error if blkid returns empty (both scripts).

## aconfmgr integration

The aconfmgr config (`~/.config/aconfmgr`) manages several machine-specific files that must be updated after a fresh install before running `aconfmgr apply`. Both scripts print the exact commands in their post-install output.

| File | Why | How |
|------|-----|-----|
| `/etc/fstab` | New UUIDs, swap partition instead of old swapfile | `cp /etc/fstab` |
| `/etc/machine-id` | Must be unique per install | `cp /etc/machine-id` |
| `/etc/passwd`, `/etc/shadow`, `/etc/group`, `/etc/gshadow` | New UIDs and password hashes | `cp /etc/{passwd,shadow,group,gshadow}` |
| `/boot/loader/entries/arch.conf` | install-vm.sh only — root LUKS UUID (+ resume UUID for hibernation) | `sed` the `rd.luks.name=...=cryptroot` and `resume=UUID=` params |
| `/etc/crypttab.initramfs` | install.sh only — root LUKS UUID (arch.conf carries no LUKS params there) | `cp` as-is, then `mkinitcpio -P` to re-embed |
| `/etc/crypttab`, `/etc/cryptsetup-keys.d/*.key` | install.sh only — home/swap unlock keys, sensitive (same trust level as shadow) | `cp` as-is, no templating needed (already correct for this install) |

aconfmgr also manages `/etc/mkinitcpio.conf` (nvidia modules, libfido2) and the rest of `arch.conf` (nvidia kernel params) — these are fine to overwrite since aconfmgr installs nvidia packages first.

## Editing rules

- These scripts run from a live Arch ISO as root. They will never be linted or type-checked.
- Section divider comments are intentional — the scripts are read linearly during a manual install.
- Test changes by reading the script, not by running it (destructive).
- Keep both scripts in sync for shared logic (LUKS setup, mkinitcpio hooks, bootctl flags, fstab fixups, chroot config, paru/aconfmgr install, post-install instructions).
