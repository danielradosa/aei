-- Options are automatically loaded before lazy.nvim startup.
-- Default options come from: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua

local opt = vim.opt

-- ── Snappier keypress feel ──────────────────────────────────────────────────
-- The compositor (Hyprland's input { repeat_rate, repeat_delay }) drives how
-- fast a held key fires; these tighten *Vim's* internal waits so chord
-- detection (`gg`, `<leader>...`) doesn't add extra perceived latency.
opt.timeoutlen  = 300   -- ms to wait for a mapped sequence (default 1000)
opt.ttimeoutlen = 10    -- ms to wait for a terminal key code  (default 50)
opt.updatetime  = 200   -- ms before swap write / CursorHold   (default 4000)

-- ── Misc ergonomic defaults ─────────────────────────────────────────────────
opt.scrolloff      = 8       -- keep N lines visible above/below cursor
opt.sidescrolloff  = 8
opt.confirm        = true    -- ask to save instead of erroring on :q
