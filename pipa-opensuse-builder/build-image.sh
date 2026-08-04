#!/bin/bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: build-image.sh [gnome|plasma|plasma-mobile]

Build an openSUSE Tumbleweed image for Xiaomi Pad 6 (Pipa).

Environment variables:
  PIPA_REPO_URL          zypper repo URL (default: thespider2 pipa-pkgs opensuse)
  PIPA_INCLUDE_SENSORS   Include sensor packages (default: 1)
  BUILD_GIT_REV          Git revision stamped into build metadata
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "You must be root to run this script."
    exit 1
fi

DE_NAME="${1:-plasma}"
DATE=$(date +%Y%m%d)
# zypper --installroot/--root requires an absolute path.
BUILD_ROOT="$(pwd)"
ROOTFS_DIR="$BUILD_ROOT/rootfs"
IMAGE_DIR="$BUILD_ROOT/images"
IMAGE_MNT="$BUILD_ROOT/mnt_image"
ESP_MNT="$BUILD_ROOT/mnt_esp"
BOOT_MNT="$BUILD_ROOT/mnt_boot"
IMAGE_NAME="opensuse-pipa-${DE_NAME}-${DATE}"
ROOTFS_LABEL="suse-pipa"
BOOT_LABEL="boot"
ESP_LABEL="SUSEPIPAESP"
TARGET_KERNEL_CMDLINE="root=LABEL=$ROOTFS_LABEL rw rootwait boot=LABEL=$BOOT_LABEL console=tty0 console=ttyS0 earlycon quiet splash"
EFI_TEMPLATE_DIR="$BUILD_ROOT/efi-template"
VBMETA_IMG="$BUILD_ROOT/vbmeta.img"
PIPA_REPO_URL="${PIPA_REPO_URL:-https://thespider2.github.io/pipa-pkgs/repo/opensuse/}"
SILICIUM_URL="https://github.com/onesaladleaf/Mu-Silicium/releases/download/v3.5-pocketblue/Mu-pipa.img"
SILICIUM_SHA256="ea3e1e123beea7ee5394295bdfee75054711d4734e9403831fda7f037fc900b6"
PIPA_INCLUDE_SENSORS="${PIPA_INCLUDE_SENSORS:-1}"
BUILD_GIT_REV="${BUILD_GIT_REV:-unknown}"
ESP_SIZE_MB=128
BOOT_SIZE_MB=1024

PIPA_PACKAGES=(
    pipa-metapkg
    kernel-pipa
    kernel-pipa-modules
    xiaomi-pipa-firmware
    pipa-dracut
    pipa-grub-config
    pipa-sound-conf
    bootmac
    swclock-offset
    qrtr
    pd-mapper
)
# Not published for TW yet; install if available.
OPTIONAL_PIPA_PACKAGES=(
    tqftpserv
    rmtfs
)
if [ "$PIPA_INCLUDE_SENSORS" = "1" ]; then
    PIPA_PACKAGES+=(hexagonrpc iio-sensor-proxy libssc pipa-sensors)
fi

cleanup() {
    target_umount_all || true
    if mountpoint -q "$IMAGE_MNT" 2>/dev/null; then umount "$IMAGE_MNT" || true; fi
    if mountpoint -q "$ESP_MNT" 2>/dev/null; then umount "$ESP_MNT" || true; fi
    if mountpoint -q "$BOOT_MNT" 2>/dev/null; then umount "$BOOT_MNT" || true; fi
    if mountpoint -q "$ROOTFS_DIR/boot" 2>/dev/null; then umount "$ROOTFS_DIR/boot" || true; fi
}
trap cleanup EXIT

target_mount() {
    mkdir -p "$ROOTFS_DIR"/{proc,sys,dev,dev/pts,run}
    mount --bind /proc "$ROOTFS_DIR/proc"
    mount --bind /sys "$ROOTFS_DIR/sys"
    mount --bind /dev "$ROOTFS_DIR/dev"
    mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"
    mount -t tmpfs tmpfs "$ROOTFS_DIR/run"
}

target_umount_all() {
    for m in run dev/pts dev sys proc; do
        if mountpoint -q "$ROOTFS_DIR/$m" 2>/dev/null; then
            umount "$ROOTFS_DIR/$m" || umount -l "$ROOTFS_DIR/$m" || true
        fi
    done
}

target_chroot() {
    chroot "$ROOTFS_DIR" "$@"
}

first_existing_file() {
    local candidate
    for candidate in "$@"; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

assert_required_rootfs_files() {
    local file_path
    for file_path in "$@"; do
        if [ ! -f "$ROOTFS_DIR/$file_path" ]; then
            echo "Missing required rootfs file: $file_path" >&2
            exit 1
        fi
    done
}

# openSUSE ships many firmware blobs as .xz/.zst; the kernel loads them compressed.
assert_required_firmware() {
    local file_path candidate found
    for file_path in "$@"; do
        found=0
        for candidate in \
            "$ROOTFS_DIR/$file_path" \
            "$ROOTFS_DIR/$file_path.xz" \
            "$ROOTFS_DIR/$file_path.zst" \
            "$ROOTFS_DIR/$file_path.gz"
        do
            if [ -e "$candidate" ]; then
                found=1
                break
            fi
        done
        if [ "$found" -ne 1 ]; then
            echo "Missing required firmware: $file_path (.xz/.zst also accepted)" >&2
            ls -la "$ROOTFS_DIR/$(dirname "$file_path")" 2>/dev/null || true
            exit 1
        fi
    done
}

write_placeholder_initramfs() {
    local out="$1"
    printf '\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03' > "$out"
    printf '\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00' >> "$out"
}

write_uefi_csv() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import pathlib, sys
csv_path, entry_image, title, description = sys.argv[1:5]
text = f"{entry_image},{title},,{description}\r\n"
pathlib.Path(csv_path).write_bytes(b"\xff\xfe" + text.encode("utf-16le"))
PY
}

