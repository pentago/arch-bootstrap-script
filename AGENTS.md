# Repository Guidelines

## Project Overview

Bash scripts that install a barebones Arch Linux from a live Arch ISO (as root, UEFI only) up to the point where `aconfmgr apply` takes over full system configuration. Out of scope here: GPU drivers, desktop, extra kernel params, and everything else aconfmgr handles after first boot.

| Script | Disk | p1 ESP `/boot` | Root | Swap | `/home` | LUKS | ISO boot entry | sshd |
|---|---|---|---|---|---|---|---|---|
| `install-wipe-all.sh` | `/dev/nvme0n1` | 5G | p2 150G | p3 20G LUKS | p4 rest, LUKS | root/swap/home | no | no |
| `install-keep-home.sh` | `/dev/nvme0n1` | 5G | p2 150G | p3 20G LUKS | p4 **kept** (must already be LUKS) | root/swap/home | no | no |
| `install-vm.sh` | `/dev/vda` | 2G | p2 rest minus swap | p3 1G plain | — | root only | yes | yes, `PermitRootLogin yes` |
| `install-vm-plain.sh` | `/dev/vda` | 512M | p2 rest, plain ext4 | — | — | none | no | yes, `PermitRootLogin yes` |

`README.md` is a symlink to this file.

## Architecture & Data Flow

Every script is one linear file with `# ----` banner sections, run top to bottom:

```mermaid
flowchart LR
  A[Config vars] --> B[Preflight + YES + passwords] --> C[Cleanup + sgdisk] --> D[Format / LUKS] --> E[Mount + pacstrap -K] --> F[genfstab + ESP fmask] --> G["CHROOT heredoc"] --> H[chpasswd] --> I["PARU heredoc"] --> J["ISO entry (vm only)"] --> K[Post-install instructions]
```

- **Values flow** from the top `Config` section into unquoted heredocs (`<<CHROOT`, `<<PARU`, `<<EOF`), so `${VAR}` is expanded on the **host** before entering the chroot. Use quoted delimiters (`<<'LOADER'`) only for static content.
- **Boot**: single ESP mounted at `/boot`, `bootctl --esp-path=/boot install`, no XBOOTLDR. `arch.conf` options are just `root=LABEL=ROOT rw${EXTRA_CMDLINE:+ $EXTRA_CMDLINE}`; no `resume=` (suspend only).
- **initramfs**: systemd hooks, set with `sed -i '/^HOOKS=/c\...'` (never overwrite `mkinitcpio.conf`): `base systemd autodetect microcode modconf keyboard keymap sd-vconsole block sd-encrypt filesystems fsck` (vm-plain drops `sd-encrypt`).
- **LUKS unlock design** (two boot stages of systemd-cryptsetup-generator):
  - root → `/etc/crypttab.initramfs` (`cryptroot UUID=... - password-echo=no,...`), embedded by `sd-encrypt`; the only passphrase prompt.
  - home/swap (wipe-all, keep-home) → `/etc/crypttab` with `-` key field; random 512-byte keyfiles at `/etc/cryptsetup-keys.d/<name>.key` added as an **extra** slot via `luksAddKey` (passphrase slot kept as fallback).
  - **Never** put `rd.luks.name=`/`rd.luks.uuid=` on the cmdline: it flips the generator into allowlist mode and silently ignores other crypttab entries (broke home/swap unlock; see `e6b9dfd`, `7fb79a2`, `ceaccc9`).
- **Handoff to aconfmgr**: post-install output tells the user to install `aconfmgr-git` via paru, clone their config to `~/git/personal/aconfmgr`, symlink to `~/.config/aconfmgr`, then copy machine-specific files in before `aconfmgr apply`:

| File | Scripts | Why |
|---|---|---|
| `/etc/fstab`, `/etc/machine-id`, `/etc/{passwd,shadow,group,gshadow}` | all | new UUIDs, unique machine-id, new UIDs/hashes |
| `/etc/crypttab.initramfs` | all except vm-plain | root LUKS UUID; re-embed with `mkinitcpio -P` |
| `/etc/crypttab`, `/etc/cryptsetup-keys.d/*.key` | wipe-all, keep-home | home/swap keys; same sensitivity as `shadow` |

aconfmgr later overwrites `mkinitcpio.conf` (nvidia, libfido2) and `arch.conf` (nvidia params); FIDO2 enrollment (`systemd-cryptenroll`) happens post-install, before the first apply.

## Key Directories

