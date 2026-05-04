# aei — arch easy install

One-shot Arch Linux installer that drops you into a themed Hyprland desktop
on first reboot. Installs the system, the desktop, and a complete pywal
"alchemia" theme (purple/gold/violet) across waybar, rofi, kitty, mako,
hyprlock, wlogout and neovim.

```
ISO live env  ──►  arch-install.sh  ──►  reboot  ──►  greetd login  ──►  post-install.sh (auto)  ──►  done
   phase 1            phase 2 (chroot)                                   phase 3 (your user)
```

## TL;DR

```bash
# Inside the Arch ISO, after `loadkeys us` and a working network:
pacman -Sy --noconfirm git
git clone https://github.com/danielradosa/aei && cd aei
./arch-install.sh --config arch-install.conf
# ↑ uses the bundled defaults. Drop the flag to be prompted for everything.
```

When phase 1+2 finish: `umount -R /mnt && reboot`.
Log in via tuigreet — phase 3 (paru, AUR, oh-my-zsh, dotfiles, pywal) runs
itself once. Re-runnable any time with `~/aei/post-install.sh`.

---

## Full setup, end-to-end

### 1. Download the Arch ISO

Grab `archlinux-x86_64.iso` from a mirror near you:
[https://archlinux.org/download/](https://archlinux.org/download/)

Verify the signature if you care:

```bash
gpg --keyserver-options auto-key-retrieve --verify archlinux-*.iso.sig
```

### 2. Make a bootable USB

You need an 8 GB+ USB stick. **Anything on it gets wiped — back it up first.**

#### Coming from Windows?

Use **Rufus** (`https://rufus.ie`) — it's a single 1.4 MB `.exe`, no install:

1. Plug in the USB stick.
2. Open Rufus → **Device** = your USB.
3. **Boot selection** → *SELECT* → pick `archlinux-x86_64.iso`.
4. A popup asks "ISOHybrid image detected — write in ISO Image mode or DD
   Image mode?" → **choose "DD Image mode"**. ISO mode breaks the Arch ISO's
   layout and the resulting USB won't boot.
5. *Partition scheme* = **GPT**, *Target system* = **UEFI (non CSM)** for any
   machine made after ~2012. (BIOS/MBR if you have an older box.)
6. *START* → confirm the wipe → wait ~3 min.

**Balena Etcher** (`https://etcher.balena.io`) is the friendlier alternative —
GUI on Windows/macOS/Linux, no DD-mode prompt to think about, just *Flash from
file → Select target → Flash*. Slightly slower but harder to misuse.

> Don't use Windows' built-in "burn ISO" tool, the Microsoft USB/DVD tool, or
> UNetbootin — they all produce a USB the Arch ISO won't boot from.

**Already on Linux?**

```bash
# Ventoy (recommended — drop multiple ISOs on one stick, no re-flash later)
sudo pacman -S ventoy
sudo ventoy -i /dev/sdX                # wipes the USB
# then just copy archlinux-x86_64.iso to the USB's exfat partition

# Or dd (single-purpose, classic)
sudo dd if=archlinux-x86_64.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

Find the USB device with `lsblk` *before* running either — picking the wrong
`/dev/sdX` wipes a real drive.

#### Before you reboot — firmware prep

These steps apply to everyone, but Windows users hit them most often.
Reboot, mash the firmware key as the vendor logo appears (varies — common
ones: **F2**, **Del**, **F10**, **Esc**, **F1**; ThinkPad: **Enter** then **F1**;
Surface: hold **Vol Up** while powering on). Once inside:

1. **Disable Secure Boot.** Look under *Security* → *Secure Boot* → *Disabled*.
   The Arch ISO is unsigned, so Secure Boot will silently refuse to boot it
   and dump you back into Windows.
2. **Set USB as first boot device** (or just use the one-shot boot menu —
   F12 / F11 / F9 / Esc / F8 depending on vendor). On UEFI machines you
   want the entry that says `UEFI: <USB name>`, *not* the plain `<USB name>`
   one (that's legacy/CSM mode).
3. **(Replacing Windows entirely?)** Make sure you've copied anything you
   want to keep onto another drive. The default aei flow runs
   `sgdisk --zap-all` and **erases the whole disk**. If you want to keep
   Windows, see the dualboot section further down.
4. **(Dell/HP/Lenovo)** Switch SATA mode from *RAID/Intel RST* to **AHCI**
   if you're on an older laptop — Linux's NVMe driver expects AHCI.
   ⚠️ Doing this on a working Windows install breaks Windows' boot. Only
   change it if you're wiping Windows anyway, or follow Microsoft's
   "switch to AHCI without reinstall" guide first.

### 3. Boot the ISO

With Secure Boot disabled and USB selected (steps above), reboot. Pick
**"Arch Linux install medium"** from the boot menu. After ~20 seconds of
kernel + initrd output, you should land at a `root@archiso ~ #` prompt.

If your machine boots straight back into Windows: Secure Boot is still on,
or the firmware kept the internal drive ahead of USB. Re-enter firmware
setup, fix it, save & exit.

### 4. Set keymap and verify network

```bash
loadkeys us                  # or whatever your layout is — danish: dk
ping -c2 archlinux.org       # if this fails, set up wifi:

iwctl
[iwd]# device list
[iwd]# station wlan0 scan
[iwd]# station wlan0 get-networks
[iwd]# station wlan0 connect "Your-SSID"
[iwd]# exit
```

### 5. Run aei

```bash
pacman -Sy --noconfirm git
git clone https://github.com/danielradosa/aei
cd aei

# Edit arch-install.conf if anything needs tweaking (disk path, hostname, etc.)
nano arch-install.conf

./arch-install.sh --config arch-install.conf
```

The script will:

- detect your firmware (UEFI/BIOS) and GPU (auto-installs `nvidia-open-dkms` if NVIDIA)
- partition + format the disk you specified (LUKS2 root if `ENCRYPT="yes"`)
- pacstrap the base system + kernel
- pop into the chroot and configure locale, hostname, users, bootloader,
  greetd, all the desktop packages, services
- copy itself + all dotfiles + the post-install script into `/home/$USER/aei/`
- wire `~/.zprofile` to auto-run phase 3 on first login

### 6. Reboot

```bash
exit                          # leave the chroot if you're still in it
umount -R /mnt
cryptsetup close cryptroot    # only if ENCRYPT=yes
reboot
```

Pull the USB out as the machine restarts.

### 7. First boot

`greetd` shows tuigreet. Log in as your user. Hyprland comes up — and
`~/.zprofile` immediately fires `~/aei/post-install.sh` to:

- build `paru` from AUR
- install AUR packages (`wlogout`, `swayosd`, `cava`, `papirus-folders`, `ventoy-bin`)
- install `oh-my-zsh` + `zsh-autosuggestions` + `zsh-syntax-highlighting`
- symlink everything in `dotfiles/` into your `$HOME` (existing files backed
  up to `~/.aei-backup/<timestamp>/`)
- seed the `alchemia` pywal palette and regenerate every themed file
- hook up `pywalfox` so Firefox themes match
- headless `:Lazy! sync` so nvim is ready on first launch
- revoke the temporary `NOPASSWD` on `wheel`
- touch `~/.aei-done` so the autorun is a no-op next login

Logs live in `~/.aei-postinstall.log`.

---

## Dualbooting with Windows

If you want to keep Windows alongside Arch (same disk, both selectable from
the boot menu), do this **instead of** steps 5-6 above. The Windows side
needs a few minutes of prep first or you'll fight NTFS/BitLocker/Fast Startup
later.

### A. Prepare in Windows (before booting the Arch ISO)

1. **Disable Fast Startup.** Settings → System → Power & battery → Additional
   power settings → "Choose what the power buttons do" → "Change settings
   currently unavailable" → uncheck *Turn on fast startup*. With Fast Startup
   on, Windows leaves NTFS in a half-hibernated state that Linux refuses to
   touch — and your dualboot setup will look fine until the first time you
   try to mount the Windows partition from Arch.
2. **Disable BitLocker** *or* save the recovery key.
   Settings → Privacy & security → Device encryption → off.
   If you can't turn it off (Win Pro on TPM hardware), at least back up the
   recovery key — resizing the partition can trigger a recovery prompt.
3. **Shrink the Windows partition** to make room for Arch.
   `Win + X → Disk Management` → right-click `C:` → *Shrink Volume*.
   80 GB minimum for a comfortable Arch install, more if you want games.
   Click *Shrink* — leave the freed space *unallocated* (don't make a new
   partition from Windows; we'll do that from the ISO with Linux tooling).
4. **Disable Secure Boot** in your firmware (covered in step 2's "firmware
   prep" subsection above). Required for the Arch ISO to boot at all.

### B. Boot the Arch ISO

Steps 1-4 from the main guide above (download ISO, write to USB, boot, set
keymap, get networking up).

### C. Carve the Linux partition out of the unallocated space

Identify your disk:

```bash
lsblk -po NAME,SIZE,TYPE,FSTYPE,PARTLABEL
# Typical Windows 11 NVMe layout:
#   nvme0n1
#   ├─nvme0n1p1   100M  part  vfat        EFI    ← Windows ESP — DO NOT FORMAT
#   ├─nvme0n1p2    16M  part              MSR
#   ├─nvme0n1p3   180G  part  ntfs        Basic  ← Windows C:  ← shrunk
#   └─nvme0n1p4   650M  part  ntfs        Recovery
```

Open `cfdisk` and create one new partition in the free space:

```bash
cfdisk /dev/nvme0n1
# pick "Free space" → New → enter the size (or full remaining) →
# Type → "Linux filesystem" → Write → "yes" → Quit
```

After writing, `lsblk` should show a new partition like `nvme0n1p5`. That's
your `ROOT_PART`. The ESP from step C is your `ESP_PART` — same one Windows
uses; we don't reformat it.

### D. Run aei in manual-partition mode

```bash
pacman -Sy --noconfirm git
git clone https://github.com/danielradosa/aei && cd aei
nano arch-install.conf
```

Edit these lines in `arch-install.conf` (uncomment + set):

```
MANUAL_PARTITION="yes"
ROOT_PART="/dev/nvme0n1p5"     # the partition you just made
ESP_PART="/dev/nvme0n1p1"      # Windows' ESP — re-used as /boot/efi
# DISK="/dev/sda"              # ← comment this out; not used in manual mode
```

Then:

```bash
./arch-install.sh --config arch-install.conf
# or, equivalently, leave the conf alone and pass:
# MANUAL_PARTITION=yes ROOT_PART=/dev/nvme0n1p5 ESP_PART=/dev/nvme0n1p1 \
#   ./arch-install.sh --manual-partition
```

What aei does differently in this mode:

- **Skips** `sgdisk --zap-all` — your Windows partitions stay where they are.
- **Skips** `mkfs.fat` on the ESP — your Windows boot files survive.
- **Formats only** `ROOT_PART` (LUKS-wraps it first if `ENCRYPT="yes"`).
- **Mounts** Windows' ESP at `/boot/efi` — Arch's kernel, initramfs and
  systemd-boot loader land alongside `EFI/Microsoft/Boot/`.
- **Detects Windows automatically** in the bootloader step:
  - **systemd-boot**: writes `/boot/efi/loader/entries/windows.conf` pointing
    at `/EFI/Microsoft/Boot/bootmgfw.efi`.
  - **grub**: installs `os-prober` and `ntfs-3g`, sets
    `GRUB_DISABLE_OS_PROBER=false`, regenerates `grub.cfg` — Windows
    appears in the menu automatically.

After phase 2 finishes, reboot. The boot menu now lists both **Arch Linux**
(default) and **Windows**. Phase 3 runs on first Arch login as usual.

### E. Dualboot troubleshooting

| Symptom                                                | Fix                                                                                                       |
| ------------------------------------------------------ | --------------------------------------------------------------------------------------------------------- |
| Windows entry doesn't show in systemd-boot menu        | Verify `/boot/efi/EFI/Microsoft/Boot/bootmgfw.efi` exists. If not, your ESP is on a different partition than you set. Check with `mount \| grep efi` and `find /boot/efi -name bootmgfw.efi`. Re-create `/boot/efi/loader/entries/windows.conf` manually if needed. |
| Windows boots, Arch doesn't (or vice versa)            | Open firmware boot menu (F12 etc.) — check both `Windows Boot Manager` and `Linux Boot Manager`/`GRUB` are listed. If only one: `efibootmgr -v` from a live ISO and `efibootmgr --create ...` to add the missing entry. |
| Mounting Windows partition fails with "wrong fs type"  | Fast Startup is still on. Boot Windows, properly shut down with Shift held while clicking *Shut down* (forces a real shutdown), then disable Fast Startup. |
| BitLocker recovery prompt on first Windows boot post-install | Expected once. Enter the recovery key you saved in prep step A.2. Future boots are fine. |
| Clock is 8 hours off in Windows after using Arch       | Linux uses UTC for the hardware clock; Windows uses local. In Arch: `timedatectl set-local-rtc 1 --adjust-system-clock`. |
| Want to remove Arch later                              | Boot Windows → Disk Management → delete the Linux partition → extend C: into the free space. Then in firmware: remove the Linux EFI entry with `bcdedit` from an admin cmd, or boot the Windows install media → recovery → `bootrec /fixmbr` and `bootrec /rebuildbcd`. |

---

## Customizing

| Want to...                    | Edit                                          |
| ----------------------------- | --------------------------------------------- |
| change packages               | `packages/pacman.txt` and `packages/aur.txt`  |
| change Hyprland config        | `dotfiles/.config/hypr/hyprland.conf`         |
| change waybar / rofi / kitty  | `dotfiles/.config/{waybar,rofi,kitty}/`       |
| swap pywal scheme             | `dotfiles/.config/wal/colorschemes/dark/`     |
| add a new pywal-templated app | drop into `dotfiles/.config/wal/templates/`   |
| change the wallpaper          | replace `dotfiles/Pictures/wallpapers/*`      |
| pre-set passwords             | `arch-install.conf` (then `chmod 600`)        |

Re-running `~/aei/post-install.sh` after editing dotfiles re-links them.

---

## Troubleshooting

### Boot / install

| Symptom                                                | Fix                                                                                                      |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------- |
| `No internet` from preflight                           | `iwctl` (see step 4) or `dhcpcd eth0` for wired                                                          |
| `pacstrap` fails with mirror errors                    | `reflector --country YourCountry --save /etc/pacman.d/mirrorlist` then retry                             |
| `Picked DISK is not a valid block device`              | edit `arch-install.conf`, set `DISK=/dev/...` to the path from `lsblk -dpno NAME,SIZE,TYPE`              |
| LUKS passphrase prompt never appears at boot           | the `encrypt` hook is missing from mkinitcpio — boot the ISO, mount + chroot, fix `/etc/mkinitcpio.conf`, run `mkinitcpio -P` |
| `bootctl install` fails with "ESP not mounted"         | UEFI install but ESP not at `/boot/efi` — re-mount and re-run phase 2                                    |

### First boot

| Symptom                                                | Fix                                                                                                       |
| ------------------------------------------------------ | --------------------------------------------------------------------------------------------------------- |
| Black screen after reboot, NVIDIA card                 | press Ctrl+Alt+F2, log in, check `journalctl -b -u greetd` — usually `nvidia_drm.modeset=1` missing from kernel cmdline. Edit `/boot/efi/loader/entries/arch.conf` and add it. |
| greetd shows but Hyprland won't start (loops back)     | check `journalctl --user -b -t Hyprland` — most often `start-hyprland` not on PATH. Verify with `which start-hyprland` (should be `/usr/local/bin/start-hyprland`). If missing, copy from `~/aei/scripts/start-hyprland`. |
| tuigreet doesn't list a Hyprland session at all        | `/etc/greetd/config.toml` should have `--cmd start-hyprland`. Re-run `sudo aei/post-install.sh` won't fix this — edit the file directly and `sudo systemctl restart greetd`. |
| Wallpaper doesn't load                                 | `pgrep awww-daemon`. If empty: `awww-daemon &` then `awww img ~/Pictures/wallpapers/alchemy-bg.png`. The `awww` package provides `swww`. |
| Waybar shows but with no colors                        | `~/.cache/wal/waybar-colors.css` missing — run `wal --theme alchemia` to regenerate. The custom templates live in `~/.config/wal/templates/`. |
| Firefox doesn't theme                                  | install the `pywalfox` browser extension from addons.mozilla.org, then `pywalfox update`                  |

### Phase 3 (post-install)

| Symptom                                                 | Fix                                                                                                       |
| ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Phase 3 didn't auto-run on login                        | check `cat ~/.aei-done` (should NOT exist if it didn't run). Manually: `~/aei/post-install.sh`. The hook lives in `~/.zprofile`. |
| `paru: command not found` after phase 3                 | the build failed. Check `~/.aei-postinstall.log`. Most often: missing `base-devel` (it shouldn't — pacstrap installs it). Try manually: `cd /tmp && git clone https://aur.archlinux.org/paru && cd paru && makepkg -si`. |
| AUR package fails to build                              | log line says which one. Re-run `paru -S <pkg>` to see the real error. Failed packages are listed at the end of `post-install.sh`'s output and don't block the rest. |
| LazyVim sync errors on first run                        | non-fatal — open `nvim`, run `:Lazy sync`, then `:Mason` to fill in any missing LSP/formatter binaries. |
| Dotfiles got overwritten / I want my own back          | `~/.aei-backup/<timestamp>/` has your previous files. The deployer always backs up before symlinking.    |
| `~/.aei-done` exists but I want phase 3 to re-run       | `rm ~/.aei-done && ~/aei/post-install.sh`                                                                 |

### Day-to-day

| Symptom                                              | Fix                                                                                |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Hold-backspace deletes one char per second           | already handled — `repeat_delay = 220, repeat_rate = 50` in `hyprland.conf`. If you changed it, lower `repeat_delay` (50–250 ms) and raise `repeat_rate` (30–60). |
| nvim feels laggy on key sequences                    | `dotfiles/.config/nvim/lua/config/options.lua` sets `timeoutlen = 300, ttimeoutlen = 10` — drop them lower if you want even snappier (10/0). |
| `wal --theme alchemia` says theme not found          | the colorscheme JSON should be at `~/.config/wal/colorschemes/dark/alchemia.json` — check the symlink. |
| Bluetooth doesn't work                               | `sudo systemctl enable --now bluetooth && bluetoothctl` — `power on`, `scan on`, `pair <MAC>`. |
| Docker says permission denied                        | log out / back in (group membership added in phase 2 only takes effect on a new login session). |

---

## Repo layout

```
aei/
├── arch-install.sh        # phases 1 + 2 (ISO, partition, chroot, packages)
├── arch-install.conf      # baked-in non-interactive defaults
├── post-install.sh        # phase 3 (per-user; idempotent, fail-tolerant)
├── packages/
│   ├── pacman.txt         # one official-repo package per line
│   └── aur.txt            # one AUR package per line
├── scripts/
│   └── start-hyprland     # greetd launches this (env + dbus + Hyprland)
└── dotfiles/              # symlinked into $HOME by post-install
    ├── .zshrc
    ├── Pictures/wallpapers/
    └── .config/
        ├── hypr/{hyprland,hyprlock,hypridle}.conf
        ├── waybar/{config.jsonc,style.css}
        ├── kitty/kitty.conf
        ├── rofi/{config.rasi,alchemia.rasi}
        ├── mako/config
        ├── wlogout/{layout,style.css}
        ├── swayosd/style.css
        ├── cava/config
        ├── fastfetch/config.jsonc
        ├── starship.toml
        ├── nvim/                  # LazyVim + alchemia colorscheme
        └── wal/{colorschemes,templates}/
```

## Notes

- **NVIDIA**: defaults to `nvidia-open-dkms` (open kernel modules — Turing/Ampere/Ada+).
  If you have a Maxwell/Pascal card, swap that for `nvidia-dkms` in `packages/pacman.txt`.
- **awww vs swww**: this repo uses `awww` (it's in `[extra]` and `provides=swww`).
  All configs reference `awww` / `awww-daemon`. If you prefer plain `swww`, swap
  the package + the two `exec-once` lines in `hyprland.conf`.
- **greetd's `start-hyprland`**: lives at `/usr/local/bin/start-hyprland`.
  If you re-image without this script, tuigreet's `--cmd Hyprland` will technically
  work but you'll lose XDG/dbus env propagation (no portal, no clipboard, no Qt theme).
- **Re-running** `post-install.sh` is always safe. It checks each step's current
  state before acting, so partial-failure recovery is just `~/aei/post-install.sh`.