mkdir -p "$IMAGE_DIR/$IMAGE_NAME" "$IMAGE_MNT" "$ESP_MNT" "$BOOT_MNT"
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

if [ ! -f "$EFI_TEMPLATE_DIR/EFI/BOOT/BOOTAA64.EFI" ] || [ ! -f "$EFI_TEMPLATE_DIR/EFI/opensuse/grubaa64.efi" ]; then
    echo "Missing EFI template files in $EFI_TEMPLATE_DIR" >&2
    exit 1
fi
if [ ! -f "$VBMETA_IMG" ]; then
    echo "Missing vbmeta image: $VBMETA_IMG" >&2
    exit 1
fi

BASE_PACKAGES=(
    patterns-base-minimal_base
    patterns-base-basesystem
    zypper
    systemd
    sudo
    shadow
    NetworkManager
    Mesa-dri
    kernel-firmware-qcom
    kernel-firmware-ath11k
    kernel-firmware-bluetooth
    alsa-utils
    pipewire
    pipewire-pulseaudio
    wireplumber
    upower
    ModemManager
    xdg-user-dirs
    nano
    vim
    git
    wget
    rsync
    openssh
    hostname
    timezone
    dracut
    grub2
    which
    python313
    bluez
    device-mapper
    # Minimal images often skip Recommends; pin fonts so Firefox/UI text is not tofu.
    cantarell-fonts
    dejavu-fonts
    liberation-fonts
    google-noto-sans-fonts
    google-noto-serif-fonts
    google-noto-sans-mono-fonts
    google-noto-coloremoji-fonts
)

case "$DE_NAME" in
    plasma)
        DESKTOP_PACKAGES=(
            patterns-kde-kde
            sddm
            plasma6-session
            plasma6-desktop
            konsole
            dolphin
            MozillaFirefox
            flatpak
            xdg-desktop-portal-kde6
            kdialog
        )
        DISPLAY_MANAGER="sddm"
        ;;
    gnome)
        # patterns-gnome-gnome alone is thin when solver.onlyRequires=true.
        # Pull recommends + explicit core apps so the desktop is usable.
        DESKTOP_PACKAGES=(
            patterns-gnome-gnome
            patterns-gnome-gnome_basic
            patterns-gnome-gnome_utilities
            patterns-gnome-gnome_imaging
            patterns-gnome-gnome_multimedia
            gdm
            gnome-shell
            gnome-session-wayland
            gnome-control-center
            gnome-console
            gnome-terminal
            nautilus
            gnome-text-editor
            gnome-calculator
            gnome-calendar
            gnome-characters
            gnome-clocks
            gnome-contacts
            gnome-maps
            gnome-weather
            gnome-system-monitor
            gnome-disk-utility
            gnome-logs
            gnome-software
            gnome-tweaks
            gnome-backgrounds
            gnome-initial-setup
            loupe
            evince
            file-roller
            snapshot
            baobab
            sushi
            ibus
            MozillaFirefox
            flatpak
            xdg-desktop-portal-gnome
        )
        DISPLAY_MANAGER="gdm"
        ;;
    plasma-mobile)
        DESKTOP_PACKAGES=(
            plasma6-mobile
            plasma6-session
            sddm
            maliit-keyboard
            konsole
            MozillaFirefox
            flatpak
            xdg-desktop-portal-kde6
            kdialog
        )
        DISPLAY_MANAGER="sddm"
        ;;
    *)
        echo "Unsupported desktop environment: $DE_NAME" >&2
        exit 1
        ;;
esac

echo "### Seeding cmdline and placeholder initramfs..."
install -d "$ROOTFS_DIR/etc" "$ROOTFS_DIR/boot"
printf '%s\n' "$TARGET_KERNEL_CMDLINE" > "$ROOTFS_DIR/etc/cmdline"
printf '%s\n' "$TARGET_KERNEL_CMDLINE" > "$ROOTFS_DIR/boot/cmdline.txt"
write_placeholder_initramfs "$ROOTFS_DIR/boot/initramfs.img"

echo "### Bootstrapping openSUSE Tumbleweed rootfs..."
mkdir -p "$ROOTFS_DIR/etc/zypp/repos.d" "$ROOTFS_DIR/etc/zypp"
if [ -d /etc/zypp/repos.d ]; then
    cp -a /etc/zypp/repos.d/. "$ROOTFS_DIR/etc/zypp/repos.d/"
fi
if [ -f /etc/zypp/zypp.conf ]; then
    cp -a /etc/zypp/zypp.conf "$ROOTFS_DIR/etc/zypp/zypp.conf"
fi
# Container/minimal zypp.conf often sets solver.onlyRequires=true, which drops
# pattern Recommends (GNOME core apps, Noto fonts, etc.). Force recommends on.
mkdir -p "$ROOTFS_DIR/etc/zypp"
if [ -f "$ROOTFS_DIR/etc/zypp/zypp.conf" ]; then
    if grep -q '^solver.onlyRequires' "$ROOTFS_DIR/etc/zypp/zypp.conf"; then
        sed -i 's/^solver.onlyRequires.*/solver.onlyRequires = false/' \
            "$ROOTFS_DIR/etc/zypp/zypp.conf"
    else
        printf '\n## pipa image: install pattern Recommends\nsolver.onlyRequires = false\n' \
            >> "$ROOTFS_DIR/etc/zypp/zypp.conf"
    fi
