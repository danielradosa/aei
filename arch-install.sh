#!/usr/bin/env bash
#
# arch-install.sh — Arch Easy Install (aei).
# ============================================================================
# Runs phases 1 (ISO preflight + partition + pacstrap) and 2 (chroot config).
# Phase 3 (user-level: paru, AUR, dotfiles, pywal) is handled by post-install.sh
# from the same repo, which is auto-launched on first login.
#
# Usage from the Arch ISO live env (after `loadkeys` and network up):
#
#   pacman -Sy --noconfirm git
#   git clone https://github.com/danielradosa/aei
#   cd aei
#   ./arch-install.sh --config arch-install.conf      # baked-in defaults
#   ./arch-install.sh                                 # TUI / prompts
#   ./arch-install.sh --cli                           # plain prompts
#   ./arch-install.sh --dry-run                       # print, don't write
#
# After phases 1-2 finish: reboot. greetd loads tuigreet; log in; phase 3
# auto-runs once via ~/.zprofile. Logs: /var/log/arch-install.log.
# ============================================================================

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
: "${HOSTNAME:=arch}"
: "${USERNAME:=daniel}"
: "${TIMEZONE:=Europe/Copenhagen}"
: "${LOCALE:=en_US.UTF-8}"
: "${KEYMAP:=us}"
: "${KERNEL:=linux}"
: "${FILESYSTEM:=btrfs}"
: "${ENCRYPT:=yes}"
: "${SWAP_SIZE:=8G}"
: "${BOOTLOADER:=auto}"
: "${DESKTOP:=hyprland}"
: "${SHELL_CHOICE:=zsh}"
: "${AUR_HELPER:=paru}"
: "${INSTALL_NVIDIA:=auto}"
: "${AEI_REPO:=https://github.com/danielradosa/aei.git}"
: "${AEI_BRANCH:=main}"
: "${ENABLE_MULTILIB:=yes}"
: "${ENABLE_SERVICES:=NetworkManager bluetooth sshd}"

# ── Dualboot mode ───────────────────────────────────────────────────────────
# Set MANUAL_PARTITION=yes when you've already partitioned the disk yourself
# (typical for dualboot: Windows ESP + your shrunk Windows partition + a new
# root partition you cut from the freed space). The installer will then SKIP
# `sgdisk --zap-all` and re-use the partitions named in ROOT_PART / ESP_PART
# (and BOOT_PART for BIOS). Only ROOT_PART gets formatted; the existing ESP
# is left alone so Windows still boots from it.
#
# Example for an NVMe disk where Windows lives on p1 (ESP) + p3 (NTFS) and
# you've created p4 as your Linux root:
#   MANUAL_PARTITION=yes ROOT_PART=/dev/nvme0n1p4 ESP_PART=/dev/nvme0n1p1
: "${MANUAL_PARTITION:=no}"

SELF="$(readlink -f "$0")"
REPO_DIR="$(dirname "$SELF")"
LOG_PRE=/var/log/arch-install.log
PHASE="${PHASE:-preflight}"
DRY_RUN="${DRY_RUN:-no}"
USE_TUI="${USE_TUI:-auto}"
TARGET=/mnt
CONFIG_FILE=""

# ── Logging ─────────────────────────────────────────────────────────────────
log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*" | tee -a "$LOG_PRE"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" | tee -a "$LOG_PRE"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" | tee -a "$LOG_PRE" >&2; }
die()  { err "$*"; exit 1; }

# Run a command. Logs verbatim. With --dry-run, prints and skips.
run() {
    if [[ "$DRY_RUN" == "yes" ]]; then
        printf '\033[1;36m[dry]\033[0m %s\n' "$*"
        return 0
    fi
    "$@" 2>&1 | tee -a "$LOG_PRE"
}

# Same as run() but takes a single string and uses bash -c (for pipes/redirects).
run_sh() {
    if [[ "$DRY_RUN" == "yes" ]]; then
        printf '\033[1;36m[dry]\033[0m %s\n' "$*"
        return 0
    fi
    bash -c "$*" 2>&1 | tee -a "$LOG_PRE"
}

trap 'err "Aborted on line $LINENO. See $LOG_PRE for details."' ERR

# ── TUI helpers ─────────────────────────────────────────────────────────────
have_tui() {
    [[ "$USE_TUI" == "no"  ]] && return 1
    [[ "$USE_TUI" == "yes" ]] && return 0
    command -v whiptail >/dev/null 2>&1
}

