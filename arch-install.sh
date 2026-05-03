#!/usr/bin/env bash
#
# arch-install.sh — One-shot Arch Linux installer with dotfiles
# ────────────────────────────────────────────────────────────────────────────
# Stack: Hyprland + greetd/tuigreet + Kitty + Waybar + paru + zsh/omz +
#        LazyVim + pywal (+ pywalfox) + NVIDIA auto-detect.
#
# Why Waybar over HyprPanel: in-tree (extra), themes natively from pywal via
#        ~/.cache/wal/colors-waybar.css, and what the Hyprland community
#        actually documents. HyprPanel chains 6 git AUR pkgs and doesn't
#        pywal — flag-and-forget if you change your mind later.
#
# Usage (from an Arch ISO live environment, after `loadkeys` and network up):
#
#   curl -sSLO https://your.host/arch-install.sh
#   chmod +x arch-install.sh
#   ./arch-install.sh                    # TUI (whiptail) — default
#   ./arch-install.sh --cli              # plain CLI prompts
#   ./arch-install.sh --config foo.conf  # non-interactive, from KEY=VAL file
#   ./arch-install.sh --dry-run          # print, don't execute destructive ops
#
# Phases (handled automatically — same script, re-invoked with $PHASE):
#   1. preflight   On ISO: GPU detect, partition, format, pacstrap, fstab
#   2. chroot      Inside arch-chroot: locale, users, NVIDIA, bootloader,
#                  greetd, desktop pkgs, services, chsh -> zsh
#   3. user        First login (auto via .zprofile): paru, oh-my-zsh + plugins,
#                  LazyVim, pywal, pywalfox, HyprPanel, dotfiles, starter cfgs
#
# Reboot once between phases 2 and 3. The script tells you when.
# Logs: /var/log/arch-install.log (phases 1-2), ~/.arch-install.log (phase 3).
# ────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ════════════════════════════════════════════════════════════════════════════
# CONFIG — defaults. Override via config file, CLI flags, or TUI prompts.
# ════════════════════════════════════════════════════════════════════════════
: "${HOSTNAME:=arch}"
: "${USERNAME:=daniel}"
: "${TIMEZONE:=Europe/Copenhagen}"
: "${LOCALE:=en_US.UTF-8}"
: "${KEYMAP:=us}"
: "${KERNEL:=linux}"                       # linux | linux-lts | linux-zen | linux-hardened
: "${FILESYSTEM:=ext4}"                    # ext4 | btrfs
: "${ENCRYPT:=no}"                         # yes | no   (LUKS2 on root)
: "${SWAP_SIZE:=24G}"                      # swap file size ("0" to skip)
: "${BOOTLOADER:=auto}"                    # systemd-boot | grub | auto
: "${DESKTOP:=hyprland}"                   # hyprland | kde | gnome | sway | i3 | none
: "${SHELL_CHOICE:=zsh}"                   # zsh | bash | fish
: "${AUR_HELPER:=paru}"                    # paru | yay | none
: "${INSTALL_NVIDIA:=auto}"                # auto | yes | no
: "${DOTFILES_REPO:=}"                     # e.g. https://github.com/you/dotfiles.git
: "${DOTFILES_METHOD:=stow}"               # stow | bare | script
: "${DOTFILES_BRANCH:=main}"
: "${DOTFILES_INSTALL_SCRIPT:=install.sh}"
: "${ENABLE_MULTILIB:=yes}"
# Base extras (everyone gets these). Desktop pkgs are added separately.
: "${EXTRA_PACKAGES:=git curl wget neovim tmux htop ranger fzf ripgrep fd bat eza zoxide stow openssh man-db unzip zip tree jq python python-pip nodejs npm}"
: "${ENABLE_SERVICES:=NetworkManager bluetooth sshd}"

# Don't touch unless you know why ──────────────────────────────────────────
SELF="$(readlink -f "$0")"
LOG_PRE=/var/log/arch-install.log
LOG_USER="$HOME/.arch-install.log"
PHASE="${PHASE:-preflight}"
DRY_RUN="${DRY_RUN:-no}"
USE_TUI="${USE_TUI:-auto}"
TARGET=/mnt
CONFIG_FILE=""

# ════════════════════════════════════════════════════════════════════════════
# UTILITIES
# ════════════════════════════════════════════════════════════════════════════
log_file() { [[ "$PHASE" == "user" ]] && echo "$LOG_USER" || echo "$LOG_PRE"; }
log()   { printf '\033[1;32m[+]\033[0m %s\n' "$*" | tee -a "$(log_file)"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*" | tee -a "$(log_file)"; }
err()   { printf '\033[1;31m[x]\033[0m %s\n' "$*" | tee -a "$(log_file)" >&2; }
die()   { err "$*"; exit 1; }

run() {
    if [[ "$DRY_RUN" == "yes" ]]; then
        printf '\033[1;36m[dry]\033[0m %s\n' "$*"
    else
        eval "$@" 2>&1 | tee -a "$(log_file)"
    fi
}

trap 'err "Aborted on line $LINENO. See $(log_file) for details."' ERR

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

# ════════════════════════════════════════════════════════════════════════════
# ARGS / CONFIG
# ════════════════════════════════════════════════════════════════════════════
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cli)        USE_TUI=no ;;
            --tui)        USE_TUI=yes ;;
            --dry-run)    DRY_RUN=yes ;;
            --config)     CONFIG_FILE="$2"; shift ;;
            --phase)      PHASE="$2"; shift ;;
            -h|--help)    grep -E '^# ' "$SELF" | sed 's/^# \?//'; exit 0 ;;
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

