export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME=""

plugins=(git sudo command-not-found z fzf docker docker-compose npm node python pip zsh-autosuggestions zsh-syntax-highlighting)

source $ZSH/oh-my-zsh.sh

# Pywal
[ -f "$HOME/.cache/wal/sequences" ] && cat "$HOME/.cache/wal/sequences"
[ -f "$HOME/.cache/wal/colors-tty.sh" ] && source "$HOME/.cache/wal/colors-tty.sh"

# Editor
export EDITOR=nvim
export VISUAL=nvim

# Aliases
alias v=nvim
alias vi=nvim
alias vim=nvim
alias ll='eza -lah --icons --git'
alias ls='eza --icons'
alias cat='bat --paging=never'
alias cc='clear'
alias home='cd && cc'
alias ez='nvim ~/.zshrc'
alias sez='source ~/.zshrc'
alias gs='git status'
eval "$(zoxide init zsh)"

export PATH="$HOME/.local/bin:$PATH"

# SSH agent
eval "$(ssh-agent -s)" > /dev/null 2>&1
ssh-add ~/.ssh/id_ed25519 2>/dev/null

# Starship prompt
eval "$(starship init zsh)"