else
    printf '## pipa image\nsolver.onlyRequires = false\n' > "$ROOTFS_DIR/etc/zypp/zypp.conf"
fi

echo "### Verifying pipa-pkgs repo at $PIPA_REPO_URL ..."
if ! curl -fsSL "${PIPA_REPO_URL%/}/repodata/repomd.xml" -o /tmp/pipa-repomd.xml; then
    echo "Pipa repo metadata not reachable: ${PIPA_REPO_URL%/}/repodata/repomd.xml" >&2
    exit 1
fi

# Register explicitly. Dropping a .repo file alone is not always enough with
# --installroot when host zypp.conf/services dominate discovery.
zypper --non-interactive --installroot "$ROOTFS_DIR" removerepo pipa-pkgs 2>/dev/null || true
zypper --non-interactive --installroot "$ROOTFS_DIR" addrepo -f -G \
    -n "Pipa Packages for Xiaomi Pad 6" \
    "$PIPA_REPO_URL" pipa-pkgs
zypper --non-interactive --installroot "$ROOTFS_DIR" modifyrepo -p 50 pipa-pkgs

# Skip flaky/unneeded repos on GHA aarch64 (timeouts on non-oss/openh264).
zypper --non-interactive --installroot "$ROOTFS_DIR" modifyrepo -d \
    repo-non-oss repo-openh264 2>/dev/null || true

# Prefer the CDN backend; download.opensuse.org redirects can 404 mid-snapshot.
if [ -d "$ROOTFS_DIR/etc/zypp/repos.d" ]; then
    sed -i \
        -e 's|http://download.opensuse.org/|https://downloadcontent.opensuse.org/|g' \
        -e 's|https://download.opensuse.org/|https://downloadcontent.opensuse.org/|g' \
        "$ROOTFS_DIR"/etc/zypp/repos.d/*.repo 2>/dev/null || true
fi

zypper --non-interactive --installroot "$ROOTFS_DIR" --gpg-auto-import-keys refresh
zypper --non-interactive --installroot "$ROOTFS_DIR" repos -up

if ! zypper --non-interactive --installroot "$ROOTFS_DIR" search -x bootmac | grep -q bootmac; then
    echo "pipa-pkgs repo is enabled but bootmac is still invisible; aborting" >&2
    zypper --non-interactive --installroot "$ROOTFS_DIR" repos -up || true
    exit 1
fi

# Image uses kernel-pipa. Stock TW kernels are useless here and often break the
# build when oss metadata/CDN lag (zypper wants kernel-default-X which 404s).
# After locking kernel-default, the solver can still pick kernel-64kb (aarch64
# 64KB-page flavor) because it Provides a newer kernel= than kernel-pipa.
echo "### Locking stock kernels (use kernel-pipa)..."
zypper --non-interactive --installroot "$ROOTFS_DIR" al \
    'kernel-default*' \
    'kernel-64kb*' \
    'kernel-rt*' \
    'kernel-kvmsmall*' \
    'kernel-zfcpdump*' \
    kernel-source \
    kernel-syms \
    kernel-obs-build || true

# Install device kernel first so its Provides(kernel=...) is visible before
# desktop patterns try to pull a stock TW kernel.
echo "### Installing kernel-pipa before desktop stack..."
zypper_install() {
    local attempt=1
    local max_attempts=3
    while true; do
        if zypper --non-interactive --installroot "$ROOTFS_DIR" install \
            --recommends --force-resolution -y "$@"; then
            return 0
        fi
        if [ "$attempt" -ge "$max_attempts" ]; then
            return 1
        fi
        echo "zypper install failed (attempt $attempt/$max_attempts); refreshing and retrying..." >&2
        zypper --non-interactive --installroot "$ROOTFS_DIR" refresh || true
        attempt=$((attempt + 1))
        sleep 5
    done
}

zypper_install kernel-pipa kernel-pipa-modules xiaomi-pipa-firmware

zypper_install \
    "${BASE_PACKAGES[@]}" \
    "${DESKTOP_PACKAGES[@]}" \
    "${PIPA_PACKAGES[@]}"

rpm --root "$ROOTFS_DIR" -q kernel-firmware-qcom kernel-firmware-ath11k kernel-pipa kernel-pipa-modules

# Refuse any stock kernel sneaking in despite locks.
STOCK_KERNELS="$(rpm --root "$ROOTFS_DIR" -qa 'kernel-default*' 'kernel-64kb*' 'kernel-rt*' 'kernel-kvmsmall*' 2>/dev/null || true)"
if [ -n "$STOCK_KERNELS" ]; then
    echo "Stock TW kernel packages were installed; removing:" >&2
    echo "$STOCK_KERNELS" >&2
    # shellcheck disable=SC2086
    zypper --non-interactive --installroot "$ROOTFS_DIR" rm -y $STOCK_KERNELS || true
fi

if [ ${#OPTIONAL_PIPA_PACKAGES[@]} -gt 0 ]; then
    zypper --non-interactive --installroot "$ROOTFS_DIR" --no-refresh install --recommends -y \
        "${OPTIONAL_PIPA_PACKAGES[@]}" || true
fi

# Soft-install extra GNOME bits that may rename between TW snapshots.
if [ "$DE_NAME" = "gnome" ]; then
    zypper --non-interactive --installroot "$ROOTFS_DIR" --no-refresh install --recommends -y \
        gnome-papers eog || true
fi

echo "### Validating Pipa packages..."
assert_required_rootfs_files \
    "usr/local/bin/pipa-refresh-grub-config" \
    "usr/share/alsa/ucm2/conf.d/sm8250/Xiaomi Pad 6.conf" \
    "usr/lib/dracut/dracut.conf.d/10-pipa.conf"

echo "### Locale / keymap..."
echo 'LANG=C.UTF-8' > "$ROOTFS_DIR/etc/locale.conf"
echo 'KEYMAP=us' > "$ROOTFS_DIR/etc/vconsole.conf"

echo "### SSH: allow password login (incl. root) for tablet recovery..."
install -d "$ROOTFS_DIR/etc/ssh/sshd_config.d"
# Upstream default is PermitRootLogin prohibit-password, which rejects root:opensuse
# over SSH even though PasswordAuthentication is on.
cat > "$ROOTFS_DIR/etc/ssh/sshd_config.d/10-pipa.conf" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
EOF

echo "### fstab..."
cat > "$ROOTFS_DIR/etc/fstab" <<EOF
LABEL=$ROOTFS_LABEL / ext4 defaults,x-systemd.growfs 0 1
LABEL=$BOOT_LABEL /boot ext4 defaults 0 2
EOF

echo "### Root password (root:opensuse) and sudo..."
target_mount
echo 'root:opensuse' | target_chroot chpasswd
# openSUSE ships Defaults targetpw in /usr/etc/sudoers, which makes sudo ask
# for *root's* password. Disable that so wheel users authenticate as themselves.
cat > "$ROOTFS_DIR/etc/sudoers.d/10-pipa-wheel" <<'EOF'
Defaults !targetpw
Defaults !rootpw
%wheel ALL=(ALL:ALL) ALL
EOF
chmod 0440 "$ROOTFS_DIR/etc/sudoers.d/10-pipa-wheel"
rm -f "$ROOTFS_DIR/etc/sudoers.d/wheel"
target_chroot getent group wheel >/dev/null 2>&1 || target_chroot groupadd -r wheel || true

echo "### First-boot user setup..."
# openSUSE GDM defaults to InitialSetupEnable=False, which skips the wizard and
# shows a username prompt with no users to pick. Re-enable native GIS for GNOME.
# Plasma gets an Endeavour-style create-user dialog via root autologin.
if [ "$DE_NAME" = "gnome" ]; then
    # GIS only runs when there are no local users with UID >= 1000.
    if [ -f "$ROOTFS_DIR/etc/passwd" ]; then
        while IFS=: read -r _pw_user _ _pw_uid _; do
            case "$_pw_uid" in
                ''|*[!0-9]*) continue ;;
            esac
            if [ "$_pw_uid" -ge 1000 ] && [ "$_pw_uid" -lt 65534 ]; then
                echo "Removing pre-created user '$_pw_user' (uid $_pw_uid) so GNOME initial setup can run..."
                target_chroot userdel -r "$_pw_user" 2>/dev/null || \
                    target_chroot userdel "$_pw_user" 2>/dev/null || true
            fi
        done < "$ROOTFS_DIR/etc/passwd"
    fi
    install -d "$ROOTFS_DIR/etc/gdm"
    cat > "$ROOTFS_DIR/etc/gdm/custom.conf" <<'EOF'
# GDM configuration storage
#
# Note: settings from /etc/sysconfig/displaymanager have a higher priority
#

[daemon]
InitialSetupEnable=True
#WaylandEnable=false

[security]

[xdmcp]

[chooser]

[debug]
#Enable=true
EOF
    # Ensure /etc/sysconfig/displaymanager does not force-disable initial setup.
    if [ -f "$ROOTFS_DIR/etc/sysconfig/displaymanager" ]; then
        sed -i \
            -e 's/^DISPLAYMANAGER_AUTOLOGIN=.*/DISPLAYMANAGER_AUTOLOGIN=""/' \
            "$ROOTFS_DIR/etc/sysconfig/displaymanager" || true
    fi
