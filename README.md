# openSUSE Tumbleweed for Xiaomi Pad 6 (pipa)

Builds flashable Tumbleweed images (GNOME, Plasma, Plasma Mobile).
Device packages come from [pipa-pkgs](https://thespider2.github.io/pipa-pkgs/repo/opensuse/).

## Build (CI or local ARM64)

```bash
make builder
make gnome            # or plasma / plasma-mobile / all
```

Images land in `images/`. Override the package repo with `PIPA_REPO_URL=…`.

GitHub Actions builds all three desktops on `ubuntu-24.04-arm` and uploads ZIP artifacts.

## Flash

1. Unlock the bootloader.
2. Extract the ZIP and run `./flash.sh` (or `./flash-multiboot.sh`).

| Image | Partition |
|-------|-----------|
| `silicium.img` | `boot_ab` |
| `opensuse_esp.raw` | `rawdump` |
| `opensuse_boot.raw` | `cust` |
| `opensuse_rootfs.raw` | `userdata` |

## First boot

- **GNOME:** GDM runs `gnome-initial-setup` (create your user). Root password is `opensuse` for SSH/recovery.
- **Plasma / Plasma Mobile:** root autologins once, shows a create-user dialog, then reboots to the normal login screen.

GNOME images install core apps (Files, Console, Text Editor, Calculator, Software, …) plus Noto/Cantarell/Liberation fonts so Firefox text renders correctly.