ask() {
    local prompt="$1" default="${2:-}" ans
    if have_tui; then
        ans=$(whiptail --title "Arch Installer" --inputbox "$prompt" 10 70 "$default" 3>&1 1>&2 2>&3) \
            || die "Cancelled."
    else
        read -rp "$prompt [$default]: " ans
        ans="${ans:-$default}"
    fi
    echo "$ans"
}

ask_pw() {
    local prompt="$1" pw1 pw2
    while :; do
        if have_tui; then
            pw1=$(whiptail --title "Arch Installer" --passwordbox "$prompt" 10 70 3>&1 1>&2 2>&3) || die "Cancelled."
            pw2=$(whiptail --title "Arch Installer" --passwordbox "Confirm: $prompt" 10 70 3>&1 1>&2 2>&3) || die "Cancelled."
        else
            read -rsp "$prompt: " pw1; echo
            read -rsp "Confirm: " pw2; echo
        fi
        [[ "$pw1" == "$pw2" && -n "$pw1" ]] && { echo "$pw1"; return; }
        warn "Passwords didn't match or were empty."
    done
}

confirm() {
    local prompt="$1"
    if have_tui; then
        whiptail --title "Confirm" --yesno "$prompt" 10 70
    else
        read -rp "$prompt [y/N]: " a
        [[ "${a,,}" == "y" || "${a,,}" == "yes" ]]
    fi
}

menu() {
    local title="$1"; shift
    if have_tui; then
        whiptail --title "Arch Installer" --menu "$title" 20 70 10 "$@" 3>&1 1>&2 2>&3 || die "Cancelled."
    else
        echo "$title" >&2
        local i=1 keys=()
        while [[ $# -gt 0 ]]; do
            keys+=("$1"); printf '  %d) %s — %s\n' "$i" "$1" "$2" >&2
            shift 2; ((i++))
        done
        local sel
        read -rp "Choice [1]: " sel; sel="${sel:-1}"
        echo "${keys[$((sel-1))]}"
    fi
}

# ── CLI parsing ─────────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cli)               USE_TUI=no ;;
            --tui)               USE_TUI=yes ;;
            --dry-run)           DRY_RUN=yes ;;
            --manual-partition)  MANUAL_PARTITION=yes ;;
            --config)            CONFIG_FILE="$2"; shift ;;
            --phase)             PHASE="$2"; shift ;;
            -h|--help)           sed -n '2,30p' "$SELF" | sed 's/^# \?//'; exit 0 ;;
            *) die "Unknown flag: $1" ;;
        esac
        shift
    done

    if [[ -n "$CONFIG_FILE" ]]; then
        [[ -r "$CONFIG_FILE" ]] || die "Config file not readable: $CONFIG_FILE"
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi
}

# ── Hardware detection ──────────────────────────────────────────────────────
detect_gpu() {
    GPU_VENDOR=other
    local gpu_line; gpu_line=$(lspci | grep -Ei 'vga|3d|display' || true)
    if   echo "$gpu_line" | grep -iq nvidia; then GPU_VENDOR=nvidia
    elif echo "$gpu_line" | grep -iq amd;    then GPU_VENDOR=amd
    elif echo "$gpu_line" | grep -iq intel;  then GPU_VENDOR=intel
    fi
    log "GPU vendor: $GPU_VENDOR"

    case "$INSTALL_NVIDIA" in
        auto) [[ "$GPU_VENDOR" == "nvidia" ]] && DO_NVIDIA=yes || DO_NVIDIA=no ;;
        yes)  DO_NVIDIA=yes ;;
        no)   DO_NVIDIA=no ;;
    esac
    log "NVIDIA driver: $DO_NVIDIA"
}