else
    install -Dm755 /dev/stdin "$ROOTFS_DIR/usr/local/bin/pipa-firstboot-setup" <<'EOF'
#!/bin/sh
set -eu

TITLE="openSUSE Pipa Setup"
STATE_DIR=/var/lib/pipa-firstboot
SENTINEL="$STATE_DIR/needs-setup"
LOCK_FILE="$STATE_DIR/lock"
AUTOSTART_FILE=/root/.config/autostart/pipa-firstboot-setup.desktop
DEFAULT_HOSTNAME="pipa"
DEFAULT_SHELL="/bin/bash"

[ -f "$SENTINEL" ] || exit 0

mkdir -p "$STATE_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

dialog_backend() {
    if command -v kdialog >/dev/null 2>&1; then
        printf '%s\n' kdialog
        return 0
    fi
    if command -v zenity >/dev/null 2>&1; then
        printf '%s\n' zenity
        return 0
    fi
    return 1
}

prompt_info() {
    message="$1"
    case "$(dialog_backend)" in
        zenity) zenity --info --title "$TITLE" --text "$message" >/dev/null 2>&1 || return 1 ;;
        kdialog) kdialog --title "$TITLE" --msgbox "$message" >/dev/null 2>&1 || return 1 ;;
    esac
}

prompt_error() {
    message="$1"
    case "$(dialog_backend)" in
        zenity) zenity --error --title "$TITLE" --text "$message" >/dev/null 2>&1 || true ;;
        kdialog) kdialog --title "$TITLE" --error "$message" >/dev/null 2>&1 || true ;;
    esac
}

trim_whitespace() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