# ════════════════════════════════════════════════════════════════════════════
# HARDWARE DETECTION
# ════════════════════════════════════════════════════════════════════════════
detect_gpu() {
    GPU_VENDOR=other
    local gpu_line; gpu_line=$(lspci | grep -Ei 'vga|3d|display' || true)
    if   echo "$gpu_line" | grep -iq nvidia; then GPU_VENDOR=nvidia
    elif echo "$gpu_line" | grep -iq amd;    then GPU_VENDOR=amd
    elif echo "$gpu_line" | grep -iq intel;  then GPU_VENDOR=intel
    fi
    log "GPU vendor detected: $GPU_VENDOR"

    case "$INSTALL_NVIDIA" in
        auto) [[ "$GPU_VENDOR" == "nvidia" ]] && DO_NVIDIA=yes || DO_NVIDIA=no ;;
        yes)  DO_NVIDIA=yes ;;
        no)   DO_NVIDIA=no ;;
    esac
    log "NVIDIA driver install: $DO_NVIDIA"
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
        TIMEZONE=$(ask "Timezone (e.g. Europe/Copenhagen)" "$TIMEZONE")
        LOCALE=$(ask   "Locale" "$LOCALE")
        KEYMAP=$(ask   "Console keymap" "$KEYMAP")
        KERNEL=$(menu "Kernel" \
            linux           "Stable (recommended)" \
            linux-lts       "Long-term support" \
            linux-zen       "Tuned for desktop" \
            linux-hardened  "Security-hardened")
        FILESYSTEM=$(menu "Root filesystem" \
            ext4   "Boring & bulletproof" \
            btrfs  "Snapshots & subvolumes")
        if confirm "Encrypt root with LUKS2?"; then ENCRYPT=yes; else ENCRYPT=no; fi
        DOTFILES_REPO=$(ask "Dotfiles git URL (blank to skip)" "$DOTFILES_REPO")
        [[ -n "$DOTFILES_REPO" ]] && DOTFILES_METHOD=$(menu "Dotfiles install method" \
            stow   "GNU Stow (one subdir per package)" \
            bare   "Bare git repo in \$HOME" \
            script "Run install script from repo")
    fi

    [[ -z "${USER_PASSWORD:-}" ]] && USER_PASSWORD=$(ask_pw "Password for $USERNAME")
    [[ -z "${ROOT_PASSWORD:-}" ]] && ROOT_PASSWORD=$(ask_pw "Root password")
    if [[ "$ENCRYPT" == "yes" && -z "${LUKS_PASSWORD:-}" ]]; then
        LUKS_PASSWORD=$(ask_pw "LUKS encryption passphrase")
    fi
    # Make sure the var exists for set -u even when encryption is off.
    : "${LUKS_PASSWORD:=}"
}

