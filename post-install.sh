#!/usr/bin/env bash
#
# post-install.sh — phase 3 of aei.
# ============================================================================
# Runs as the unprivileged user (NOT root) after first login. Wires up:
#
#   - paru (AUR helper) built from source
#   - AUR packages from packages/aur.txt (each installed independently)
#   - oh-my-zsh + plugins
#   - dotfiles from dotfiles/ (symlinked into $HOME)
#   - alchemia pywal palette + templates
#   - Firefox theming bridge (pywalfox)
#
# Idempotent: every step checks current state before acting. Safe to re-run
# any number of times — failed steps are reported, not fatal. When all
# critical work succeeds the marker ~/.aei-done is created so that the
# autorun hook in ~/.zprofile becomes a no-op on subsequent logins.
#
# ============================================================================

set -uo pipefail   # NB: no -e — partial failures must not abort the whole run.

# ── Logging ─────────────────────────────────────────────────────────────────
LOG="$HOME/.aei-postinstall.log"
GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'
CYAN='\033[1;36m';  BOLD='\033[1m';      RESET='\033[0m'
log()  { printf "${GREEN}[+]${RESET} %s\n" "$*" | tee -a "$LOG"; }
warn() { printf "${YELLOW}[!]${RESET} %s\n" "$*" | tee -a "$LOG"; }
err()  { printf "${RED}[x]${RESET} %s\n" "$*" | tee -a "$LOG" >&2; }
hr()   { printf "${CYAN}──────────────────────────────────────────────${RESET}\n" | tee -a "$LOG"; }
step() { hr; printf "${BOLD}== %s ==${RESET}\n" "$*" | tee -a "$LOG"; hr; }

[[ $EUID -eq 0 ]] && { err "Run as your user, not root."; exit 1; }

# Resolve repo dir relative to this script (so it works whether invoked from
# ~/aei/post-install.sh, ./post-install.sh, /tmp/aei/post-install.sh, etc.).
SCRIPT="$(readlink -f "$0")"
REPO="$(dirname "$SCRIPT")"
DOTFILES="$REPO/dotfiles"
[[ -d "$DOTFILES" ]] || { err "dotfiles/ not found at $DOTFILES"; exit 1; }

# Track failures so we can report a summary at the end and decide whether to
# touch the .aei-done marker.
FAILURES=()
fail() { FAILURES+=("$1"); err "$1 failed (non-fatal — continuing)"; }

# ── Source phase 1-2 env if present (gives us $USERNAME, $DO_NVIDIA, etc.) ──
[[ -f "$HOME/.aei.env" ]] && { set -a; . "$HOME/.aei.env"; set +a; }

step "aei post-install starting on $(date) [user=$(whoami)]"