prompt_required_text() {
    prompt="$1"
    default_value="${2:-}"
    while :; do
        case "$(dialog_backend)" in
            zenity)
                answer="$(zenity --entry --title "$TITLE" --text "$prompt" --entry-text "$default_value" 2>/dev/null)" || return 1
                ;;
            kdialog)
                answer="$(kdialog --title "$TITLE" --inputbox "$prompt" "$default_value" 2>/dev/null)" || return 1
                ;;
        esac
        answer="$(trim_whitespace "$answer")"
        if [ -n "$answer" ]; then
            printf '%s\n' "$answer"
            return 0
        fi
        prompt_error "This field cannot be empty."
    done
}

prompt_optional_text() {
    prompt="$1"
    default_value="${2:-}"
    case "$(dialog_backend)" in
        zenity)
            answer="$(zenity --entry --title "$TITLE" --text "$prompt" --entry-text "$default_value" 2>/dev/null)" || return 1
            ;;
        kdialog)
            answer="$(kdialog --title "$TITLE" --inputbox "$prompt" "$default_value" 2>/dev/null)" || return 1
            ;;
    esac
    trim_whitespace "$answer"
}

prompt_password() {
    prompt="$1"
    while :; do
        case "$(dialog_backend)" in
            zenity)
                password="$(zenity --entry --title "$TITLE" --text "$prompt" --hide-text 2>/dev/null)" || return 1
                ;;
            kdialog)
                password="$(kdialog --title "$TITLE" --password "$prompt" 2>/dev/null)" || return 1
                ;;
        esac
        if [ -z "$password" ]; then
            prompt_error "Password cannot be empty."
            continue
        fi
        case "$(dialog_backend)" in
            zenity)
                confirmation="$(zenity --entry --title "$TITLE" --text "Confirm the password." --hide-text 2>/dev/null)" || return 1
                ;;
            kdialog)
                confirmation="$(kdialog --title "$TITLE" --password "Confirm the password." 2>/dev/null)" || return 1
                ;;
        esac
        if [ "$password" != "$confirmation" ]; then
            prompt_error "Passwords do not match. Please try again."
            continue
        fi
        printf '%s\n' "$password"
        return 0
    done
}

valid_username() {
    printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_-]*[$]?$'
}

valid_hostname() {
    printf '%s' "$1" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
}

prompt_info "Welcome to openSUSE for Xiaomi Pad 6.\n\nThis first-boot setup will create your user account, set the hostname, and then reboot into the normal login screen." || exit 0

while :; do
    fullname="$(prompt_optional_text 'Full name (optional):' '')" || exit 0
    username="$(prompt_required_text 'Username:' '')" || exit 0
    username="$(printf '%s' "$username" | tr '[:upper:]' '[:lower:]')"

    if ! valid_username "$username"; then
        prompt_error "Username must start with a letter or underscore and may contain lowercase letters, numbers, hyphens, or underscores."
        continue
    fi
    if id "$username" >/dev/null 2>&1; then
        prompt_error "User '$username' already exists. Choose another username."
        continue
    fi

    hostname="$(prompt_required_text 'Hostname:' "$DEFAULT_HOSTNAME")" || exit 0
    hostname="$(printf '%s' "$hostname" | tr '[:upper:]' '[:lower:]')"
    if ! valid_hostname "$hostname"; then
        prompt_error "Hostname may only contain lowercase letters, numbers, and hyphens."
        continue
    fi

    password="$(prompt_password "Password for $username:")" || exit 0
    break
done

if [ -n "$fullname" ]; then
    useradd -m -G wheel -s "$DEFAULT_SHELL" -c "$fullname" "$username"
else
    useradd -m -G wheel -s "$DEFAULT_SHELL" "$username"
fi
printf 'root:%s\n%s:%s\n' "$password" "$username" "$password" | chpasswd
printf '%s\n' "$hostname" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
::1 localhost
127.0.1.1 $hostname.localdomain $hostname
HOSTS

rm -f /etc/sddm.conf.d/10-firstboot-autologin.conf
rm -f "$AUTOSTART_FILE" "$SENTINEL"
prompt_info "Setup complete.\n\nUser '$username' was created and the hostname was set to '$hostname'. Rebooting now." || true
systemctl reboot
EOF

    SESSION_FILE="$(first_existing_file \
        "$ROOTFS_DIR/usr/share/wayland-sessions/plasma.desktop" \
        "$ROOTFS_DIR/usr/share/wayland-sessions/plasmawayland.desktop" \
        "$ROOTFS_DIR/usr/share/xsessions/plasma.desktop" \
        "$ROOTFS_DIR/usr/share/wayland-sessions/plasma-mobile.desktop" \
        "$ROOTFS_DIR/usr/share/xsessions/plasma-mobile.desktop" \
    )"
    SESSION_NAME="$(basename "${SESSION_FILE:-plasma.desktop}" .desktop)"
    install -d "$ROOTFS_DIR/etc/sddm.conf.d"
    cat > "$ROOTFS_DIR/etc/sddm.conf.d/10-firstboot-autologin.conf" <<EOF
[Autologin]
User=root
Session=$SESSION_NAME
Relogin=false
EOF
    install -Dm644 /dev/stdin "$ROOTFS_DIR/root/.config/autostart/pipa-firstboot-setup.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=openSUSE Pipa First Boot Setup
Exec=sh -lc 'sleep 3; exec /usr/local/bin/pipa-firstboot-setup'
NoDisplay=true
EOF
    install -d "$ROOTFS_DIR/var/lib/pipa-firstboot"
    : > "$ROOTFS_DIR/var/lib/pipa-firstboot/needs-setup"