select_disk() {
    log "Detecting disks..."

    # Honour a preset DISK from config / env (skip the picker entirely).
    if [[ -n "${DISK:-}" ]]; then
        [[ -b "$DISK" ]] || die "Preset DISK='$DISK' is not a block device. Use full path like /dev/sda or /dev/nvme0n1."
        log "Using preset DISK=$DISK"
        confirm "Really WIPE EVERYTHING on $DISK ?" || die "User aborted."
        confirm "Last chance. Confirm $DISK will be erased."  || die "User aborted."
        return
    fi

    # -p prints full device paths so we don't have to glue /dev/ on by hand.
    mapfile -t disks < <(lsblk -dpno NAME,SIZE,TYPE | awk '$3=="disk"{print $1, $2}')
    [[ ${#disks[@]} -eq 0 ]] && die "No disks found."

    if [[ ${#disks[@]} -eq 1 ]]; then
        # Single-disk case (typical in a VM): skip the menu and just use it.
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

    # Defensive sanity check — catches whiptail weirdness, empty selection, etc.
    [[ "$DISK" == /dev/* && -b "$DISK" ]] \
        || die "Picked DISK='$DISK' is not a valid block device. Set DISK=/dev/sda (or your path) in arch-install.conf and re-run."

    confirm "Really WIPE EVERYTHING on $DISK ?" || die "User aborted."
    confirm "Last chance. Confirm $DISK will be erased." || die "User aborted."
}

partition_disk() {
    log "Partitioning $DISK..."
    if [[ "$FIRMWARE" == "uefi" ]]; then
        run "sgdisk --zap-all $DISK"
        run "sgdisk -n1:0:+1G -t1:ef00 -c1:ESP $DISK"
        run "sgdisk -n2:0:0   -t2:8300 -c2:root $DISK"
    else
        run "sgdisk --zap-all $DISK"
        run "sgdisk -n1:0:+1M   -t1:ef02 -c1:bios $DISK"
        run "sgdisk -n2:0:+512M -t2:8300 -c2:boot $DISK"
        run "sgdisk -n3:0:0     -t3:8300 -c3:root $DISK"
    fi
    run "partprobe $DISK"; sleep 2

    if [[ "$DISK" =~ nvme|mmcblk ]]; then PFX="${DISK}p"; else PFX="$DISK"; fi
    if [[ "$FIRMWARE" == "uefi" ]]; then
        ESP_PART="${PFX}1"; ROOT_PART="${PFX}2"; BOOT_PART=""
    else
        BOOT_PART="${PFX}2"; ROOT_PART="${PFX}3"; ESP_PART=""
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

    log "Formatting ($FILESYSTEM)..."
    case "$FILESYSTEM" in
        ext4)  run "mkfs.ext4 -F $ROOT_DEV" ;;
        btrfs) run "mkfs.btrfs -f $ROOT_DEV" ;;
    esac
    [[ -n "$ESP_PART"  ]] && run "mkfs.fat -F32 $ESP_PART"
    [[ -n "$BOOT_PART" ]] && run "mkfs.ext4 -F $BOOT_PART"

    log "Mounting..."
    run "mount $ROOT_DEV $TARGET"
    if [[ "$FILESYSTEM" == "btrfs" ]]; then
        run "btrfs subvolume create $TARGET/@"
        run "btrfs subvolume create $TARGET/@home"
        run "btrfs subvolume create $TARGET/@log"
        run "btrfs subvolume create $TARGET/@pkg"
        run "umount $TARGET"
        run "mount -o noatime,compress=zstd,subvol=@      $ROOT_DEV $TARGET"
        run "mkdir -p $TARGET/{home,var/log,var/cache/pacman/pkg,boot}"
        run "mount -o noatime,compress=zstd,subvol=@home  $ROOT_DEV $TARGET/home"
        run "mount -o noatime,compress=zstd,subvol=@log   $ROOT_DEV $TARGET/var/log"
        run "mount -o noatime,compress=zstd,subvol=@pkg   $ROOT_DEV $TARGET/var/cache/pacman/pkg"
    fi
    run "mkdir -p $TARGET/boot"
    if [[ "$FIRMWARE" == "uefi" ]]; then
        run "mkdir -p $TARGET/boot/efi"
        run "mount $ESP_PART $TARGET/boot/efi"
    else
        run "mount $BOOT_PART $TARGET/boot"
    fi
}

install_base() {
    log "Pacstrapping base..."
    local pkgs=(base "$KERNEL" "${KERNEL}-headers" linux-firmware
                base-devel sudo networkmanager
                vim man-db man-pages texinfo
                pacman-contrib reflector
                zsh)                       # so chsh -> zsh works in chroot
    [[ "$FILESYSTEM" == "btrfs" ]] && pkgs+=(btrfs-progs)
    [[ "$ENCRYPT"    == "yes"   ]] && pkgs+=(cryptsetup)
    [[ "$BOOTLOADER" == "grub"  ]] && pkgs+=(grub $( [[ "$FIRMWARE" == "uefi" ]] && echo efibootmgr ))

    if grep -q "GenuineIntel" /proc/cpuinfo; then pkgs+=(intel-ucode); MICROCODE=intel-ucode
    elif grep -q "AuthenticAMD" /proc/cpuinfo; then pkgs+=(amd-ucode); MICROCODE=amd-ucode
    else MICROCODE=""; fi

    run "reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist"
    run "pacstrap -K $TARGET ${pkgs[*]}"

    log "Generating fstab..."
    run "genfstab -U $TARGET >> $TARGET/etc/fstab"
}

setup_swap() {
    [[ "$SWAP_SIZE" == "0" ]] && return
    log "Creating ${SWAP_SIZE} swap file..."

    if [[ "$FILESYSTEM" == "btrfs" ]]; then
        if btrfs filesystem mkswapfile --help 2>&1 | grep -q -- '--size'; then
            run "btrfs filesystem mkswapfile --size $SWAP_SIZE $TARGET/swapfile"
        else
            warn "btrfs-progs too old for mkswapfile; falling back to chattr+dd"
            run "touch $TARGET/swapfile"
            run "chattr +C $TARGET/swapfile"
            local mb; mb=$(numfmt --from=iec "$SWAP_SIZE" | awk '{print int($1/1024/1024)}')
            run "dd if=/dev/zero of=$TARGET/swapfile bs=1M count=$mb status=progress"
            run "chmod 600 $TARGET/swapfile"
            run "mkswap $TARGET/swapfile"
        fi
    else
        local mb; mb=$(numfmt --from=iec "$SWAP_SIZE" | awk '{print int($1/1024/1024)}')
        run "dd if=/dev/zero of=$TARGET/swapfile bs=1M count=$mb status=progress"
        run "chmod 600 $TARGET/swapfile"
        run "mkswap $TARGET/swapfile"
    fi

    run "echo '/swapfile none swap defaults 0 0' >> $TARGET/etc/fstab"
}

stage_chroot() {
    log "Copying installer into target and running phase 2..."
    run "cp $SELF $TARGET/root/arch-install.sh"
    run "chmod +x $TARGET/root/arch-install.sh"

    if [[ "$DRY_RUN" == "yes" ]]; then
        printf '\033[1;36m[dry]\033[0m would write %s/root/arch-install.env (chroot env vars)\n' "$TARGET"
    else
        cat > "$TARGET/root/arch-install.env" <<EOF
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
DOTFILES_REPO='$DOTFILES_REPO'
DOTFILES_METHOD='$DOTFILES_METHOD'
DOTFILES_BRANCH='$DOTFILES_BRANCH'
DOTFILES_INSTALL_SCRIPT='$DOTFILES_INSTALL_SCRIPT'
ENABLE_MULTILIB='$ENABLE_MULTILIB'
EXTRA_PACKAGES='$EXTRA_PACKAGES'
ENABLE_SERVICES='$ENABLE_SERVICES'
FIRMWARE='$FIRMWARE'
ROOT_PART='$ROOT_PART'
ESP_PART='${ESP_PART:-}'
BOOT_PART='${BOOT_PART:-}'
DISK='$DISK'
MICROCODE='${MICROCODE:-}'
ROOT_PASSWORD='$ROOT_PASSWORD'
USER_PASSWORD='$USER_PASSWORD'
PHASE='chroot'
USE_TUI='no'
EOF
        chmod 600 "$TARGET/root/arch-install.env"
    fi
    run "arch-chroot $TARGET /bin/bash -c 'set -a; source /root/arch-install.env; set +a; /root/arch-install.sh --phase chroot --cli'"
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 2 — IN CHROOT
# ════════════════════════════════════════════════════════════════════════════
chroot_configure() {
    log "Phase 2: configuring system inside chroot..."
    run "ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime"
    run "hwclock --systohc"

    sed -i "s/^#\s*\(${LOCALE}\)/\1/" /etc/locale.gen
    run "locale-gen"
    echo "LANG=$LOCALE"     > /etc/locale.conf
    echo "KEYMAP=$KEYMAP"   > /etc/vconsole.conf
    echo "$HOSTNAME"        > /etc/hostname
    cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

    if [[ "$ENABLE_MULTILIB" == "yes" ]]; then
        sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
        run "pacman -Syy --noconfirm"
    fi

    install_nvidia          # must run BEFORE mkinitcpio/bootloader
    configure_mkinitcpio
    install_bootloader
    install_desktop_packages
    configure_greetd
    create_user

    log "Enabling services: $ENABLE_SERVICES"
    for s in $ENABLE_SERVICES; do run "systemctl enable $s"; done

    install_phase3_hook
    log "Phase 2 complete."
}

install_nvidia() {
    [[ "$DO_NVIDIA" != "yes" ]] && { log "Skipping NVIDIA driver."; return; }
    log "Installing NVIDIA proprietary drivers..."
    # nvidia-dkms = matches whatever kernel; nvidia-utils = userspace; egl-wayland needed for Hyprland on NVIDIA
    local nv=(nvidia-dkms nvidia-utils lib32-nvidia-utils nvidia-settings
              libva-nvidia-driver egl-wayland)
    run "pacman -S --noconfirm --needed ${nv[*]}"

    # Pacman hook: rebuild initramfs after nvidia upgrade
    install -d /etc/pacman.d/hooks
    cat > /etc/pacman.d/hooks/nvidia.hook <<'EOF'
[Trigger]
Operation=Install
Operation=Upgrade
Operation=Remove
Type=Package
Target=nvidia
Target=nvidia-dkms
Target=nvidia-lts
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
        # Set NVIDIA modules; drop "kms" hook so nouveau doesn't load early.
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
        # Append btrfs without clobbering nvidia entries
        if grep -q '^MODULES=(nvidia' /etc/mkinitcpio.conf; then
            sed -i 's/^MODULES=(\(.*\))/MODULES=(\1 btrfs)/' /etc/mkinitcpio.conf
        else
            sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
        fi
    fi
    run "mkinitcpio -P"
}

install_bootloader() {
    log "Bootloader: $BOOTLOADER"
    local nvidia_args=""
    [[ "$DO_NVIDIA" == "yes" ]] && nvidia_args="nvidia_drm.modeset=1 nvidia_drm.fbdev=1"

    case "$BOOTLOADER" in
        systemd-boot)
            run "bootctl --path=/boot/efi install"
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
            run "cp /boot/vmlinuz-$KERNEL /boot/efi/"
            run "cp /boot/initramfs-$KERNEL.img /boot/efi/"
            [[ -n "$MICROCODE" ]] && run "cp /boot/$MICROCODE.img /boot/efi/"
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
            ;;
        grub)
            if [[ "$FIRMWARE" == "uefi" ]]; then
                run "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB"
            else
                run "grub-install --target=i386-pc $DISK"
            fi
            local extra=""
            if [[ "$ENCRYPT" == "yes" ]]; then
                local uuid; uuid=$(blkid -s UUID -o value "$ROOT_PART")
                extra="cryptdevice=UUID=$uuid:cryptroot"
            fi
            sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$extra $nvidia_args\"|" /etc/default/grub
            run "grub-mkconfig -o /boot/grub/grub.cfg"
            ;;
    esac
}

install_desktop_packages() {
    log "Installing desktop ($DESKTOP)..."

    # Always install user's base extras + chosen shell
    local extras=($EXTRA_PACKAGES $SHELL_CHOICE)
    run "pacman -S --noconfirm --needed ${extras[*]}"

    case "$DESKTOP" in
        hyprland)
            local pkgs=(
                # Core compositor + portals
                hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
                # Lock / idle / wallpaper / picker
                hyprlock hypridle hyprpicker swww
                # Terminal
                kitty
                # Status bar — Waybar is in extra, themes from pywal natively
                waybar
                # Launcher
                rofi-wayland wofi
                # Notifications
                mako libnotify
                # Audio (pipewire stack)
                pipewire pipewire-pulse pipewire-alsa wireplumber pavucontrol
                # File / clipboard / screenshot tooling
                thunar thunar-volman gvfs wl-clipboard cliphist grim slurp swappy
                # Hardware controls
                brightnessctl playerctl bluez bluez-utils network-manager-applet
                # Polkit + Qt theming
                polkit-kde-agent qt5-wayland qt6-wayland
                # Fonts
                ttf-jetbrains-mono-nerd ttf-firacode-nerd noto-fonts noto-fonts-emoji noto-fonts-cjk
                # Pywal core (templates) — official repo
                python-pywal imagemagick
                # Browser (will be themed via pywalfox-native from AUR)
                firefox
                # Greeter
                greetd greetd-tuigreet
                # XDG basics
                xdg-user-dirs xdg-utils
            )
            run "pacman -S --noconfirm --needed ${pkgs[*]}"
            ;;
        kde)
            run "pacman -S --noconfirm --needed plasma-meta kde-applications-meta sddm firefox"
            run "systemctl enable sddm"
            ;;
        gnome)
            run "pacman -S --noconfirm --needed gnome gnome-tweaks gdm firefox"
            run "systemctl enable gdm"
            ;;
        sway)
            run "pacman -S --noconfirm --needed sway swaybg swaylock swayidle waybar foot wofi pipewire pipewire-pulse wireplumber wl-clipboard brightnessctl playerctl polkit ttf-jetbrains-mono-nerd"
            ;;
        i3)
            run "pacman -S --noconfirm --needed xorg-server xorg-xinit i3-wm i3status i3lock dmenu rxvt-unicode picom feh ttf-jetbrains-mono-nerd lightdm lightdm-gtk-greeter"
            run "systemctl enable lightdm"
            ;;
        none) ;;
    esac
}

configure_greetd() {
    [[ "$DESKTOP" != "hyprland" ]] && return
    log "Configuring greetd + tuigreet..."
    install -d /etc/greetd
    cat > /etc/greetd/config.toml <<EOF
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --remember-user-session --asterisks --cmd Hyprland"
user = "greeter"
EOF
    run "systemctl enable greetd"
}

create_user() {
    log "Setting passwords & creating $USERNAME..."
    echo "root:$ROOT_PASSWORD" | chpasswd
    local user_shell="/bin/bash"
    [[ "$SHELL_CHOICE" == "zsh"  ]] && user_shell="/bin/zsh"
    [[ "$SHELL_CHOICE" == "fish" ]] && user_shell="/usr/bin/fish"
    run "useradd -m -G wheel,audio,video,input,storage,network -s $user_shell $USERNAME"
    echo "$USERNAME:$USER_PASSWORD" | chpasswd
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
    # Allow wheel to run pacman/makepkg without password during phase 3 (revoked at the end).
    cat > /etc/sudoers.d/00-arch-install <<EOF
%wheel ALL=(ALL) NOPASSWD: ALL
EOF
    chmod 440 /etc/sudoers.d/00-arch-install
}

install_phase3_hook() {
    log "Staging phase 3 (paru, omz, dotfiles, pywal) for first user login..."
    install -d -m 700 -o "$USERNAME" -g "$USERNAME" "/home/$USERNAME/.local/bin"
    cp /root/arch-install.sh  "/home/$USERNAME/.local/bin/arch-install.sh"
    cp /root/arch-install.env "/home/$USERNAME/.arch-install.env"
    chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.local" "/home/$USERNAME/.arch-install.env"
    chmod 600 "/home/$USERNAME/.arch-install.env"
    chmod +x  "/home/$USERNAME/.local/bin/arch-install.sh"

    # Hook fires from whichever shell login profile is in use.
    local hook='
# ── arch-install one-shot phase 3 ───────────────────────────────────────────
if [ -f "$HOME/.arch-install.env" ] && [ ! -f "$HOME/.arch-install.done" ]; then
    set -a; . "$HOME/.arch-install.env"; set +a
    if PHASE=user "$HOME/.local/bin/arch-install.sh" --phase user --cli; then
        touch "$HOME/.arch-install.done"
    else
        echo
        echo "  Phase 3 did not complete cleanly. Logs: ~/.arch-install.log"
        echo "  Fix the issue, then retry with:"
        echo "    PHASE=user ~/.local/bin/arch-install.sh --phase user --cli && touch ~/.arch-install.done"
        echo
    fi
fi
'
    for f in .bash_profile .zprofile .profile; do
        echo "$hook" >> "/home/$USERNAME/$f"
        chown "$USERNAME:$USERNAME" "/home/$USERNAME/$f"
    done
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 3 — USER (first login)
# ════════════════════════════════════════════════════════════════════════════
user_setup() {
    log "Phase 3: user setup as $(whoami)..."
    install_aur_helper
    install_aur_packages
    install_oh_my_zsh
    install_lazyvim
    setup_pywal
    install_dotfiles
    bootstrap_configs
    finalize
    log "──────────────────────────────────────────────────────────────"
    log " Phase 3 complete. Log out and log back in (or reboot) to drop"
    log " into the themed Hyprland session via greetd/tuigreet."
    log " Logs: $LOG_USER"
    log "──────────────────────────────────────────────────────────────"
}

install_aur_helper() {
    [[ "$AUR_HELPER" == "none" ]] && return
    command -v "$AUR_HELPER" >/dev/null && { log "$AUR_HELPER already installed."; return; }
    log "Building $AUR_HELPER from AUR..."
    local tmp; tmp=$(mktemp -d)
    run "git clone https://aur.archlinux.org/$AUR_HELPER.git $tmp/$AUR_HELPER"
    ( cd "$tmp/$AUR_HELPER" && makepkg -si --noconfirm )
    rm -rf "$tmp"
}

install_aur_packages() {
    [[ "$AUR_HELPER" == "none" ]] && return
    log "Installing AUR packages (pywalfox)..."
    local aur=()
    [[ "$DESKTOP" == "hyprland" ]] && aur+=(python-pywalfox)
    # Add anything else here you want from AUR by default:
    # aur+=(visual-studio-code-bin spotify-launcher discord ags-hyprpanel-git)

    # Install each individually so a single build failure doesn't block the rest
    # of phase 3 (oh-my-zsh, LazyVim, pywal, configs, etc.). Failures get
    # logged as warnings and surfaced in the final summary.
    AUR_FAILED=()
    for pkg in "${aur[@]}"; do
        log "→ AUR: $pkg"
        if "$AUR_HELPER" -S --needed --noconfirm "$pkg" 2>&1 | tee -a "$(log_file)"; then
            log "  ✓ $pkg installed"
        else
            warn "  ✗ $pkg failed to build — continuing without it."
            AUR_FAILED+=("$pkg")
        fi
    done
    if [[ ${#AUR_FAILED[@]} -gt 0 ]]; then
        warn "AUR packages that did NOT install: ${AUR_FAILED[*]}"
    fi
}

install_oh_my_zsh() {
    [[ "$SHELL_CHOICE" != "zsh" ]] && return
    log "Installing oh-my-zsh + plugins..."
    if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
        run 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended --keep-zshrc'
    fi
    local custom="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
    [[ ! -d "$custom/plugins/zsh-autosuggestions" ]] && \
        run "git clone https://github.com/zsh-users/zsh-autosuggestions $custom/plugins/zsh-autosuggestions"
    [[ ! -d "$custom/plugins/zsh-syntax-highlighting" ]] && \
        run "git clone https://github.com/zsh-users/zsh-syntax-highlighting.git $custom/plugins/zsh-syntax-highlighting"

    # Generate a sensible .zshrc only if dotfiles haven't dropped one with the plugins already wired.
    if [[ ! -f "$HOME/.zshrc" ]] || ! grep -q "zsh-autosuggestions" "$HOME/.zshrc" 2>/dev/null; then
        cat > "$HOME/.zshrc" <<'ZSHRC'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="agnoster"
plugins=(git sudo command-not-found z fzf docker docker-compose npm node python pip
         zsh-autosuggestions zsh-syntax-highlighting)
source $ZSH/oh-my-zsh.sh

# Pywal: load the cached palette every shell
[ -f "$HOME/.cache/wal/sequences" ] && cat "$HOME/.cache/wal/sequences"
[ -f "$HOME/.cache/wal/colors-tty.sh" ] && source "$HOME/.cache/wal/colors-tty.sh"

# Editor / tooling
export EDITOR=nvim
export VISUAL=nvim
alias v=nvim
alias vi=nvim
alias ll='eza -lah --icons --git'
alias ls='eza --icons'
alias cat='bat --paging=never'
alias cd='z'
eval "$(zoxide init zsh)"

export PATH="$HOME/.local/bin:$PATH"
ZSHRC
    fi
}

install_lazyvim() {
    log "Bootstrapping LazyVim with language extras..."
    if [[ -d "$HOME/.config/nvim" ]] && [[ -n "$(ls -A "$HOME/.config/nvim" 2>/dev/null)" ]]; then
        log "Existing nvim config found — skipping LazyVim bootstrap."
        return
    fi
    install -d "$HOME/.config/nvim"
    run "git clone https://github.com/LazyVim/starter $HOME/.config/nvim"
    rm -rf "$HOME/.config/nvim/.git"

    # Pre-enable LazyVim "extras" — Mason auto-installs LSP/DAP/formatters for each.
    cat > "$HOME/.config/nvim/lua/plugins/extras.lua" <<'LUA'
-- Auto-loaded via LazyVim's `{ import = "plugins" }` entry. Trim what you don't use.
return {
  { import = "lazyvim.plugins.extras.lang.typescript" },
  { import = "lazyvim.plugins.extras.lang.json" },
  { import = "lazyvim.plugins.extras.lang.yaml" },
  { import = "lazyvim.plugins.extras.lang.toml" },
  { import = "lazyvim.plugins.extras.lang.markdown" },
  { import = "lazyvim.plugins.extras.lang.python" },
  { import = "lazyvim.plugins.extras.lang.rust" },
  { import = "lazyvim.plugins.extras.lang.go" },
  { import = "lazyvim.plugins.extras.lang.php" },
  { import = "lazyvim.plugins.extras.lang.tailwind" },
  { import = "lazyvim.plugins.extras.lang.docker" },
  { import = "lazyvim.plugins.extras.lang.git" },
  { import = "lazyvim.plugins.extras.lang.sql" },
  { import = "lazyvim.plugins.extras.lang.bash" },
  { import = "lazyvim.plugins.extras.editor.harpoon2" },
  { import = "lazyvim.plugins.extras.formatting.prettier" },
  { import = "lazyvim.plugins.extras.linting.eslint" },
  { import = "lazyvim.plugins.extras.util.dot" },
}
LUA

    # Headless install + sync — first-run cost paid here, not on first launch.
    run "nvim --headless '+Lazy! sync' +qa || true"
}

setup_pywal() {
    log "Seeding pywal palette..."
    install -d "$HOME/Pictures/wallpapers"
    # Try Arch's wallpapers; fall back to a synthesised gradient.
    if pacman -Q archlinux-wallpaper >/dev/null 2>&1 || sudo pacman -S --noconfirm --needed archlinux-wallpaper 2>/dev/null; then
        local src; src=$(find /usr/share/backgrounds/archlinux -type f \( -iname '*.jpg' -o -iname '*.png' \) 2>/dev/null | head -1)
        [[ -n "$src" ]] && cp "$src" "$HOME/Pictures/wallpapers/default.jpg"
    fi
    if [[ ! -f "$HOME/Pictures/wallpapers/default.jpg" ]]; then
        run "convert -size 1920x1080 gradient:'#1a1b26-#414868' $HOME/Pictures/wallpapers/default.jpg"
    fi

    # -n: don't set wallpaper (swww does that), -s/-t skip terminal seq+title, -e skip reload, -q quiet
    run "wal -i $HOME/Pictures/wallpapers/default.jpg -n -s -t -e -q"

    # Firefox theming bridge — pywalfox needs the browser extension installed too,
    # but `pywalfox install` does the native-host part.
    if command -v pywalfox >/dev/null 2>&1; then
        run "pywalfox install || true"
        run "pywalfox update  || true"
    fi
}

install_dotfiles() {
    [[ -z "$DOTFILES_REPO" ]] && { log "No DOTFILES_REPO — skipping."; return; }
    log "Installing dotfiles ($DOTFILES_METHOD) from $DOTFILES_REPO"
    case "$DOTFILES_METHOD" in
        stow)
            local dir="$HOME/.dotfiles"
            run "git clone --branch '$DOTFILES_BRANCH' '$DOTFILES_REPO' '$dir'"
            command -v stow >/dev/null || run "sudo pacman -S --noconfirm stow"
            ( cd "$dir" && for pkg in */; do
                  [[ -d "$pkg" ]] || continue
                  log "stow $pkg"
                  stow -v -R -t "$HOME" "${pkg%/}" || warn "stow conflict on $pkg — resolve manually"
              done )
            ;;
        bare)
            run "git clone --bare --branch '$DOTFILES_BRANCH' '$DOTFILES_REPO' $HOME/.cfg"
            git --git-dir="$HOME/.cfg" --work-tree="$HOME" config --local status.showUntrackedFiles no
            mkdir -p "$HOME/.dotfiles-backup"
            git --git-dir="$HOME/.cfg" --work-tree="$HOME" checkout 2>&1 \
                | grep -E "^\s+\." | awk '{print $1}' \
                | while read -r f; do
                      mkdir -p "$HOME/.dotfiles-backup/$(dirname "$f")"
                      mv "$HOME/$f" "$HOME/.dotfiles-backup/$f" || true
                  done
            git --git-dir="$HOME/.cfg" --work-tree="$HOME" checkout
            ;;
        script)
            local dir="$HOME/.dotfiles"
            run "git clone --branch '$DOTFILES_BRANCH' '$DOTFILES_REPO' '$dir'"
            [[ -x "$dir/$DOTFILES_INSTALL_SCRIPT" ]] || die "$DOTFILES_INSTALL_SCRIPT not found/executable in repo"
            ( cd "$dir" && "./$DOTFILES_INSTALL_SCRIPT" )
            ;;
    esac
}

# ────────────────────────────────────────────────────────────────────────────
# Starter configs — only written if dotfiles didn't drop their own.
# ────────────────────────────────────────────────────────────────────────────
bootstrap_configs() {
    [[ "$DESKTOP" != "hyprland" ]] && return
    log "Writing starter configs (skipping any that dotfiles already provide)..."

    install -d "$HOME/.config/hypr"
    if [[ ! -f "$HOME/.config/hypr/hyprland.conf" ]]; then
        local nv_env=""
        if [[ "$DO_NVIDIA" == "yes" ]]; then
            nv_env=$(cat <<'NVEOF'
# ── NVIDIA ─────────────────────────────────────────────────────────────────
env = LIBVA_DRIVER_NAME,nvidia
env = XDG_SESSION_TYPE,wayland
env = GBM_BACKEND,nvidia-drm
env = __GLX_VENDOR_LIBRARY_NAME,nvidia
env = NVD_BACKEND,direct
env = ELECTRON_OZONE_PLATFORM_HINT,auto
NVEOF
)
        fi
        cat > "$HOME/.config/hypr/hyprland.conf" <<HYPR
# ── Starter Hyprland config ────────────────────────────────────────────────
# Generated by arch-install.sh. Edit freely or replace via dotfiles.
# Docs: https://wiki.hypr.land

monitor=,preferred,auto,1

\$mod = SUPER
\$term = kitty
\$menu = rofi -show drun

$nv_env

# Pywal palette (regenerated on each \`wal -i\`)
source = ~/.cache/wal/colors-hyprland.conf

input {
  kb_layout = $KEYMAP
  follow_mouse = 1
  touchpad { natural_scroll = true }
  sensitivity = 0
}

general {
  gaps_in = 4
  gaps_out = 8
  border_size = 2
  col.active_border = \$color4 \$color6 45deg
  col.inactive_border = \$color0
  layout = dwindle
}

decoration {
  rounding = 8
  blur { enabled = true; size = 6; passes = 2; new_optimizations = true }
  shadow { enabled = true; range = 12; render_power = 3 }
}

animations {
  enabled = true
  bezier  = ease,0.05,0.9,0.1,1.0
  animation = windows,    1, 5, ease
  animation = fade,       1, 5, ease
  animation = workspaces, 1, 5, ease
}

dwindle { pseudotile = true; preserve_split = true }
misc    { disable_hyprland_logo = true; force_default_wallpaper = 0 }

# Autostart
exec-once = swww-daemon
exec-once = sleep 1 && swww img ~/Pictures/wallpapers/default.jpg --transition-type any
exec-once = wal -R
exec-once = waybar
exec-once = mako
exec-once = /usr/lib/polkit-kde-authentication-agent-1
exec-once = wl-paste --type text  --watch cliphist store
exec-once = wl-paste --type image --watch cliphist store
exec-once = nm-applet --indicator
exec-once = blueman-applet
exec-once = hypridle

# Keybinds
bind = \$mod, Return, exec, \$term
bind = \$mod, Q, killactive
bind = \$mod SHIFT, E, exit
bind = \$mod, E, exec, thunar
bind = \$mod, R, exec, \$menu
bind = \$mod, V, togglefloating
bind = \$mod, F, fullscreen
bind = \$mod, P, pseudo
bind = \$mod, J, togglesplit
bind = \$mod, L, exec, hyprlock

# Move focus
bind = \$mod, left,  movefocus, l
bind = \$mod, right, movefocus, r
bind = \$mod, up,    movefocus, u
bind = \$mod, down,  movefocus, d

# Workspaces 1-9
bind = \$mod, 1, workspace, 1
bind = \$mod, 2, workspace, 2
bind = \$mod, 3, workspace, 3
bind = \$mod, 4, workspace, 4
bind = \$mod, 5, workspace, 5
bind = \$mod, 6, workspace, 6
bind = \$mod, 7, workspace, 7
bind = \$mod, 8, workspace, 8
bind = \$mod, 9, workspace, 9
bind = \$mod SHIFT, 1, movetoworkspace, 1
bind = \$mod SHIFT, 2, movetoworkspace, 2
bind = \$mod SHIFT, 3, movetoworkspace, 3
bind = \$mod SHIFT, 4, movetoworkspace, 4
bind = \$mod SHIFT, 5, movetoworkspace, 5
bind = \$mod SHIFT, 6, movetoworkspace, 6
bind = \$mod SHIFT, 7, movetoworkspace, 7
bind = \$mod SHIFT, 8, movetoworkspace, 8
bind = \$mod SHIFT, 9, movetoworkspace, 9

# Mouse
bindm = \$mod, mouse:272, movewindow
bindm = \$mod, mouse:273, resizewindow

# Screenshots
bind = , Print,         exec, grim -g "\$(slurp)" - | swappy -f -
bind = SHIFT, Print,    exec, grim - | swappy -f -

# Volume / brightness / media
bindel = , XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+
bindel = , XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindel = , XF86AudioMute,        exec, wpctl set-mute   @DEFAULT_AUDIO_SINK@ toggle
bindel = , XF86MonBrightnessUp,   exec, brightnessctl s 5%+
bindel = , XF86MonBrightnessDown, exec, brightnessctl s 5%-
bindl  = , XF86AudioPlay, exec, playerctl play-pause
bindl  = , XF86AudioNext, exec, playerctl next
bindl  = , XF86AudioPrev, exec, playerctl previous
HYPR
    fi

    # hyprlock starter
    if [[ ! -f "$HOME/.config/hypr/hyprlock.conf" ]]; then
        cat > "$HOME/.config/hypr/hyprlock.conf" <<'EOF'
source = ~/.cache/wal/colors-hyprland.conf
background {
  monitor =
  path    = ~/Pictures/wallpapers/default.jpg
  blur_passes = 2
}
input-field {
  monitor =
  size    = 240, 50
  position = 0, -120
  halign = center
  valign = center
  outline_thickness = 2
  outer_color = $color4
  inner_color = $color0
  font_color  = $color7
  fade_on_empty = true
  placeholder_text = <i>Password…</i>
}
label {
  monitor =
  text = cmd[update:1000] echo "$(date +"%H:%M")"
  font_size = 90
  position = 0, 200
  halign = center
  valign = center
  color = $color7
}
EOF
    fi

    # hypridle starter
    if [[ ! -f "$HOME/.config/hypr/hypridle.conf" ]]; then
        cat > "$HOME/.config/hypr/hypridle.conf" <<'EOF'
general {
  lock_cmd = pidof hyprlock || hyprlock
  before_sleep_cmd = loginctl lock-session
  after_sleep_cmd = hyprctl dispatch dpms on
}
listener { timeout = 300;  on-timeout = brightnessctl -s set 10; on-resume = brightnessctl -r }
listener { timeout = 600;  on-timeout = loginctl lock-session }
listener { timeout = 660;  on-timeout = hyprctl dispatch dpms off; on-resume = hyprctl dispatch dpms on }
listener { timeout = 1800; on-timeout = systemctl suspend }
EOF
    fi

    # Kitty config — pywal-themed
    install -d "$HOME/.config/kitty"
    if [[ ! -f "$HOME/.config/kitty/kitty.conf" ]]; then
        cat > "$HOME/.config/kitty/kitty.conf" <<'EOF'
font_family      JetBrainsMono Nerd Font
font_size        12
enable_audio_bell no
window_padding_width 8
confirm_os_window_close 0
background_opacity 0.92

# Pywal — pywal writes ~/.cache/wal/colors-kitty.conf on each `wal -i`
include ~/.cache/wal/colors-kitty.conf

# Sensible keybinds
map ctrl+shift+enter new_window
map ctrl+shift+t     new_tab
map ctrl+shift+w     close_window
EOF
    fi

    # Rofi — point at the pywal-generated rasi
    install -d "$HOME/.config/rofi"
    if [[ ! -f "$HOME/.config/rofi/config.rasi" ]]; then
        cat > "$HOME/.config/rofi/config.rasi" <<'EOF'
@theme "~/.cache/wal/colors-rofi-dark.rasi"
configuration {
  modi: "drun,run,window";
  show-icons: true;
  font: "JetBrainsMono Nerd Font 11";
  display-drun: " ";
  display-run:  " ";
  display-window: " ";
}
EOF
    fi

    # Waybar — config + pywal-themed stylesheet
    install -d "$HOME/.config/waybar"
    if [[ ! -f "$HOME/.config/waybar/config.jsonc" ]]; then
        cat > "$HOME/.config/waybar/config.jsonc" <<'EOF'
{
  "layer": "top",
  "position": "top",
  "height": 32,
  "spacing": 4,
  "modules-left":   ["hyprland/workspaces", "hyprland/window"],
  "modules-center": ["clock"],
  "modules-right":  ["tray", "pulseaudio", "network", "cpu", "memory", "battery"],

  "hyprland/workspaces": {
    "format": "{icon}",
    "format-icons": {
      "1": "1", "2": "2", "3": "3", "4": "4", "5": "5",
      "6": "6", "7": "7", "8": "8", "9": "9",
      "active": "●", "default": "○"
    },
    "on-click": "activate"
  },
  "hyprland/window": { "max-length": 50 },
  "clock": {
    "format":          " {:%H:%M}",
    "format-alt":      " {:%a %Y-%m-%d %H:%M}",
    "tooltip-format":  "<tt><small>{calendar}</small></tt>"
  },
  "cpu":      { "format": " {usage}%", "interval": 5 },
  "memory":   { "format": " {percentage}%", "interval": 5 },
  "network": {
    "format-wifi":         " {essid}",
    "format-ethernet":     " connected",
    "format-disconnected": "⚠ off",
    "tooltip-format":      "{ifname}: {ipaddr}"
  },
  "pulseaudio": {
    "format":         "{icon} {volume}%",
    "format-muted":   " muted",
    "format-icons":   { "default": ["", "", ""] },
    "on-click":       "pavucontrol",
    "scroll-step":    5
  },
  "battery": {
    "states":          { "warning": 30, "critical": 15 },
    "format":          "{icon} {capacity}%",
    "format-charging": "  {capacity}%",
    "format-plugged":  " {capacity}%",
    "format-icons":    ["", "", "", "", ""]
  },
  "tray": { "icon-size": 18, "spacing": 8 }
}
EOF
    fi

    if [[ ! -f "$HOME/.config/waybar/style.css" ]]; then
        # NOTE: $HOME is interpolated so the @import has an absolute path —
        # waybar's GTK CSS engine doesn't always resolve ~ correctly.
        cat > "$HOME/.config/waybar/style.css" <<EOF
/* Pywal palette — regenerated on every \`wal -i\` */
@import "$HOME/.cache/wal/colors-waybar.css";

* {
  border: none;
  border-radius: 0;
  font-family: "JetBrainsMono Nerd Font", monospace;
  font-size: 13px;
  min-height: 0;
}

window#waybar {
  background: alpha(@background, 0.85);
  color: @foreground;
  transition-duration: .2s;
}

#workspaces button {
  padding: 0 10px;
  background: transparent;
  color: @color8;
  border-bottom: 2px solid transparent;
}
#workspaces button.active {
  color: @foreground;
  border-bottom: 2px solid @color4;
}
#workspaces button.urgent {
  color: @color1;
  border-bottom: 2px solid @color1;
}

#window, #clock, #cpu, #memory, #network, #pulseaudio, #battery, #tray {
  padding: 0 12px;
  color: @foreground;
}

#battery.warning  { color: @color3; }
#battery.critical { color: @color1; }
EOF
    fi
}

finalize() {
    log "Locking down sudoers (revoking NOPASSWD)..."
    run "sudo rm -f /etc/sudoers.d/00-arch-install"
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
            log " greetd will load tuigreet — log in as $USERNAME, phase 3"
            log " (paru, omz, LazyVim, pywal, dotfiles) auto-runs once."
            log "──────────────────────────────────────────────────────────────"
            ;;
        chroot) chroot_configure ;;
        user)   user_setup ;;
        *) die "Unknown phase: $PHASE" ;;
    esac
}

main "$@"