Flat repo: four `install-*.sh` scripts at the root. `.omo/` is agent session state, not project content (no `.gitignore` exists; don't commit it).

## Development Commands

```bash
# Syntax check (safe)
for f in install-*.sh; do bash -n "$f" || echo "FAIL $f"; done

# Lint (safe; currently clean)
shellcheck install-*.sh

# Real run: ONLY in a throwaway UEFI VM with a virtio disk /dev/vda, booted from the Arch ISO
curl -LO <url>/install-vm.sh && chmod +x install-vm.sh && ./install-vm.sh
```

`shfmt` is not installed; if used, match the existing 2-space style (`shfmt -d -i 2`).

## Code Conventions & Common Patterns

- `#!/usr/bin/env bash` + `set -euo pipefail`; 2-space indent; `# ----` section banners are intentional (scripts are read linearly during a manual install).
- **All tunables in `Config`** at the top (`DISK`, `*_SIZE`, `HOSTNAME`, `TIMEZONE`, `LOCALE`, `VCONSOLE_FONT`, `USER_NAME`, `USER_SHELL`, `EXTRA_CMDLINE`, `PKGS`). No magic values further down.
  - Gotcha: bash pre-sets `HOSTNAME`, so `set -u` won't catch a missing `HOSTNAME=` line; the system silently gets `archiso`.
- **Partition suffix**: `PART_PREFIX="p"` when `$DISK` ends in a digit (`nvme0n1p1` vs `vda1`).
- **Passwords collected upfront**: `read -rsp` twice + compare, then piped non-interactively (`echo -n "$LUKS_PASS" | cryptsetup ...`, `echo "user:pass" | arch-chroot /mnt chpasswd`).
- **Heredoc stdin is consumed**: anything that prompts (`passwd`, `sudo`, `makepkg -si`, `paru -S`) can't run inside a heredoc. paru is built as `su - USER -c '... makepkg --noconfirm'` then installed with `pacman -U` as root. `aconfmgr-git` is deliberately a manual post-install step (sudo prompt in chroot failed twice; `5c369bd`).
- **Re-runnable**: pre-partition cleanup with `|| true` (`swapoff -a`, `umount -R /mnt`, `umount /tmp/archiso`, `cryptsetup close ...`).
- **Fail loud**: guard every `blkid` UUID: `[[ -z "$LUKS_UUID" ]] && { echo "ERROR: ..."; exit 1; }` (an empty UUID writes a silently broken crypttab).
- ESP fstab entry tightened: `fmask=0077,dmask=0077`. sudo via `/etc/sudoers.d/wheel` (0440), never `/etc/sudoers`.
- **Keep shared logic in sync** across scripts (mkinitcpio hooks, bootctl, fstab fixups, chroot config, paru build, post-install output); vm-plain intentionally lacks LUKS/swap/ISO pieces.
- Known drift to clean up when touching it: chroot shell is `/bin/bash` vs `/usr/bin/bash` inconsistently between `CHROOT`/`PARU` heredocs; header comments in `install-wipe-all.sh:9`/`install-keep-home.sh:9` (p4 description) and `install-vm.sh:7` (`ROOT_SIZE`, which vm doesn't define) don't match the code; `install-vm.sh` closes `cryptswap`/`crypthome` it never creates (harmless).

## Important Files

- `install-wipe-all.sh` — primary bare-metal install (whole disk).
- `install-keep-home.sh` — reinstall; preflight requires existing LUKS p4, `sgdisk --delete=1..3` and recreates p1–p3, re-adds home keyfile slot.
- `install-vm.sh` — VM test of the LUKS path; also adds the Arch ISO recovery boot entry (download into `/mnt/boot`, `pacman-key -v`, loop-mount at `/tmp/archiso`, copy kernel/initrd, `archiso.conf` with `img_dev=/dev/disk/by-label/BOOT img_loop=...`), run from the host, not the chroot.
- `install-vm-plain.sh` — minimal VM test: ESP + plain ext4 root (type 8304).

## Runtime/Tooling Preferences

- Runs only from a live Arch ISO: root, UEFI, network (pacstrap, AUR clone, ISO download; not pre-checked).
- Tools: `sgdisk`, `cryptsetup` (LUKS2, aes-xts-plain64, 512-bit key; root uses `--pbkdf argon2id`), `pacstrap -K`, `genfstab -L`, `arch-chroot`, `bootctl`, `mkinitcpio`, `makepkg`.
- paru is built from AUR source (`paru-bin` links a `libalpm.so` that mismatches newer ISOs), so `rust` is in `PKGS`; the LTO link needs 4G+ RAM (relevant for VMs).
- `/boot` holding the ISO entry needs ≥2G (ISO is ~1.6G); `set -e` aborts at the very end otherwise.

## Testing & QA

- No tests, no CI, no lint config. Static checks: `bash -n` and `shellcheck` (both clean).
- Never run `install-wipe-all.sh` / `install-keep-home.sh` outside a disposable VM: they erase disks. Otherwise review by reading.
- Behavioral validation: `install-vm.sh` (LUKS root, swap, ISO entry) or `install-vm-plain.sh` (no LUKS) in a UEFI VM with ≥4G RAM; then reboot and confirm the passphrase prompt (vm), login, `paru --version`.
- The VM scripts don't exercise home/swap keyfile unlock or keep-home's p4 preservation; those need a VM with an nvme-style or edited `DISK` and the bare-metal script.