fi

echo "### Enabling services..."
target_chroot systemctl enable "$DISPLAY_MANAGER" || true
target_chroot systemctl enable NetworkManager sshd || true
target_chroot systemctl enable bluetooth systemd-resolved systemd-timesyncd || true
target_chroot systemctl enable tuned || true
target_chroot systemctl enable bootmac-bluetooth || true
target_chroot systemctl enable pd-mapper || true
target_chroot systemctl enable tqftpserv rmtfs || true
if [ "$PIPA_INCLUDE_SENSORS" = "1" ]; then
    target_chroot systemctl enable \
        pipa-sensors-persist \
        hexagonrpcd-sdsp \
        hexagonrpcd-adsp-sensorspd \
        iio-sensor-proxy \
        pipa-audio-init || true
else
    target_chroot systemctl enable pipa-audio-init || true
fi
target_chroot systemctl mask hexagonrpcd-adsp-rootpd.service || true

if [ "$DE_NAME" = "plasma" ] || [ "$DE_NAME" = "plasma-mobile" ]; then
    mkdir -p "$ROOTFS_DIR/etc/environment.d"
    cat > "$ROOTFS_DIR/etc/environment.d/90-plasma-keyboard.conf" <<EOF
KWIN_IM_SHOW_ALWAYS=1
PLASMA_KEYBOARD_USE_QT_LAYOUTS=1
EOF
fi