# ── Read package lists from packages/{pacman,aur}.txt ───────────────────────
load_pkg_list() {
    # Strips comments + blanks. Echoes one package per line.
    local file="$1"
    [[ -r "$file" ]] || die "Package list missing: $file"
    sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//;s/[[:space:]]*$//' "$file"
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 1 — PREFLIGHT
# ════════════════════════════════════════════════════════════════════════════
preflight_checks() {
    log "Preflight checks..."
    [[ $EUID -eq 0 ]] || die "Run as root from the Arch ISO."
    [[ -d /sys/firmware/efi/efivars ]] && FIRMWARE=uefi || FIRMWARE=bios
    log "Firmware: $FIRMWARE"
    ping -c1 -W3 archlinux.org >/dev/null 2>&1 || die "No internet. Connect with iwctl/dhcpcd first."
    timedatectl set-ntp true || true
    detect_gpu
    [[ "$BOOTLOADER" == "auto" ]] && {
        BOOTLOADER=$([[ "$FIRMWARE" == "uefi" ]] && echo "systemd-boot" || echo "grub")
    }
}

interactive_config() {
    if [[ -n "$CONFIG_FILE" ]]; then
        log "Using config $CONFIG_FILE — skipping field prompts."
    else
        HOSTNAME=$(ask "Hostname" "$HOSTNAME")
        USERNAME=$(ask "Username" "$USERNAME")
        TIMEZONE=$(ask "Timezone" "$TIMEZONE")
        LOCALE=$(ask   "Locale"  "$LOCALE")
        KEYMAP=$(ask   "Keymap"  "$KEYMAP")
        KERNEL=$(menu "Kernel" \
            linux           "Stable (recommended)" \
            linux-lts       "Long-term support" \
            linux-zen       "Tuned for desktop" \
            linux-hardened  "Security-hardened")
        FILESYSTEM=$(menu "Root filesystem" \
            btrfs  "Snapshots & subvolumes (default)" \
            ext4   "Boring & bulletproof")
        if confirm "Encrypt root with LUKS2?"; then ENCRYPT=yes; else ENCRYPT=no; fi
    fi

    [[ -z "${USER_PASSWORD:-}" ]] && USER_PASSWORD=$(ask_pw "Password for $USERNAME")
    [[ -z "${ROOT_PASSWORD:-}" ]] && ROOT_PASSWORD=$(ask_pw "Root password")
    if [[ "$ENCRYPT" == "yes" && -z "${LUKS_PASSWORD:-}" ]]; then
        LUKS_PASSWORD=$(ask_pw "LUKS encryption passphrase")
    fi
    : "${LUKS_PASSWORD:=}"
}

select_disk() {
    if [[ "$MANUAL_PARTITION" == "yes" ]]; then
        log "MANUAL_PARTITION=yes — skipping disk picker."
        [[ -n "${ROOT_PART:-}" && -b "${ROOT_PART:-}" ]] \
            || die "MANUAL_PARTITION needs ROOT_PART set to an existing block device (e.g. /dev/nvme0n1p4)."
        if [[ "$FIRMWARE" == "uefi" ]]; then
            [[ -n "${ESP_PART:-}" && -b "${ESP_PART:-}" ]] \
                || die "MANUAL_PARTITION + UEFI needs ESP_PART set (e.g. /dev/nvme0n1p1 — usually Windows' ESP)."
        else
            [[ -n "${BOOT_PART:-}" && -b "${BOOT_PART:-}" ]] \
                || die "MANUAL_PARTITION + BIOS needs BOOT_PART set."
        fi
        log "Will format ROOT_PART=$ROOT_PART (only); leaving ESP_PART=${ESP_PART:-} untouched."
        confirm "Format $ROOT_PART (Linux root)? Existing data on it will be lost." \
            || die "User aborted."
        : "${DISK:=auto}"   # not used in manual mode but referenced later
        return
    fi

    log "Detecting disks..."

    if [[ -n "${DISK:-}" ]]; then
        [[ -b "$DISK" ]] || die "Preset DISK='$DISK' is not a block device."
        log "Using preset DISK=$DISK"
        confirm "Really WIPE EVERYTHING on $DISK ?" || die "User aborted."
        confirm "Last chance. Confirm $DISK will be erased."  || die "User aborted."
        return
    fi

    mapfile -t disks < <(lsblk -dpno NAME,SIZE,TYPE | awk '$3=="disk"{print $1, $2}')
    [[ ${#disks[@]} -eq 0 ]] && die "No disks found."

    if [[ ${#disks[@]} -eq 1 ]]; then
        DISK=$(echo "${disks[0]}" | awk '{print $1}')
        log "Single disk detected: $DISK ($(echo "${disks[0]}" | awk '{print $2}'))"
    else
        local args=()
        for d in "${disks[@]}"; do
            local name size; read -r name size <<<"$d"
            args+=("$name" "$size")
        done
        DISK=$(menu "Select install disk (WILL BE WIPED)" "${args[@]}")
    fi

    [[ "$DISK" == /dev/* && -b "$DISK" ]] \
        || die "Picked DISK='$DISK' is not a valid block device."

    confirm "Really WIPE EVERYTHING on $DISK ?" || die "User aborted."
    confirm "Last chance. Confirm $DISK will be erased." || die "User aborted."
}

partition_disk() {
    if [[ "$MANUAL_PARTITION" == "yes" ]]; then
        log "Reusing pre-existing partitions (MANUAL_PARTITION=yes):"
        log "  ROOT_PART=$ROOT_PART"
        log "  ESP_PART=${ESP_PART:-<none>}"
        log "  BOOT_PART=${BOOT_PART:-<none>}"
        # Skip sgdisk + partprobe — partitions already exist.
    else
        log "Partitioning $DISK..."
        if [[ "$FIRMWARE" == "uefi" ]]; then
            run sgdisk --zap-all "$DISK"
            run sgdisk -n1:0:+1G -t1:ef00 -c1:ESP "$DISK"
            run sgdisk -n2:0:0   -t2:8300 -c2:root "$DISK"
        else
            run sgdisk --zap-all "$DISK"
            run sgdisk -n1:0:+1M   -t1:ef02 -c1:bios "$DISK"
            run sgdisk -n2:0:+512M -t2:8300 -c2:boot "$DISK"
            run sgdisk -n3:0:0     -t3:8300 -c3:root "$DISK"
        fi
        run partprobe "$DISK"; sleep 2

        if [[ "$DISK" =~ nvme|mmcblk ]]; then PFX="${DISK}p"; else PFX="$DISK"; fi
        if [[ "$FIRMWARE" == "uefi" ]]; then
            ESP_PART="${PFX}1"; ROOT_PART="${PFX}2"; BOOT_PART=""
        else
            BOOT_PART="${PFX}2"; ROOT_PART="${PFX}3"; ESP_PART=""
        fi
    fi

    if [[ "$ENCRYPT" == "yes" ]]; then
        log "LUKS2 on $ROOT_PART..."
        if [[ "$DRY_RUN" == "no" ]]; then
            printf '%s' "$LUKS_PASSWORD" | cryptsetup luksFormat --type luks2 --batch-mode "$ROOT_PART" -
            printf '%s' "$LUKS_PASSWORD" | cryptsetup open "$ROOT_PART" cryptroot -
        fi
        ROOT_DEV=/dev/mapper/cryptroot
    else
        ROOT_DEV="$ROOT_PART"
    fi

    log "Formatting root ($FILESYSTEM)..."
    case "$FILESYSTEM" in
        ext4)  run mkfs.ext4 -F "$ROOT_DEV" ;;
        btrfs) run mkfs.btrfs -f "$ROOT_DEV" ;;
    esac
    # In MANUAL_PARTITION mode, the ESP and BOOT_PART already host another OS
    # (typically Windows' EFI System Partition + a recovery/boot partition).
    # Reformatting them would brick that OS — so skip both formats entirely.
    if [[ "$MANUAL_PARTITION" != "yes" ]]; then
        [[ -n "$ESP_PART"  ]] && run mkfs.fat -F32 "$ESP_PART"
        [[ -n "$BOOT_PART" ]] && run mkfs.ext4 -F "$BOOT_PART"
    else
        log "Skipping mkfs on ESP_PART / BOOT_PART (manual-partition mode)."
    fi

    log "Mounting..."
    run mount "$ROOT_DEV" "$TARGET"
    if [[ "$FILESYSTEM" == "btrfs" ]]; then
        run btrfs subvolume create "$TARGET/@"
        run btrfs subvolume create "$TARGET/@home"
        run btrfs subvolume create "$TARGET/@log"
        run btrfs subvolume create "$TARGET/@pkg"
        run umount "$TARGET"
        run mount -o noatime,compress=zstd,subvol=@      "$ROOT_DEV" "$TARGET"
        run mkdir -p "$TARGET/home" "$TARGET/var/log" "$TARGET/var/cache/pacman/pkg" "$TARGET/boot"
        run mount -o noatime,compress=zstd,subvol=@home  "$ROOT_DEV" "$TARGET/home"
        run mount -o noatime,compress=zstd,subvol=@log   "$ROOT_DEV" "$TARGET/var/log"
        run mount -o noatime,compress=zstd,subvol=@pkg   "$ROOT_DEV" "$TARGET/var/cache/pacman/pkg"
    fi
    run mkdir -p "$TARGET/boot"
    if [[ "$FIRMWARE" == "uefi" ]]; then
        run mkdir -p "$TARGET/boot/efi"
        run mount "$ESP_PART" "$TARGET/boot/efi"
    else
        run mount "$BOOT_PART" "$TARGET/boot"
    fi
}

install_base() {
    log "Pacstrapping base..."
    local pkgs=(base "$KERNEL" "${KERNEL}-headers" linux-firmware
                base-devel sudo networkmanager
                vim man-db man-pages texinfo
                pacman-contrib reflector
                git
                "$SHELL_CHOICE")
    [[ "$FILESYSTEM" == "btrfs" ]] && pkgs+=(btrfs-progs)
    [[ "$ENCRYPT"    == "yes"   ]] && pkgs+=(cryptsetup)
    [[ "$BOOTLOADER" == "grub"  ]] && pkgs+=(grub $( [[ "$FIRMWARE" == "uefi" ]] && echo efibootmgr ))

    if grep -q "GenuineIntel" /proc/cpuinfo; then pkgs+=(intel-ucode); MICROCODE=intel-ucode
    elif grep -q "AuthenticAMD" /proc/cpuinfo; then pkgs+=(amd-ucode); MICROCODE=amd-ucode
    else MICROCODE=""; fi

    run reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
    run pacstrap -K "$TARGET" "${pkgs[@]}"

    log "Generating fstab..."
    run_sh "genfstab -U $TARGET >> $TARGET/etc/fstab"
}

setup_swap() {
    [[ "$SWAP_SIZE" == "0" ]] && return
    log "Creating ${SWAP_SIZE} swap file..."

    if [[ "$FILESYSTEM" == "btrfs" ]]; then
        if btrfs filesystem mkswapfile --help 2>&1 | grep -q -- '--size'; then
            run btrfs filesystem mkswapfile --size "$SWAP_SIZE" "$TARGET/swapfile"
        else
            warn "btrfs-progs too old for mkswapfile; falling back to chattr+dd"
            run touch "$TARGET/swapfile"
            run chattr +C "$TARGET/swapfile"
            local mb; mb=$(numfmt --from=iec "$SWAP_SIZE" | awk '{print int($1/1024/1024)}')
            run dd if=/dev/zero of="$TARGET/swapfile" bs=1M count="$mb" status=progress
            run chmod 600 "$TARGET/swapfile"
            run mkswap "$TARGET/swapfile"
        fi
    else
        local mb; mb=$(numfmt --from=iec "$SWAP_SIZE" | awk '{print int($1/1024/1024)}')
        run dd if=/dev/zero of="$TARGET/swapfile" bs=1M count="$mb" status=progress
        run chmod 600 "$TARGET/swapfile"
        run mkswap "$TARGET/swapfile"
    fi

    run_sh "echo '/swapfile none swap defaults 0 0' >> $TARGET/etc/fstab"
}

stage_chroot() {
    log "Copying repo into target and entering chroot..."
    run cp -r "$REPO_DIR" "$TARGET/root/aei"
    run chmod +x "$TARGET/root/aei/arch-install.sh"
    run chmod +x "$TARGET/root/aei/post-install.sh"

    if [[ "$DRY_RUN" == "yes" ]]; then
        printf '\033[1;36m[dry]\033[0m would write %s/root/aei.env\n' "$TARGET"
    else
        cat > "$TARGET/root/aei.env" <<EOF
HOSTNAME='$HOSTNAME'
USERNAME='$USERNAME'
TIMEZONE='$TIMEZONE'
LOCALE='$LOCALE'
KEYMAP='$KEYMAP'
KERNEL='$KERNEL'
FILESYSTEM='$FILESYSTEM'
ENCRYPT='$ENCRYPT'
BOOTLOADER='$BOOTLOADER'
DESKTOP='$DESKTOP'
SHELL_CHOICE='$SHELL_CHOICE'
AUR_HELPER='$AUR_HELPER'
DO_NVIDIA='$DO_NVIDIA'
GPU_VENDOR='$GPU_VENDOR'
AEI_REPO='$AEI_REPO'
AEI_BRANCH='$AEI_BRANCH'
ENABLE_MULTILIB='$ENABLE_MULTILIB'
ENABLE_SERVICES='$ENABLE_SERVICES'
FIRMWARE='$FIRMWARE'
ROOT_PART='$ROOT_PART'
ESP_PART='${ESP_PART:-}'
BOOT_PART='${BOOT_PART:-}'
DISK='$DISK'
MICROCODE='${MICROCODE:-}'
MANUAL_PARTITION='$MANUAL_PARTITION'
ROOT_PASSWORD='$ROOT_PASSWORD'
USER_PASSWORD='$USER_PASSWORD'
PHASE='chroot'
USE_TUI='no'
EOF
        chmod 600 "$TARGET/root/aei.env"
    fi
    run arch-chroot "$TARGET" /bin/bash -c \
        'set -a; source /root/aei.env; set +a; /root/aei/arch-install.sh --phase chroot --cli'
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 2 — IN CHROOT
# ════════════════════════════════════════════════════════════════════════════
chroot_configure() {
    log "Phase 2: configuring system inside chroot..."
    run ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    run hwclock --systohc

    sed -i "s/^#\s*\(${LOCALE}\)/\1/" /etc/locale.gen
    run locale-gen
    echo "LANG=$LOCALE"   > /etc/locale.conf
    echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
    echo "$HOSTNAME"      > /etc/hostname
    cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

    if [[ "$ENABLE_MULTILIB" == "yes" ]]; then
        sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
        run pacman -Syy --noconfirm
    fi

    install_nvidia              # before mkinitcpio/bootloader
    configure_mkinitcpio
    install_bootloader
    install_pkglist             # pacman.txt — desktop + base extras
    configure_greetd
    create_user

    log "Enabling services: $ENABLE_SERVICES"
    for s in $ENABLE_SERVICES; do run systemctl enable "$s"; done

    install_phase3_hook
    log "Phase 2 complete."
}

install_nvidia() {
    [[ "$DO_NVIDIA" != "yes" ]] && { log "Skipping NVIDIA driver."; return; }
    log "Installing NVIDIA proprietary drivers (open kernel modules)..."
    # nvidia-open-dkms = open kernel modules (Turing/Ampere/Ada+); see Arch wiki.
    run pacman -S --noconfirm --needed \
        nvidia-open-dkms nvidia-utils lib32-nvidia-utils nvidia-settings \
        libva-nvidia-driver egl-wayland

    install -d /etc/pacman.d/hooks
    cat > /etc/pacman.d/hooks/nvidia.hook <<'EOF'
[Trigger]
Operation=Install
Operation=Upgrade
Operation=Remove
Type=Package
Target=nvidia
Target=nvidia-open
Target=nvidia-open-dkms
Target=nvidia-dkms
Target=linux
Target=linux-lts
Target=linux-zen
Target=linux-hardened

[Action]
Description=Updating NVIDIA module in initcpio
Depends=mkinitcpio
When=PostTransaction
NeedsTargets
Exec=/bin/sh -c 'while read -r trg; do case $trg in linux*) exit 0; esac; done; /usr/bin/mkinitcpio -P'
EOF
}

configure_mkinitcpio() {
    if [[ "$DO_NVIDIA" == "yes" ]]; then
        sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
        if [[ "$ENCRYPT" == "yes" ]]; then
            sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
        else
            sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf keyboard keymap consolefont block filesystems fsck)/' /etc/mkinitcpio.conf
        fi
    elif [[ "$ENCRYPT" == "yes" ]]; then
        sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
    fi
    if [[ "$FILESYSTEM" == "btrfs" ]]; then
        if grep -q '^MODULES=(nvidia' /etc/mkinitcpio.conf; then
            sed -i 's/^MODULES=(\(.*\))/MODULES=(\1 btrfs)/' /etc/mkinitcpio.conf
        else
            sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
        fi
    fi
    run mkinitcpio -P
}

install_bootloader() {
    log "Bootloader: $BOOTLOADER"
    local nvidia_args=""
    [[ "$DO_NVIDIA" == "yes" ]] && nvidia_args="nvidia_drm.modeset=1 nvidia_drm.fbdev=1"

    case "$BOOTLOADER" in
        systemd-boot)
            run bootctl --path=/boot/efi install
            local cmdline="rw quiet $nvidia_args"
            local uuid; uuid=$(blkid -s UUID -o value "$ROOT_PART")
            if [[ "$ENCRYPT" == "yes" ]]; then
                cmdline="cryptdevice=UUID=$uuid:cryptroot root=/dev/mapper/cryptroot $cmdline"
            else
                cmdline="root=UUID=$uuid $cmdline"
            fi
            [[ "$FILESYSTEM" == "btrfs" ]] && cmdline="$cmdline rootflags=subvol=@"

            cat > /boot/efi/loader/loader.conf <<EOF
default arch.conf
timeout 3
console-mode max
editor no
EOF
            cat > /boot/efi/loader/entries/arch.conf <<EOF
title   Arch Linux
linux   /vmlinuz-$KERNEL
$( [[ -n "$MICROCODE" ]] && echo "initrd  /$MICROCODE.img" )
initrd  /initramfs-$KERNEL.img
options $cmdline
EOF
            run cp "/boot/vmlinuz-$KERNEL" /boot/efi/
            run cp "/boot/initramfs-$KERNEL.img" /boot/efi/
            [[ -n "$MICROCODE" ]] && run cp "/boot/$MICROCODE.img" /boot/efi/

            install -d /etc/pacman.d/hooks
            cat > /etc/pacman.d/hooks/95-systemd-boot-copy.hook <<'EOF'
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/modules/*/vmlinuz
Target = boot/initramfs-*.img
Target = boot/*-ucode.img

[Action]
Description = Copying kernel & initrd to ESP
When = PostTransaction
Exec = /bin/sh -c 'cp /boot/vmlinuz-* /boot/initramfs-*.img /boot/*-ucode.img /boot/efi/ 2>/dev/null || true'
EOF

            # Dualboot: if the ESP holds Windows' boot manager, add an entry
            # for it so tuigreet/systemd-boot can chainload it. systemd-boot
            # has no os-prober; this is the manual equivalent.
            if [[ -f /boot/efi/EFI/Microsoft/Boot/bootmgfw.efi ]]; then
                log "Detected Windows on the ESP — adding systemd-boot entry."
                cat > /boot/efi/loader/entries/windows.conf <<'EOF'
title   Windows
efi     /EFI/Microsoft/Boot/bootmgfw.efi
EOF
            fi
            ;;
        grub)
            if [[ "$FIRMWARE" == "uefi" ]]; then
                run grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
            else
                run grub-install --target=i386-pc "$DISK"
            fi
            local extra=""
            if [[ "$ENCRYPT" == "yes" ]]; then
                local uuid; uuid=$(blkid -s UUID -o value "$ROOT_PART")
                extra="cryptdevice=UUID=$uuid:cryptroot"
            fi
            sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$extra $nvidia_args\"|" /etc/default/grub

            # Dualboot: enable os-prober so grub-mkconfig discovers Windows.
            # (Disabled by default in Arch's grub package since 2.06.)
            if [[ "$MANUAL_PARTITION" == "yes" ]] || [[ -f /boot/efi/EFI/Microsoft/Boot/bootmgfw.efi ]]; then
                log "Enabling os-prober for dualboot detection."
                pacman -S --noconfirm --needed os-prober ntfs-3g 2>&1 | tee -a "$LOG_PRE" || true
                if grep -q '^GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then
                    sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
                else
                    echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
                fi
            fi

            run grub-mkconfig -o /boot/grub/grub.cfg
            ;;
    esac
}

install_pkglist() {
    [[ "$DESKTOP" != "hyprland" ]] && { log "DESKTOP=$DESKTOP — skipping desktop pkgs."; return; }

    log "Installing pacman package list..."
    local pkgs=()
    while IFS= read -r p; do pkgs+=("$p"); done < <(load_pkg_list /root/aei/packages/pacman.txt)
    run pacman -S --noconfirm --needed "${pkgs[@]}"
}

configure_greetd() {
    [[ "$DESKTOP" != "hyprland" ]] && return
    log "Configuring greetd + tuigreet + start-hyprland wrapper..."

    # Drop the wrapper script into /usr/local/bin so the greeter session can
    # find it on PATH. The wrapper exports XDG/NVIDIA env, imports it into
    # systemd-user + dbus, then exec's Hyprland.
    install -m 755 /root/aei/scripts/start-hyprland /usr/local/bin/start-hyprland

    install -d /etc/greetd
    cat > /etc/greetd/config.toml <<'EOF'
[terminal]
vt = 1

[default_session]
# `--cmd start-hyprland` (NOT `--cmd Hyprland`) — see /usr/local/bin/start-hyprland.
# Tuigreet flags: --time shows clock, --remember stores last user, --asterisks
# masks the password, --remember-user-session keeps the previous WM choice.
command = "tuigreet --time --remember --remember-user-session --asterisks --cmd start-hyprland"
user = "greeter"
EOF
    run systemctl enable greetd
}

create_user() {
    log "Setting passwords & creating $USERNAME..."
    echo "root:$ROOT_PASSWORD" | chpasswd
    local user_shell=/bin/bash
    [[ "$SHELL_CHOICE" == "zsh"  ]] && user_shell=/bin/zsh
    [[ "$SHELL_CHOICE" == "fish" ]] && user_shell=/usr/bin/fish

    if id -u "$USERNAME" >/dev/null 2>&1; then
        log "User $USERNAME already exists — skipping useradd."
    else
        run useradd -m -G wheel,audio,video,input,storage,network -s "$user_shell" "$USERNAME"
    fi
    echo "$USERNAME:$USER_PASSWORD" | chpasswd
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
    # Temp NOPASSWD so paru/AUR builds in phase 3 don't prompt. Revoked at end of phase 3.
    cat > /etc/sudoers.d/00-aei <<EOF
%wheel ALL=(ALL) NOPASSWD: ALL
EOF
    chmod 440 /etc/sudoers.d/00-aei

    # Add docker group + put user in it (no-op if docker not installed).
    if pacman -Q docker >/dev/null 2>&1; then
        getent group docker >/dev/null || groupadd docker
        gpasswd -a "$USERNAME" docker || true
    fi
}

install_phase3_hook() {
    log "Staging phase 3 (post-install) for first user login..."
    local home="/home/$USERNAME"

    install -d -m 755 -o "$USERNAME" -g "$USERNAME" "$home/aei"
    cp -r /root/aei/. "$home/aei/"
    chown -R "$USERNAME:$USERNAME" "$home/aei"
    chmod +x "$home/aei/arch-install.sh" "$home/aei/post-install.sh"

    cp /root/aei.env "$home/.aei.env"
    chown "$USERNAME:$USERNAME" "$home/.aei.env"
    chmod 600 "$home/.aei.env"

    # Append idempotent autorun to *every* common shell login profile.
    # post-install.sh handles its own done/skip logic, so even if this fires
    # repeatedly the only cost is a few stat() calls.
    local hook='
# ── aei post-install autorun (one-shot; idempotent) ─────────────────────────
if [ -f "$HOME/aei/post-install.sh" ] && [ ! -f "$HOME/.aei-done" ]; then
    "$HOME/aei/post-install.sh" || {
        echo
        echo "  aei post-install did not finish cleanly."
        echo "  Logs: ~/.aei-postinstall.log"
        echo "  Re-run anytime: ~/aei/post-install.sh"
        echo
    }
fi
'
    for f in .bash_profile .zprofile .profile; do
        # Use grep so we don't append the hook twice on re-runs.
        if [[ ! -f "$home/$f" ]] || ! grep -q "aei post-install autorun" "$home/$f"; then
            echo "$hook" >> "$home/$f"
            chown "$USERNAME:$USERNAME" "$home/$f"
        fi
    done
}

# ════════════════════════════════════════════════════════════════════════════
# DISPATCH
# ════════════════════════════════════════════════════════════════════════════
main() {
    parse_args "$@"
    case "$PHASE" in
        preflight)
            preflight_checks
            interactive_config
            select_disk
            partition_disk
            install_base
            setup_swap
            stage_chroot
            log "──────────────────────────────────────────────────────────────"
            log " Phases 1-2 complete. Run:"
            log "   umount -R $TARGET"
            [[ "$ENCRYPT" == "yes" ]] && log "   cryptsetup close cryptroot"
            log "   reboot"
            log " greetd will load tuigreet — log in as $USERNAME, post-install"
            log " (paru, AUR, dotfiles, pywal) auto-runs once."
            log "──────────────────────────────────────────────────────────────"
            ;;
        chroot) chroot_configure ;;
        *) die "Unknown phase: $PHASE" ;;
    esac
}

main "$@"