# ── 1. paru ────────────────────────────────────────────────────────────────
install_paru() {
    step "Installing paru (AUR helper)"
    if command -v paru >/dev/null 2>&1; then
        log "paru already installed — skipping."
        return 0
    fi
    local tmp; tmp=$(mktemp -d)
    git clone https://aur.archlinux.org/paru.git "$tmp/paru" 2>&1 | tee -a "$LOG" \
        || { fail "paru git clone"; rm -rf "$tmp"; return 1; }
    (cd "$tmp/paru" && makepkg -si --noconfirm) 2>&1 | tee -a "$LOG" \
        || { fail "paru makepkg"; rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    log "paru installed."
}

# ── 2. AUR packages (each installed standalone — one failure ≠ all fail) ───
install_aur() {
    step "Installing AUR packages"
    command -v paru >/dev/null 2>&1 || { warn "no paru — skipping AUR."; return; }

    local list="$REPO/packages/aur.txt"
    [[ -r "$list" ]] || { warn "aur.txt missing — skipping."; return; }

    local pkg
    while IFS= read -r pkg; do
        [[ -z "$pkg" || "$pkg" =~ ^[[:space:]]*# ]] && continue
        if pacman -Q "$pkg" >/dev/null 2>&1; then
            log "AUR: $pkg already installed."
            continue
        fi
        log "AUR: building $pkg..."
        if paru -S --needed --noconfirm --skipreview "$pkg" 2>&1 | tee -a "$LOG"; then
            log "  ✓ $pkg installed"
        else
            fail "AUR pkg: $pkg"
        fi
    done < <(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "$list")
}

# ── 3. oh-my-zsh + plugins ─────────────────────────────────────────────────
install_omz() {
    step "Installing oh-my-zsh + plugins"
    if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
        # RUNZSH=no keeps the installer from chsh'ing & spawning a subshell.
        RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
            "" --unattended --keep-zshrc 2>&1 | tee -a "$LOG" \
            || fail "oh-my-zsh installer"
    else
        log "oh-my-zsh already installed."
    fi

    local custom="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
    install -d "$custom/plugins"

    if [[ ! -d "$custom/plugins/zsh-autosuggestions" ]]; then
        git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
            "$custom/plugins/zsh-autosuggestions" 2>&1 | tee -a "$LOG" \
            || fail "zsh-autosuggestions clone"
    fi
    if [[ ! -d "$custom/plugins/zsh-syntax-highlighting" ]]; then
        git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git \
            "$custom/plugins/zsh-syntax-highlighting" 2>&1 | tee -a "$LOG" \
            || fail "zsh-syntax-highlighting clone"
    fi
}

# ── 4. Dotfiles → $HOME (symlinked; backs up conflicts) ────────────────────
# We walk dotfiles/ instead of using stow so we can ship Pictures/ and any
# top-level dotfile with a single tree, and still get safe symlinks.
deploy_dotfiles() {
    step "Deploying dotfiles"

    local backup="$HOME/.aei-backup/$(date +%Y%m%d-%H%M%S)"
    install -d "$backup"

    # Walk every regular file under DOTFILES, mirror its relative path under $HOME.
    local rel src dst
    while IFS= read -r -d '' src; do
        rel="${src#"$DOTFILES"/}"
        dst="$HOME/$rel"
        install -d "$(dirname "$dst")"

        # If destination already points at the right file, skip.
        if [[ -L "$dst" ]] && [[ "$(readlink -f "$dst")" == "$src" ]]; then
            continue
        fi

        # If destination exists (regular file or different symlink), back it up.
        if [[ -e "$dst" || -L "$dst" ]]; then
            install -d "$(dirname "$backup/$rel")"
            mv "$dst" "$backup/$rel"
        fi

        ln -s "$src" "$dst"
    done < <(find "$DOTFILES" -type f -print0)

    if [[ -z "$(ls -A "$backup" 2>/dev/null)" ]]; then
        rmdir "$backup" 2>/dev/null
        log "Dotfiles linked. (No conflicts — no backup created.)"
    else
        log "Dotfiles linked. Existing files backed up to: $backup"
    fi
}

# ── 5. Pywal: alchemia palette ─────────────────────────────────────────────
seed_pywal() {
    step "Seeding pywal alchemia palette"

    install -d "$HOME/Pictures/wallpapers"

    # Wallpapers come in via dotfiles/ so they're already in place. Bail if not.
    if [[ ! -f "$HOME/Pictures/wallpapers/alchemy-bg.png" ]]; then
        warn "Wallpaper missing at ~/Pictures/wallpapers/alchemy-bg.png — pywal will fall back."
    fi

    # alchemia is a custom colorscheme, not an image. wal --theme reads it from
    # ~/.config/wal/colorschemes/dark/alchemia.json (linked from dotfiles).
    if command -v wal >/dev/null 2>&1; then
        # -n: don't set wallpaper (awww does that) | -s: skip term seq | -t: skip title
        # -e: skip reload | -q: quiet
        wal --theme alchemia -n -s -t -e -q 2>&1 | tee -a "$LOG" \
            || fail "wal --theme alchemia"
    else
        fail "pywal not installed"
    fi
}

# ── 6. Firefox theming via pywalfox ────────────────────────────────────────
setup_pywalfox() {
    step "Hooking up pywalfox (Firefox theming bridge)"
    if ! command -v pywalfox >/dev/null 2>&1; then
        warn "pywalfox not installed — install python-pywalfox to enable Firefox theming."
        return
    fi
    pywalfox install 2>&1 | tee -a "$LOG" || true
    pywalfox update  2>&1 | tee -a "$LOG" || true
}

# ── 7. LazyVim plugin sync (headless) ──────────────────────────────────────
sync_lazyvim() {
    step "Syncing LazyVim plugins (headless)"
    if [[ ! -f "$HOME/.config/nvim/init.lua" ]]; then
        # Fresh install: bootstrap LazyVim starter in addition to user dotfiles.
        log "No nvim init.lua — bootstrapping LazyVim starter."
        local tmp; tmp=$(mktemp -d)
        git clone --depth=1 https://github.com/LazyVim/starter "$tmp/starter" 2>&1 | tee -a "$LOG" \
            || { fail "LazyVim starter clone"; return; }
        rm -rf "$tmp/starter/.git"
        # Copy starter files but DO NOT clobber files that came from dotfiles
        # (extras.lua, colorscheme.lua, init.lua are owned by us via symlinks).
        cp -rn "$tmp/starter/." "$HOME/.config/nvim/" 2>&1 | tee -a "$LOG"
        rm -rf "$tmp"
    fi
    nvim --headless '+Lazy! sync' +qa 2>&1 | tee -a "$LOG" \
        || warn "LazyVim sync had errors — check :Lazy on next launch."
}

# ── 8. Lock down sudoers (revoke the temporary NOPASSWD) ───────────────────
finalize() {
    step "Locking down sudoers"
    if [[ -f /etc/sudoers.d/00-aei ]]; then
        sudo rm -f /etc/sudoers.d/00-aei \
            || warn "Could not remove /etc/sudoers.d/00-aei — remove manually."
    fi
}

# ── Run sequence ───────────────────────────────────────────────────────────
install_paru
install_aur
install_omz
deploy_dotfiles
seed_pywal
setup_pywalfox
sync_lazyvim
finalize

# ── Summary ────────────────────────────────────────────────────────────────
hr
if [[ ${#FAILURES[@]} -eq 0 ]]; then
    log "post-install complete. All steps succeeded."
    touch "$HOME/.aei-done"
    log ""
    log "  Reload Hyprland to pick up the new config:    hyprctl reload"
    log "  Or: log out and back in via tuigreet for a clean start."
else
    warn "post-install finished with ${#FAILURES[@]} failed step(s):"
    for f in "${FAILURES[@]}"; do warn "  - $f"; done
    warn ""
    warn "Re-run after investigating: $HOME/aei/post-install.sh"
    warn "Logs: $LOG"
    # NB: deliberately NOT touching .aei-done so the autorun retries on next login.
fi
hr
