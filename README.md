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

**Ventoy** (recommended — drop multiple ISOs on one stick, no re-flash):

```bash
sudo pacman -S ventoy        # or get it from ventoy.net
sudo ventoy -i /dev/sdX      # ⚠️ wipes the USB
# then just copy archlinux-x86_64.iso to the USB's exfat partition
```

**dd** (single-purpose, classic):

```bash
sudo dd if=archlinux-x86_64.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

Find your USB device with `lsblk` *before* running either — picking the wrong
`/dev/sdX` wipes a real drive.

### 3. Boot the ISO

In your BIOS/UEFI, set USB as the first boot device (or use the boot-menu
hotkey: F12/F11/F10/Esc depending on vendor). Disable Secure Boot. Pick the
"Arch Linux install medium" entry.

You should land at a `root@archiso ~ #` prompt.

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