echo "### Locating kernel artifacts..."
KERNEL_VER=$(find "$ROOTFS_DIR/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n 1)
if [ -z "${KERNEL_VER:-}" ]; then
    echo "No kernel modules directory found under /usr/lib/modules" >&2
    exit 1
fi
KERNEL_IMAGE="$(first_existing_file \
    "$ROOTFS_DIR/boot/Image.gz" \
    "$ROOTFS_DIR/boot/vmlinuz-$KERNEL_VER" \
)"
KERNEL_IMAGE_UNCOMPRESSED="$(first_existing_file \
    "$ROOTFS_DIR/boot/Image" \
    "$ROOTFS_DIR/boot/vmlinuz-$KERNEL_VER.uncompressed" \
    || true \
)"
DTB_IMAGE="$(first_existing_file \
    "$ROOTFS_DIR/boot/dtbs/qcom/sm8250-xiaomi-pipa.dtb" \
    "$ROOTFS_DIR/usr/lib/modules/$KERNEL_VER/devicetree/sm8250-xiaomi-pipa.dtb" \
)"

if [ -z "${KERNEL_IMAGE:-}" ] || [ ! -f "$KERNEL_IMAGE" ]; then
    echo "Kernel image was not found for $KERNEL_VER" >&2
    exit 1
fi
if [ -z "${DTB_IMAGE:-}" ] || [ ! -f "$DTB_IMAGE" ]; then
    echo "Device tree was not found for $KERNEL_VER" >&2
    exit 1
fi

echo "### Generating module dependency maps for $KERNEL_VER..."
# kernel-pipa packages with DEPMOD=/bin/true; modules.dep is created on install/image.
target_chroot depmod -a "$KERNEL_VER"
if [ ! -f "$ROOTFS_DIR/usr/lib/modules/$KERNEL_VER/modules.dep" ]; then
    echo "depmod failed to create modules.dep for $KERNEL_VER" >&2
    exit 1
fi

echo "### Generating initramfs..."
# Tablet images do not need LUKS helpers; omitting avoids dm/crypt module errors
# when host/network packaging is incomplete.
target_chroot dracut --force --omit "crypt systemd-cryptsetup" \
    --kver "$KERNEL_VER" "/boot/initramfs-$KERNEL_VER.img"
INITRAMFS_IMAGE="$(first_existing_file \
    "$ROOTFS_DIR/boot/initramfs-$KERNEL_VER.img" \
    "$ROOTFS_DIR/boot/initramfs.img" \
)"
if [ ! -f "$INITRAMFS_IMAGE" ] || [ "$(stat -c '%s' "$INITRAMFS_IMAGE")" -lt 1048576 ]; then
    echo "Initramfs missing or too small" >&2
    exit 1
fi
cp "$INITRAMFS_IMAGE" "$ROOTFS_DIR/boot/initramfs.img"

echo "### Validating firmware..."
assert_required_firmware \
    "usr/lib/firmware/qcom/a650_sqe.fw" \
    "usr/lib/firmware/qcom/a650_gmu.bin" \
    "usr/lib/firmware/ath11k/QCA6390/hw2.0/amss.bin"

printf '%s\n' "$TARGET_KERNEL_CMDLINE" > "$ROOTFS_DIR/etc/cmdline"

echo "### Fetching Mu-Silicium..."
wget -O "$IMAGE_DIR/$IMAGE_NAME/silicium.img" "$SILICIUM_URL"
echo "$SILICIUM_SHA256  $IMAGE_DIR/$IMAGE_NAME/silicium.img" | sha256sum -c -

echo "### GRUB redirect on rootfs..."
mkdir -p "$ROOTFS_DIR/boot/efi" "$ROOTFS_DIR/boot/grub"
cat > "$ROOTFS_DIR/boot/grub/grub.cfg" <<EOF
search --no-floppy --label --set=boot $BOOT_LABEL
set prefix=(\$boot)/grub2
configfile (\$boot)/grub2/grub.cfg
EOF

echo "### Building boot partition image..."
truncate -s "${BOOT_SIZE_MB}M" "$IMAGE_DIR/$IMAGE_NAME/opensuse_boot.raw"
mkfs.ext4 -F -L "$BOOT_LABEL" -O '^64bit,^metadata_csum,^metadata_csum_seed,^orphan_file' \
    "$IMAGE_DIR/$IMAGE_NAME/opensuse_boot.raw"
mount -o loop "$IMAGE_DIR/$IMAGE_NAME/opensuse_boot.raw" "$BOOT_MNT"
mkdir -p "$BOOT_MNT/dtbs/qcom" "$BOOT_MNT/grub2" "$BOOT_MNT/efi"
cp -a "$KERNEL_IMAGE" "$BOOT_MNT/Image.gz"
if [ -n "${KERNEL_IMAGE_UNCOMPRESSED:-}" ] && [ -f "$KERNEL_IMAGE_UNCOMPRESSED" ]; then
    cp -a "$KERNEL_IMAGE_UNCOMPRESSED" "$BOOT_MNT/Image"
fi
cp -a "$INITRAMFS_IMAGE" "$BOOT_MNT/initramfs-$KERNEL_VER.img"
cp -a "$ROOTFS_DIR/boot/cmdline.txt" "$BOOT_MNT/cmdline.txt"
if [ -d "$ROOTFS_DIR/boot/dtbs/qcom" ]; then
    cp -a "$ROOTFS_DIR/boot/dtbs/qcom"/sm8250-xiaomi-pipa*.dtb "$BOOT_MNT/dtbs/qcom/" 2>/dev/null || \
        cp -a "$DTB_IMAGE" "$BOOT_MNT/dtbs/qcom/sm8250-xiaomi-pipa.dtb"
else
    cp -a "$DTB_IMAGE" "$BOOT_MNT/dtbs/qcom/sm8250-xiaomi-pipa.dtb"
fi

mount --move "$BOOT_MNT" "$ROOTFS_DIR/boot"
PIPA_INITRAMFS_SOURCE="/boot/initramfs-$KERNEL_VER.img" \
    target_chroot /usr/local/bin/pipa-refresh-grub-config
if [ ! -f "$ROOTFS_DIR/boot/grub2/grub.cfg" ]; then
    echo "pipa-grub-config did not generate /boot/grub2/grub.cfg" >&2
    exit 1
fi
umount "$ROOTFS_DIR/boot"
mkdir -p "$BOOT_MNT"
mount -o loop "$IMAGE_DIR/$IMAGE_NAME/opensuse_boot.raw" "$BOOT_MNT"
test -f "$BOOT_MNT/grub2/grub.cfg"
umount "$BOOT_MNT"

echo "### Building ESP..."
BOOT_FS_UUID="$(blkid -s UUID -o value "$IMAGE_DIR/$IMAGE_NAME/opensuse_boot.raw")"
if [ -z "$BOOT_FS_UUID" ]; then
    echo "Unable to read UUID from opensuse_boot.raw" >&2
    exit 1
fi
truncate -s "${ESP_SIZE_MB}M" "$IMAGE_DIR/$IMAGE_NAME/opensuse_esp.raw"
mkfs.fat -F 16 -n "$ESP_LABEL" "$IMAGE_DIR/$IMAGE_NAME/opensuse_esp.raw"
mount -o loop "$IMAGE_DIR/$IMAGE_NAME/opensuse_esp.raw" "$ESP_MNT"
cp -r "$EFI_TEMPLATE_DIR/EFI" "$ESP_MNT/"
mkdir -p "$ESP_MNT/EFI/fedora"
cp -r "$ESP_MNT/EFI/opensuse/." "$ESP_MNT/EFI/fedora/"
for shim_vendor in opensuse fedora; do
    # Match Mu-Silicium / Endeavour early-config flow: source bootuuid.cfg,
    # then search by UUID or fall back to the boot label.
    cat > "$ESP_MNT/EFI/$shim_vendor/grub.cfg" <<EOF
if [ -f \${config_directory}/bootuuid.cfg ]; then
  source \${config_directory}/bootuuid.cfg
fi
if [ -n "\${BOOT_UUID}" ]; then
  search --fs-uuid "\${BOOT_UUID}" --set prefix --no-floppy
else
  search --label $BOOT_LABEL --set prefix --no-floppy
fi
if [ -d (\$prefix)/grub2 ]; then
  set prefix=(\$prefix)/grub2
  configfile \$prefix/grub.cfg
else
  set prefix=(\$prefix)/boot/grub2
  configfile \$prefix/grub.cfg
fi
boot
EOF
    cat > "$ESP_MNT/EFI/$shim_vendor/bootuuid.cfg" <<EOF
set BOOT_UUID="$BOOT_FS_UUID"
EOF
done
write_uefi_csv "$ESP_MNT/EFI/fedora/BOOTAA64.CSV" "shimaa64.efi" "openSUSE" "openSUSE Pipa"
write_uefi_csv "$ESP_MNT/EFI/opensuse/BOOTAA64.CSV" "shimaa64.efi" "openSUSE" "openSUSE Pipa"
umount "$ESP_MNT"

echo "### Building rootfs image..."
target_umount_all
ROOTFS_SIZE_MB=$(( $(du -sm "$ROOTFS_DIR" | awk '{print $1}') * 9 / 8 + 512 ))
truncate -s "${ROOTFS_SIZE_MB}M" "$IMAGE_DIR/$IMAGE_NAME/opensuse_rootfs.raw"
mkfs.ext4 -F -L "$ROOTFS_LABEL" "$IMAGE_DIR/$IMAGE_NAME/opensuse_rootfs.raw"
mount -o loop "$IMAGE_DIR/$IMAGE_NAME/opensuse_rootfs.raw" "$IMAGE_MNT"
rsync -aHAX --exclude '/tmp/*' --exclude '/boot/efi' --exclude '/efi' \
    "$ROOTFS_DIR"/ "$IMAGE_MNT"/
umount "$IMAGE_MNT"

cp "$VBMETA_IMG" "$IMAGE_DIR/$IMAGE_NAME/vbmeta.img"

echo "### Writing flash helpers..."
cat > "$IMAGE_DIR/$IMAGE_NAME/flash.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
announce() { printf '\n==> %s\n' "$*"; }
choose_yes_no() {
    local prompt="$1" default="${2:-no}" reply
    read -r -p "$prompt [y/N]: " reply || true
    reply="${reply:-$default}"
    case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}
announce "Xiaomi Pad 6 single-boot flasher (openSUSE)"
announce "This mode flashes rootfs to userdata."
fastboot getvar product 2>&1 | grep -qi pipa || { echo "Device product is not pipa"; exit 1; }
ERASE_DTBO="${ERASE_DTBO:-}"
FLASH_VBMETA="${FLASH_VBMETA:-}"
if [ -z "$ERASE_DTBO" ]; then
    if choose_yes_no 'Erase dtbo_ab before flashing?' 'no'; then ERASE_DTBO=yes; else ERASE_DTBO=no; fi
fi
if [ -z "$FLASH_VBMETA" ]; then
    if choose_yes_no 'Flash vbmeta_ab?' 'no'; then FLASH_VBMETA=yes; else FLASH_VBMETA=no; fi
fi
read -r -p "Proceed with flashing? [Y/n]: " CONFIRM_FLASH
CONFIRM_FLASH="${CONFIRM_FLASH:-Y}"
case "$CONFIRM_FLASH" in n|N|no|NO) exit 0 ;; esac
if [ "$ERASE_DTBO" = "yes" ]; then fastboot erase dtbo_ab; fi
if [ "$FLASH_VBMETA" = "yes" ]; then fastboot flash vbmeta_ab vbmeta.img; fi
fastboot flash boot_ab silicium.img
fastboot flash rawdump opensuse_esp.raw
fastboot flash cust opensuse_boot.raw
fastboot flash userdata opensuse_rootfs.raw
fastboot reboot
EOF
chmod +x "$IMAGE_DIR/$IMAGE_NAME/flash.sh"

cat > "$IMAGE_DIR/$IMAGE_NAME/flash-multiboot.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
announce() { printf '\n==> %s\n' "$*"; }
prompt_with_default() {
    local prompt="$1" default="$2" reply
    read -r -p "$prompt [$default]: " reply || true
    printf '%s\n' "${reply:-$default}"
}
announce "Xiaomi Pad 6 multiboot flasher (openSUSE)"
fastboot getvar product 2>&1 | grep -qi pipa || { echo "Device product is not pipa"; exit 1; }
BOOT_SLOT_TARGET="${BOOT_SLOT_TARGET:-boot_ab}"
ROOTFS_PARTITION="${ROOTFS_PARTITION:-linux}"
ESP_PARTITION="rawdump"
BOOT_PARTITION="cust"
BOOT_SLOT_TARGET="$(prompt_with_default 'Boot slot target (boot_a/boot_b/boot_ab)' "$BOOT_SLOT_TARGET")"
ROOTFS_PARTITION="$(prompt_with_default 'Rootfs partition' "$ROOTFS_PARTITION")"
ERASE_DTBO="$(prompt_with_default 'Erase dtbo_ab? (yes/no)' 'no')"
FLASH_VBMETA="$(prompt_with_default 'Flash vbmeta_ab? (yes/no)' 'no')"
read -r -p "Proceed with flashing? [Y/n]: " CONFIRM_FLASH
CONFIRM_FLASH="${CONFIRM_FLASH:-Y}"
case "$CONFIRM_FLASH" in n|N|no|NO) exit 0 ;; esac
if [ "$ERASE_DTBO" = "yes" ]; then fastboot erase dtbo_ab; fi
if [ "$FLASH_VBMETA" = "yes" ]; then fastboot flash vbmeta_ab vbmeta.img; fi
fastboot flash "$BOOT_SLOT_TARGET" silicium.img
fastboot flash "$ESP_PARTITION" opensuse_esp.raw
fastboot flash "$BOOT_PARTITION" opensuse_boot.raw
fastboot flash "$ROOTFS_PARTITION" opensuse_rootfs.raw
fastboot reboot
EOF
chmod +x "$IMAGE_DIR/$IMAGE_NAME/flash-multiboot.sh"

cat > "$IMAGE_DIR/$IMAGE_NAME/BUILDINFO.txt" <<EOF
Desktop:        $DE_NAME
Date:           $DATE
Git revision:   $BUILD_GIT_REV
Kernel:         $KERNEL_VER
Pipa repo:      $PIPA_REPO_URL
Rootfs label:   $ROOTFS_LABEL
Boot label:     $BOOT_LABEL
ESP label:      $ESP_LABEL
EOF

(
    cd "$IMAGE_DIR/$IMAGE_NAME"
    sha256sum silicium.img opensuse_esp.raw opensuse_boot.raw opensuse_rootfs.raw vbmeta.img \
        flash.sh flash-multiboot.sh BUILDINFO.txt > SHA256SUMS
)

echo "### Creating ZIP..."
(
    cd "$IMAGE_DIR"
    zip -r "${IMAGE_NAME}.zip" "$IMAGE_NAME"
)

echo "### Done: $IMAGE_DIR/${IMAGE_NAME}.zip"
