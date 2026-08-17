#!/bin/bash
# Fedora 44 Post-Install Setup Script
# Author: Kushagra Kumar
# Version: 5.2.0

set -euo pipefail

# ==============================================================================
# Configuration & Flags
# ==============================================================================
DRY_RUN=false
BACKUP_DIR="$HOME/.config/fedora-setup-backups/$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/tmp/fedora-setup-$(date +%Y%m%d_%H%M%S).log"
SCRIPT_VERSION="5.2.0"
PROFILE="full"
FORCE_RERUN=false
STATE_FILE="$HOME/.config/fedora-setup/state.txt"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run|-n)
            DRY_RUN=true
            shift
            ;;
        --profile=*)
            PROFILE="${1#*=}"
            shift
            ;;
        --profile)
            if [[ $# -lt 2 ]]; then
                echo "Error: Option --profile requires an argument." >&2
                exit 1
            fi
            PROFILE="$2"
            shift 2
            ;;
        --force|-f)
            FORCE_RERUN=true
            shift
            ;;
        --help|-h)
            echo "Fedora 44 Post-Install Setup Script v${SCRIPT_VERSION}"
            echo ""
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --dry-run, -n          Preview changes without executing"
            echo "  --profile=PROFILE      Choose setup profile:"
            echo "                           minimal     - DNF, DNS, fonts, shell, browser/codecs"
            echo "                           dev         - Complete dev stack, Docker, Antigravity, KVM"
            echo "                           gaming      - Multimedia, Steam, MangoHud, Flatpaks, GPU drivers"
            echo "                           workstation - Productive desktop, Steam, KVM, GPU drivers"
            echo "                           creator     - Gaming + COPR tools (Yazi, Scrcpy)"
            echo "                           full        - All steps (default)"
            echo "  --force, -f            Re-run completed steps"
            echo "  --help, -h             Show this help message"
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate profile
case "$PROFILE" in
    minimal|dev|gaming|workstation|creator|full) ;;
    *) echo "Unknown profile: $PROFILE (use minimal, dev, gaming, workstation, creator, or full)"; exit 1 ;;
esac

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Enable logging to file
exec > >(tee -a "$LOG_FILE") 2>&1

# Logging functions
log() { echo -e "${BLUE}[SETUP]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
info() { echo -e "\033[0;36m[INFO]${NC} $1"; }
dry() { echo -e "\033[0;35m[DRY-RUN]${NC} Would execute: $1"; }

# Progress tracking
COMPLETED_STEPS=0
FAILED_STEPS=0
SKIPPED_STEPS=0
TOTAL_STEPS=0
START_TIME=$(date +%s)

step_complete() {
    COMPLETED_STEPS=$((COMPLETED_STEPS + 1))
    echo -e "\n${GREEN}[${COMPLETED_STEPS}/${TOTAL_STEPS}]${NC} $1"
}

# ==============================================================================
# Enhanced Helper Functions
# ==============================================================================

# Execute command (or dry-run)
run() {
    if $DRY_RUN; then
        dry "$*"
        return 0
    else
        "$@"
    fi
}

# Execute sudo command (or dry-run)
run_sudo() {
    if $DRY_RUN; then
        dry "sudo $*"
        return 0
    else
        sudo "$@"
    fi
}

is_gaming_profile() {
    [[ "$PROFILE" == "gaming" || "$PROFILE" == "workstation" || "$PROFILE" == "creator" || "$PROFILE" == "full" ]]
}

is_dev_profile() {
    [[ "$PROFILE" == "dev" || "$PROFILE" == "full" ]]
}

# Download a release asset from GitHub.
# Usage: github_download <owner/repo> <asset_pattern> <output_path> [fallback_url]
# asset_pattern is a grep -E regex to match the asset filename.
github_download() {
    local repo="$1" pattern="$2" output="$3" fallback="${4:-}"
    local api_url="https://api.github.com/repos/$repo/releases/latest"
    local download_url=""
    local api_response

    api_response=$(curl -sfL --max-time 10 "$api_url" 2>/dev/null || true)
    if [[ -n "$api_response" ]]; then
        if command -v jq &>/dev/null; then
            download_url=$(echo "$api_response" | jq -r ".assets[] | select(.name | test(\"$pattern\")) | .browser_download_url" 2>/dev/null | head -1 || true)
        elif command -v python3 &>/dev/null; then
            download_url=$(python3 -c "
import sys, json, re
try:
    data = json.loads(sys.stdin.read())
    pat = re.compile(sys.argv[1])
    for a in data.get('assets', []):
        if pat.search(a.get('name', '')):
            print(a.get('browser_download_url', ''))
            break
except Exception:
    pass
" "$pattern" <<< "$api_response" 2>/dev/null || true)
        else
            download_url=$(echo "$api_response" | grep -oP '"browser_download_url":\s*"\K[^"]*' 2>/dev/null | grep -E "$pattern" 2>/dev/null | head -1 || true)
        fi
    fi

    [[ -z "$download_url" ]] && download_url="$fallback"

    if [[ -n "$download_url" ]]; then
        curl -fL --max-time 120 -o "$output" "$download_url" 2>/dev/null
        return $?
    fi
    return 1
}

# Backup a file before modifying
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        if $DRY_RUN; then
            dry "Backup: $file → $BACKUP_DIR/$(basename "$file").backup"
            return 0
        fi
        mkdir -p "$BACKUP_DIR"
        local backup_name=$(basename "$file").backup
        cp "$file" "$BACKUP_DIR/$backup_name"
        info "Backed up: $file → $BACKUP_DIR/$backup_name"
    fi
}

# Restore backups
restore_backups() {
    local latest_backup
    latest_backup=$(ls -td ~/.config/fedora-setup-backups/*/ 2>/dev/null | head -1 || true)
    if [[ -z "$latest_backup" ]]; then
        warn "No backups found"
        return 1
    fi
    latest_backup="${latest_backup%/}"

    log "Latest backup: $latest_backup"
    if ! confirm "Restore all files from this backup?" "N"; then
        return 0
    fi

    local originals=(
        "$HOME/.zshrc"
        "$HOME/.bashrc"
        "/etc/dnf/dnf.conf"
        "$HOME/.config/MangoHud/MangoHud.conf"
        "$HOME/.config/starship.toml"
    )

    for orig in "${originals[@]}"; do
        local name backup_path
        name="$(basename "$orig")"
        backup_path="$latest_backup/$name.backup"

        if [[ ! -f "$backup_path" ]]; then
            warn "No backup for $orig"
            continue
        fi

        if $DRY_RUN; then
            dry "cp $backup_path $orig"
        elif [[ "$orig" == /etc/* ]]; then
            run_sudo cp "$backup_path" "$orig"
            success "Restored: $orig"
        else
            cp "$backup_path" "$orig"
            success "Restored: $orig"
        fi
    done

    if ! $DRY_RUN; then
        rm -f "$STATE_FILE"
        warn "State reset due to restore - all steps will re-run"
    fi
}

# ==============================================================================
# State File Functions (Idempotency)
# ==============================================================================
init_state() {
    mkdir -p "$(dirname "$STATE_FILE")"
    [[ -f "$STATE_FILE" ]] || touch "$STATE_FILE"
}

is_step_completed() {
    local step="$1"
    [[ -f "$STATE_FILE" ]] && grep -qx "$step" "$STATE_FILE"
}

mark_step_completed() {
    local step="$1"
    if ! is_step_completed "$step"; then
        echo "$step" >> "$STATE_FILE"
    fi
}

# Confirmation prompt
confirm() {
    local prompt="$1" default="${2:-N}" yn
    if $DRY_RUN; then
        if [[ "$default" == "Y" ]]; then
            dry "Prompt: $prompt (auto-yes in dry-run)"
            return 0
        else
            dry "Prompt: $prompt (auto-no in dry-run)"
            return 1
        fi
    fi
    if [[ "$default" == "Y" ]]; then
        read -p "$prompt (Y/n): " -n 1 -r yn
    else
        read -p "$prompt (y/N): " -n 1 -r yn
    fi
    echo
    if [[ "$default" == "Y" ]]; then
        [[ -z "$yn" || "$yn" =~ ^[Yy]$ ]]
    else
        [[ "$yn" =~ ^[Yy]$ ]]
    fi
}

# Network check
check_network() {
    ping -c 1 -W 2 8.8.8.8 &>/dev/null || ping -c 1 -W 2 1.1.1.1 &>/dev/null
}

# Disk space check
check_disk_space() {
    local required_gb=${1:-20}
    local target_dir=${2:-$HOME}
    local available_gb
    available_gb=$(df -BG "$target_dir" 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/G//' || true)

    if [[ -z "$available_gb" ]]; then
        warn "Could not determine free disk space for $target_dir - skipping check"
        return 0
    fi

    if (( available_gb < required_gb )); then
        warn "Low disk space: ${available_gb}GB available (${required_gb}GB recommended)"
        if ! confirm "Continue anyway?" "N"; then
            error "Aborting due to low disk space"
            exit 1
        fi
    else
        info "Disk space OK: ${available_gb}GB available"
    fi
}

# Show installed versions
show_versions() {
    log "Checking installed versions..."
    local packages=("zsh" "brave-browser" "vesktop" "agy" "antigravity" "docker" "tlp" "steam" "ffmpeg")
    for pkg in "${packages[@]}"; do
        if rpm -q "$pkg" &>/dev/null; then
            echo "  ✅ $pkg: $(rpm -q --queryformat '%{VERSION}' "$pkg" 2>/dev/null)"
        elif command -v "$pkg" &>/dev/null; then
            echo "  ✅ $pkg: $("$pkg" --version 2>/dev/null | head -1 || echo "installed")"
        else
            echo "  ❌ $pkg: not installed"
        fi
    done
}

# Sudo check and keep-alive
SUDO_PID=""
if ! $DRY_RUN; then
    sudo -v || { error "Requires sudo"; exit 1; }
    while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done &
    SUDO_PID=$!
fi

# ==============================================================================
# DNF Configuration
# ==============================================================================
setup_dnf() {
    log "Configuring DNF..."

    backup_file "/etc/dnf/dnf.conf"

    if ! $DRY_RUN; then
        run_sudo sed -i '/^# BEGIN fedora-setup$/,/^# END fedora-setup$/d' /etc/dnf/dnf.conf

        run_sudo tee -a /etc/dnf/dnf.conf > /dev/null <<EOF
# BEGIN fedora-setup
max_parallel_downloads=10
# END fedora-setup
EOF
    else
        dry "Add max_parallel_downloads=10 block to dnf.conf (idempotent)"
    fi

    log "Enabling RPM Fusion & Flathub (atomic operation)..."
    local fedora_ver
    fedora_ver=$(rpm -E %fedora 2>/dev/null || echo "44")
    [[ -z "$fedora_ver" || "$fedora_ver" == "%fedora" ]] && fedora_ver="44"
    run_sudo dnf install -y --setopt=best=True \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora_ver}.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedora_ver}.noarch.rpm"
    run flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || warn "Flathub already configured or failed"

    run_sudo dnf update -y --refresh --setopt=best=True

    step_complete "DNF configured"
}

# ==============================================================================
# DNS Configuration
# ==============================================================================
setup_dns() {
    if $DRY_RUN; then
        dry "DNS configuration (interactive step skipped in dry-run)"
        step_complete "DNS (dry-run)"
        return 0
    fi

    echo ""
    log "DNS Configuration"
    echo "Custom DNS replaces your ISP's default DNS with fast, private resolvers."
    echo "Benefits: Faster domain lookups and bypasses ISP-level website blocking/tampering."
    echo "Note: May conflict with internal corporate VPNs or college login portals."
    echo ""
    if ! confirm "Would you like to configure custom DNS?" "Y"; then
        info "Keeping default DHCP/ISP DNS settings"
        step_complete "DNS (skipped)"
        return 0
    fi

    echo "Choose a DNS provider:"
    echo "  1. Cloudflare DNS (1.1.1.1, 1.0.0.1)"
    echo "  2. Google DNS (8.8.8.8, 8.8.4.4)"
    echo "  3. Skip (keep current DNS)"

    local dns_choice DNS_IPV4 DNS_IPV6 DNS_NAME
    read -p "Select [1/2/3] (default: 1): " -n 1 -r dns_choice
    echo ""

    case "$dns_choice" in
        2) DNS_IPV4="8.8.8.8 8.8.4.4"; DNS_IPV6="2001:4860:4860::8888 2001:4860:4860::8844"; DNS_NAME="Google" ;;
        3) info "Keeping current DNS settings"; step_complete "DNS (skipped)"; return 0 ;;
        *) DNS_IPV4="1.1.1.1 1.0.0.1"; DNS_IPV6="2606:4700:4700::1111 2606:4700:4700::1001"; DNS_NAME="Cloudflare" ;;
    esac

    log "Configuring $DNS_NAME DNS..."
    local conns
    conns=$(nmcli -t -f NAME connection show --active 2>/dev/null || true)
    while IFS= read -r conn; do
        [[ -z "$conn" ]] && continue
        if [[ "$conn" =~ ^(docker|lo|virbr|veth|br-) ]]; then
            info "Skipping virtual interface: $conn"
            continue
        fi
        log "Setting DNS for: $conn"
        nmcli connection modify "$conn" ipv4.ignore-auto-dns yes ipv4.dns "$DNS_IPV4" 2>/dev/null || warn "Failed to set IPv4 DNS for $conn"
        nmcli connection modify "$conn" ipv6.ignore-auto-dns yes ipv6.dns "$DNS_IPV6" 2>/dev/null || warn "Failed to set IPv6 DNS for $conn"
        nmcli connection down "$conn" 2>/dev/null || true
        sleep 1
        nmcli connection up "$conn" 2>/dev/null || warn "Failed to restart $conn"
    done <<< "$conns"
    step_complete "$DNS_NAME DNS configured"
}

# ==============================================================================
# Power Management (TLP)
# ==============================================================================
setup_power() {
    warn "⚠️  TLP vs GNOME Power Profiles"
    echo "TLP provides fine-grained power control but:"
    echo "  • Disables GNOME's built-in power profiles UI"
    echo "  • Some AMD laptops work better with power-profiles-daemon"
    echo "  • Fedora upstream now prefers power-profiles-daemon"

    if ! confirm "Use TLP instead of GNOME power profiles?" "N"; then
        info "Keeping GNOME power-profiles-daemon (no changes made)"
        step_complete "Power management (default)"
        return 0
    fi

    log "Installing TLP..."
    run_sudo dnf install -y tlp tlp-rdw
    run_sudo systemctl enable tlp.service
    run_sudo systemctl mask power-profiles-daemon.service

    run_sudo tee /etc/systemd/system/tlp-autostart.service > /dev/null <<'EOF'
[Unit]
Description=Force TLP apply after boot
After=multi-user.target
Wants=multi-user.target
[Service]
Type=oneshot
ExecStart=/usr/sbin/tlp start
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    run_sudo systemctl daemon-reload && run_sudo systemctl enable tlp-autostart.service
    run_sudo tlp start
    step_complete "TLP configured"
}

# ==============================================================================
# No-Sleep Settings (GDM & User)
# ==============================================================================
setup_nosleep() {
    log "Disabling auto-sleep..."

    if ! $DRY_RUN; then
        run_sudo mkdir -p /etc/dconf/profile /etc/dconf/db/gdm.d
        if [[ ! -f /etc/dconf/profile/gdm ]]; then
            run_sudo tee /etc/dconf/profile/gdm > /dev/null <<'EOF'
user-db:user
system-db:gdm
file-db:/usr/share/gdm/greeter-dconf-defaults
EOF
        fi
        run_sudo tee /etc/dconf/db/gdm.d/01-power > /dev/null <<'EOF'
[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-timeout=0
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-timeout=0
sleep-inactive-battery-type='nothing'
EOF
        run_sudo dconf update 2>/dev/null || true
    else
        dry "Create /etc/dconf/db/gdm.d/01-power and run dconf update"
    fi

    local keys=(
        "sleep-inactive-ac-timeout 0"
        "sleep-inactive-ac-type nothing"
        "sleep-inactive-battery-timeout 0"
        "sleep-inactive-battery-type nothing"
    )
    for entry in "${keys[@]}"; do
        local key=${entry%% *} val=${entry#* }
        run gsettings set org.gnome.settings-daemon.plugins.power "$key" "$val" 2>/dev/null || true
    done

    step_complete "No-sleep configured"
}

# ==============================================================================
# ZSH + Starship
# ==============================================================================
setup_shell() {
    log "Installing ZSH & Starship..."
    run_sudo dnf install -y --skip-unavailable zsh curl git fontconfig

    if ! command -v starship &>/dev/null && ! $DRY_RUN; then
        if ! run_sudo dnf install -y --skip-unavailable starship 2>/dev/null; then
            log "Installing Starship via official installer..."
            curl -sS https://starship.rs/install.sh | sh -s -- -y >/dev/null 2>&1 || true
        fi
    fi

    if ! $DRY_RUN; then
        mkdir -p "$HOME/.zsh/plugins" "$HOME/.config"

        [[ ! -d "$HOME/.zsh/plugins/zsh-autosuggestions" ]] && run git clone https://github.com/zsh-users/zsh-autosuggestions "$HOME/.zsh/plugins/zsh-autosuggestions" 2>/dev/null || true
        [[ ! -d "$HOME/.zsh/plugins/zsh-syntax-highlighting" ]] && run git clone https://github.com/zsh-users/zsh-syntax-highlighting "$HOME/.zsh/plugins/zsh-syntax-highlighting" 2>/dev/null || true

        backup_file "$HOME/.config/starship.toml"
        cat > "$HOME/.config/starship.toml" <<'STARSHIP_CONFIG'
"$schema" = 'https://starship.rs/config-schema.json'

format = """
╭─ $os\
$username\
$directory\
$git_branch\
$git_status\
$rust\
$python\
$nodejs\
$golang\
$c\
$docker_context\
$cmd_duration\
$time
╰─$character """

[os]
disabled = false
style = "bold blue"
format = "[$symbol]($style) "

[os.symbols]
Windows = ""
Ubuntu = "󰕈"
SUSE = ""
Raspbian = "󰐿"
Mint = "󰣭"
Macos = "󰀵"
Manjaro = ""
Linux = "󰌽"
Gentoo = "󰣨"
Fedora = "󰣛"
Alpine = ""
Amazon = ""
Android = ""
Arch = "󰣇"
Debian = "󰣚"
Redhat = "󱄛"

[username]
show_always = false
style_user = "bold blue"
style_root = "bold red"
format = '[$user]($style) in '

[directory]
style = "bold cyan"
format = "[$path]($style) "
truncation_length = 0
truncate_to_repo = false

[directory.substitutions]
"Documents" = "󰈙 "
"Downloads" = " "
"Music" = "󰝚 "
"Pictures" = " "
"Developer" = "󰲋 "

[git_branch]
symbol = " "
style = "bold purple"
format = "on [$symbol$branch]($style) "

[git_status]
style = "bold red"
format = '([\[$all_status$ahead_behind\]]($style) )'
conflicted = "󰞇 "
ahead = "⇡${count}"
behind = "⇣${count}"
diverged = "⇕⇡${ahead_count}⇣${behind_count}"
up_to_date = ""
untracked = "?${count}"
stashed = "󰆓 "
modified = "!${count}"
staged = "+${count}"
renamed = "»${count}"
deleted = "✘${count}"

[rust]
symbol = " "
style = "bold red"
format = "via [$symbol($version )]($style) "

[python]
symbol = " "
style = "bold yellow"
format = 'via [${symbol}${pyenv_prefix}(${version} )(\($virtualenv\) )]($style) '

[nodejs]
symbol = " "
style = "bold green"
format = "via [$symbol($version )]($style) "

[golang]
symbol = " "
style = "bold cyan"
format = "via [$symbol($version )]($style) "

[c]
symbol = " "
style = "bold blue"
format = "via [$symbol($version )]($style) "

[docker_context]
symbol = " "
style = "bold blue"
format = "via [$symbol$context]($style) "

[cmd_duration]
min_time = 2_000
show_milliseconds = false
style = "bold yellow"
format = "took [$duration]($style) "

[time]
disabled = false
time_format = "%R"
style = "dimmed white"
format = "at [$time]($style) "

[character]
disabled = false
success_symbol = "[❯](bold green)"
error_symbol = "[❯](bold red)"
vimcmd_symbol = "[❮](bold green)"
vimcmd_replace_one_symbol = "[❮](bold purple)"
vimcmd_replace_symbol = "[❮](bold purple)"
vimcmd_visual_symbol = "[❮](bold yellow)"
STARSHIP_CONFIG

        backup_file "$HOME/.zshrc"

        if is_dev_profile; then
            log "Configuring developer .zshrc..."
            cat > "$HOME/.zshrc" <<'ZSHRC_DEV'
# ===== Zsh History =====
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000

setopt APPEND_HISTORY
setopt SHARE_HISTORY
setopt INC_APPEND_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE
setopt HIST_REDUCE_BLANKS

# Ctrl + Left / Right navigation
bindkey '^[[;5D' backward-word
bindkey '^[[;5C' forward-word

# ===== Zsh Autosuggestions color =====
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=#8a8a8a"

# ===== Zsh plugins (manual) =====
[[ -f ~/.zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && source ~/.zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
[[ -f ~/.zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] && source ~/.zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# ===== Aliases =====
alias ls='eza --group-directories-first --classify --icons --git'
alias cat='bat --paging=never --style=plain'

# ===== Antigravity IDE (WSL Remote) =====
anti() {
  if [[ -z "$WSL_DISTRO_NAME" ]]; then
    echo "❌ anti: This command must be run inside WSL"
    return 1
  fi

  local WIN_USER
  WIN_USER=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r')

  local IDE_EXE="/mnt/c/Users/$WIN_USER/AppData/Local/Programs/Antigravity IDE/Antigravity IDE.exe"

  if [[ ! -f "$IDE_EXE" ]]; then
    echo "❌ Antigravity IDE not found at:"
    echo "   $IDE_EXE"
    return 1
  fi

  local LINUX_PATH
  LINUX_PATH="$(realpath "${1:-.}")"

  "$IDE_EXE" --remote "wsl+$WSL_DISTRO_NAME" "$LINUX_PATH" &>/dev/null &
  disown
}

# ===== Environment & PATH =====
export PATH="$HOME/.local/bin:$PATH"

# ===== NVM =====
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# ===== Starship (ALWAYS LAST) =====
eval "$(starship init zsh)"
ZSHRC_DEV
        else
            log "Configuring standard .zshrc..."
            cat > "$HOME/.zshrc" <<'ZSHRC_NORMAL'
# ===== Zsh History =====
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000

setopt APPEND_HISTORY
setopt SHARE_HISTORY
setopt INC_APPEND_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE
setopt HIST_REDUCE_BLANKS

# Ctrl + Left / Right navigation
bindkey '^[[;5D' backward-word
bindkey '^[[;5C' forward-word

# ===== Zsh Autosuggestions color =====
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=#8a8a8a"

# ===== Zsh plugins (manual) =====
[[ -f ~/.zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && source ~/.zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
[[ -f ~/.zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] && source ~/.zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# ===== Aliases =====
alias ls='eza --group-directories-first --classify --icons --git'
alias cat='bat --paging=never --style=plain'

# ===== Starship (ALWAYS LAST) =====
eval "$(starship init zsh)"
ZSHRC_NORMAL
        fi
    else
        dry "Install Starship, clone plugins, deploy starship.toml and .zshrc"
    fi

    confirm "Set ZSH as default shell?" "Y" && run chsh -s "$(command -v zsh)"

    step_complete "Shell configured"
}

# ==============================================================================
# Brave Browser + Multimedia
# ==============================================================================
setup_browser_multimedia() {
    log "Installing Brave & multimedia..."

    if ! rpm -q rpmfusion-free-release &>/dev/null; then
        warn "RPM Fusion may not be installed correctly - multimedia packages may fail"
    fi

    run_sudo dnf install -y dnf-plugins-core
    run_sudo dnf config-manager addrepo --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo --overwrite 2>/dev/null || true
    run_sudo dnf install -y brave-browser mozilla-openh264

    run_sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing
    run_sudo dnf group upgrade -y multimedia --setopt=install_weak_deps=False --exclude=PackageKit-gstreamer-plugin
    run_sudo dnf group upgrade -y sound-and-video
    step_complete "Browser & multimedia ready"
}

# ==============================================================================
# Pre-Driver Reboot Checkpoint
# ==============================================================================
setup_pre_driver_reboot() {
    log "Pre-driver reboot checkpoint"

    if $DRY_RUN; then
        dry "Check running kernel vs installed kernel, prompt reboot if mismatched"
        step_complete "Reboot checkpoint (dry-run)"
        return 0
    fi

    local running_kernel installed_kernel
    running_kernel=$(uname -r)
    installed_kernel=$(rpm -q --last kernel-core kernel 2>/dev/null | head -1 | awk '{print $1}' | sed -E 's/kernel-(core-)?//' || true)

    if [[ "$running_kernel" != "$installed_kernel" ]]; then
        warn "Kernel mismatch detected"
        info "  Running:   $running_kernel"
        info "  Installed: $installed_kernel"
        echo ""
        echo "All packages and software have been installed."
        echo "A reboot is needed before driver setup so that kernel modules"
        echo "build against the kernel you're actually going to use."
        echo ""
        echo "After rebooting, re-run this script with the same arguments."
        echo "It will skip everything already done and pick up at GPU drivers."
        echo ""
        if confirm "Reboot now?" "Y"; then
            mark_step_completed "setup_pre_driver_reboot"
            step_complete "Reboot checkpoint (rebooting)"
            run_sudo reboot
            exit 0
        else
            warn "Skipping reboot. Driver modules may build against a stale kernel."
            echo "If you run into driver issues after this, reboot and re-run the script."
        fi
    else
        info "Running kernel matches installed kernel — no reboot needed"
    fi

    step_complete "Reboot checkpoint"
}

# ==============================================================================
# Smart Driver Detection
# ==============================================================================
setup_drivers() {
    if [[ "$PROFILE" == "minimal" ]]; then
        if ! confirm "Configure GPU drivers?" "N"; then
            info "Skipping GPU driver setup for minimal profile"
            step_complete "Drivers (skipped)"
            return 0
        fi
    fi

    log "Detecting Hardware..."

    local CHASSIS GPU_NVIDIA GPU_AMD GPU_INTEL
    CHASSIS=$(hostnamectl chassis 2>/dev/null || echo "unknown")
    GPU_NVIDIA=$(lspci | grep -Ei 'VGA|3D|Display' | grep -i nvidia || true)
    GPU_AMD=$(lspci | grep -Ei 'VGA|3D|Display' | grep -i amd || true)
    GPU_INTEL=$(lspci | grep -Ei 'VGA|3D|Display' | grep -i intel || true)

    log "Detected Chassis: $CHASSIS"

    if [[ -n "$GPU_INTEL" ]]; then
        log "Intel GPU Detected: Installing intel-media-driver..."
        run_sudo dnf install -y intel-media-driver
    fi

    if [[ -n "$GPU_AMD" ]]; then
        log "AMD GPU Detected: Swapping for freeworld drivers..."
        run_sudo dnf swap -y mesa-va-drivers mesa-va-drivers-freeworld
        run_sudo dnf swap -y mesa-vdpau-drivers mesa-vdpau-drivers-freeworld
    fi

    if [[ -n "$GPU_NVIDIA" ]]; then
        log "NVIDIA GPU Detected."

        run_sudo dnf install -y kmodtool akmods mokutil openssl nvtop akmod-nvidia xorg-x11-drv-nvidia-cuda libva-nvidia-driver

        log "Building NVIDIA kernel modules (this may take a few minutes)..."
        run_sudo akmods --force

        if modinfo nvidia &>/dev/null; then
            success "NVIDIA module built successfully"
        else
            warn "NVIDIA module not yet available - will build during boot"
        fi

        if [[ "$CHASSIS" == "laptop" || "$CHASSIS" == "notebook" || "$CHASSIS" == "convertible" ]]; then
            log "Laptop detected. Checking for Optimus/Hybrid setup..."
            if [[ -n "$GPU_INTEL" || -n "$GPU_AMD" ]]; then
                log "Hybrid Graphics (Optimus) detected."
            else
                log "Dedicated Nvidia only (MUX Switch or Desktop replacement)."
            fi
        fi

        echo ""
        echo "================================================================================"
        echo "                      SECURE BOOT & NVIDIA DRIVER SIGNING                      "
        echo "================================================================================"
        echo "Secure Boot is an EFI firmware security feature required by modern systems."
        echo "Fedora's akmods automatically signs locally built kernel modules with a self-"
        echo "generated key, which must be imported into your EFI firmware (MOK)."
        echo ""
        echo "You DO NOT need to disable Secure Boot or switch to legacy BIOS mode."
        echo ""
        echo "Reference: https://rpmfusion.org/Howto/Secure%20Boot"
        echo "Documentation: /usr/share/doc/akmods/README.secureboot"
        echo ""
        echo "--------------------------------------------------------------------------------"
        echo "1. Securing your key:"
        echo "--------------------------------------------------------------------------------"
        echo "Because the Secure Boot key is stored locally in /etc/pki/akmods, consider"
        echo "encrypting your rootfs (LUKS) to protect the private signing key."
        echo ""
        echo "--------------------------------------------------------------------------------"
        echo "2. Manual Key Generation & MOK Enrollment Steps:"
        echo "--------------------------------------------------------------------------------"
        echo "If you have Secure Boot enabled and wish to sign your drivers:"
        echo ""
        echo "a) Install required tools:"
        echo "   sudo dnf install -y kmodtool akmods mokutil openssl"
        echo ""
        echo "b) Generate a default keypair:"
        echo "   sudo kmodgenca -a"
        echo ""
        echo "c) Import the public key into MOK:"
        echo "   sudo mokutil --import /etc/pki/akmods/certs/public_key.der"
        echo "   -> Enter a temporary password when prompted (you will need this on reboot)."
        echo ""
        echo "d) Reboot your system:"
        echo "   systemctl reboot"
        echo ""
        echo "e) On the blue 'MOK Management' screen after reboot:"
        echo "   - Select 'Enroll MOK'"
        echo "   - Select 'Continue' -> 'Yes'"
        echo "   - Enter the password you set above (⚠️ WARNING: Keyboard is mapped to QWERTY!)"
        echo "   - Select 'Reboot'"
        echo ""
        echo "--------------------------------------------------------------------------------"
        echo "3. BIOS / EFI Firmware Updates:"
        echo "--------------------------------------------------------------------------------"
        echo "When updating the BIOS/UEFI firmware, the enrolled MOK key may be cleared."
        echo "Re-enroll the key anytime with:"
        echo "   sudo mokutil --import /etc/pki/akmods/certs/public_key.der"
        echo "================================================================================"
        echo ""
    else
        log "No NVIDIA GPU found. Skipping proprietary drivers."
    fi

    step_complete "Drivers configured!!"
}

# ==============================================================================
# COPR Packages
# ==============================================================================
setup_copr() {
    log "Installing COPR packages..."
    local coprs=(
        "zeno/scrcpy:scrcpy"
        "lihaohong/yazi:yazi file ffmpeg 7zip jq poppler-utils fd-find ripgrep fzf zoxide resvg xclip wl-clipboard xsel ImageMagick"
    )
    for entry in "${coprs[@]}"; do
        local repo="${entry%%:*}"
        local pkgs="${entry#*:}"
        if run_sudo dnf copr enable -y "$repo"; then
            run_sudo dnf install -y --skip-unavailable $pkgs || warn "$pkgs install failed"
        else
            warn "Failed to enable COPR repo $repo"
        fi
    done
    step_complete "COPR packages installed"
}

# ==============================================================================
# System Fonts
# ==============================================================================
setup_fonts() {
    log "Installing fonts..."
    run_sudo dnf install -y --skip-unavailable unzip mscore-fonts mscore-fonts-all dejavu-sans-fonts dejavu-serif-fonts \
        dejavu-sans-mono-fonts liberation-sans-fonts liberation-serif-fonts liberation-mono-fonts \
        google-noto-sans-fonts google-noto-serif-fonts google-noto-mono-fonts google-carlito-fonts google-caladea-fonts \
        curl cabextract xorg-x11-font-utils fontconfig

    run curl -sLO https://downloads.sourceforge.net/project/mscorefonts2/rpms/msttcore-fonts-installer-2.6-1.noarch.rpm
    run_sudo rpm -ivh --nodigest --nofiledigest msttcore-fonts-installer-2.6-1.noarch.rpm 2>/dev/null || true
    run rm -f msttcore-fonts-installer-2.6-1.noarch.rpm

    log "Downloading FiraCode Nerd Font..."
    if ! $DRY_RUN; then
        mkdir -p ~/.local/share/fonts
        if github_download "ryanoasis/nerd-fonts" "FiraCode\\.zip" "/tmp/FiraCode.zip" \
            "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FiraCode.zip"; then
            unzip -oq /tmp/FiraCode.zip -d ~/.local/share/fonts/ && rm -f /tmp/FiraCode.zip
            success "FiraCode Nerd Font installed"
        else
            warn "Failed to download FiraCode Nerd Font"
            info "Manual download: https://github.com/ryanoasis/nerd-fonts/releases"
        fi
        fc-cache -fv
    else
        dry "Download and install FiraCode Nerd Font"
        dry "fc-cache -fv"
    fi

    step_complete "Fonts installed"
}

# ==============================================================================
# GNOME Tools
# ==============================================================================
setup_gnome() {
    log "Installing GNOME tools..."
    run_sudo dnf install -y gnome-tweaks
    run flatpak install -y flathub com.mattjakeman.ExtensionManager 2>/dev/null || true

    info "Recommended GNOME Extensions (install via Extension Manager):"
    info "  • Blur My Shell"
    info "  • Clipboard Indicator"
    info "  • Dash to Dock / Dash2Dock Animated"
    info "  • Coverflow Alt+Tab"
    info "  • GSConnect"
    info "  • Net Speed"
    info "  • Space Bar"
    info "  • User Themes"
    info "  Note: Some extensions (Compiz effects) may not work on GNOME 45+"

    step_complete "GNOME tools installed"
}

# ==============================================================================
# Essential Packages
# ==============================================================================
setup_packages() {
    log "Installing essential packages..."

    local pkgs_to_install=(
        gcc clang fastfetch make cmake perl wmctrl cargo maven bat eza \
        java-latest-openjdk java-latest-openjdk-devel nodejs python3 python3-pip wget htop unzip unrar \
        p7zip p7zip-plugins ntfs-3g gparted timeshift vlc \
        telegram-desktop vim neovim gh android-tools libva-utils gstreamer1-plugin-openh264
    )

    if is_gaming_profile; then
        pkgs_to_install+=(steam mangohud)
    fi

    run_sudo dnf install -y --skip-unavailable "${pkgs_to_install[@]}"

    run_sudo dnf config-manager setopt fedora-cisco-openh264.enabled=1

    if is_gaming_profile; then
        log "Unlocking Steam H264 codec..."
        if ! $DRY_RUN; then
            local unlock_pid
            if flatpak list 2>/dev/null | grep -q "com.valvesoftware.Steam"; then
                info "Flatpak Steam detected"
                xdg-open steam://unlockh264/ 2>/dev/null &
                unlock_pid=$!
            else
                steam steam://unlockh264/ 2>/dev/null &
                unlock_pid=$!
            fi
            sleep 2
            kill "$unlock_pid" 2>/dev/null || true
        else
            dry "Unlock Steam H264 codec"
        fi

        info "Steam Settings (configure manually):"
        info "  • Library → Enable 'Show Steam Deck compatibility info'"
        info "  • Downloads → Disable 'Shader Pre-Caching'"
        info "  • Interface → Client Beta Participation → Steam Beta Update"

        if command -v mangohud &>/dev/null || $DRY_RUN; then
            if ! $DRY_RUN; then
                mkdir -p "$HOME/.config/MangoHud"
                backup_file "$HOME/.config/MangoHud/MangoHud.conf"
                cat > "$HOME/.config/MangoHud/MangoHud.conf" <<'EOF'
gpu_stats
gpu_temp
gpu_core_clock
gpu_mem_clock
gpu_power
cpu_stats
cpu_temp
cpu_mhz
cpu_power
vram
ram
fps
frametime=1
frame_timing=1
hud_no_margin
table_columns=3
background_alpha=0.3
font_size=20
EOF
                success "MangoHud config created"
            else
                dry "Create ~/.config/MangoHud/MangoHud.conf"
            fi
        fi
    fi

    if ! $DRY_RUN; then
        local arch
        arch=$(uname -m)
        local fallback_url="https://github.com/Vencord/Vesktop/releases/download/v1.5.3/vesktop-1.5.3.${arch}.rpm"
        log "Downloading Vesktop RPM..."
        if github_download "Vencord/Vesktop" "vesktop.*\.${arch}\.rpm" "/tmp/vesktop.rpm" "$fallback_url"; then
            if run_sudo dnf install -y /tmp/vesktop.rpm 2>/dev/null; then
                success "Vesktop installed"
            else
                warn "Vesktop install failed"
            fi
            run rm -f /tmp/vesktop.rpm
        else
            warn "Failed to download Vesktop"
            info "Manual install: https://github.com/Vencord/Vesktop/releases"
        fi
    else
        dry "Download and install Vesktop RPM from GitHub Releases"
    fi

    step_complete "Essential packages installed"
}

# ==============================================================================
# Development Tools & Compilers
# ==============================================================================
setup_dev() {
    log "Installing dev tools & libraries..."

    local dev_pkgs=(
        meson ninja-build automake autoconf libtool pkg-config bear
        gdb valgrind strace ltrace clang-tools-extra
        bc bison flex gperf protobuf-compiler python3-protobuf libxml2 libxslt
        ImageMagick git-lfs gnupg lzop lz4 pngcrush rsync schedtool squashfs-tools zip
        python3-devel python3-virtualenv python3-wheel python3-setuptools
        openssl-devel zlib-devel elfutils-libelf-devel elfutils-devel gnutls-devel sdl12-compat-devel
        glibc-devel.i686 libstdc++-devel.i686 zlib-ng-compat-devel.i686 libX11-devel.i686 readline-devel.i686 ncurses-devel.i686
    )

    run_sudo dnf install -y --skip-unavailable "${dev_pkgs[@]}"

    if confirm "Install full Rust toolchain (rustup, clippy, rust-analyzer)?" "Y"; then
        run_sudo dnf install -y rust cargo rustup rustfmt clippy rust-analyzer 2>/dev/null || true
    fi

    if command -v ccache &>/dev/null || $DRY_RUN; then
        if ! $DRY_RUN; then
            ccache --set-config=max_size=50G 2>/dev/null || true
            ccache --set-config=compression=true 2>/dev/null || true
            mkdir -p "$HOME/.ccache"
            echo "cache_dir = $HOME/.ccache" > "$HOME/.ccache/ccache.conf"
            success "ccache configured (50GB limit, compressed)"
        else
            dry "Configure ccache: 50GB max size, compression enabled"
        fi
    fi

    if command -v npm &>/dev/null; then
        log "Enabling corepack (yarn/pnpm)..."
        run_sudo npm install -g corepack 2>/dev/null || true
        run_sudo corepack enable 2>/dev/null || true
    fi

    log "Installing Google Antigravity CLI..."
    if ! $DRY_RUN; then
        if ! command -v agy &>/dev/null; then
            curl -fsSL https://antigravity.google/cli/install.sh | bash 2>/dev/null || \
            warn "Antigravity CLI install failed - try manually: curl -fsSL https://antigravity.google/cli/install.sh | bash"
        fi
    else
        dry "Install Antigravity CLI (agy) via official installer"
    fi

    step_complete "Dev tools installed"
}

# ==============================================================================
# Antigravity
# ==============================================================================
setup_antigravity() {
    log "Installing Antigravity..."
    if ! $DRY_RUN; then
        run_sudo tee /etc/yum.repos.d/antigravity.repo > /dev/null <<'EOL'
[antigravity-rpm]
name=Antigravity RPM Repository
baseurl=https://us-central1-yum.pkg.dev/projects/antigravity-auto-updater-dev/antigravity-rpm
enabled=1
gpgcheck=0
EOL
        if run_sudo dnf makecache; then
            run_sudo dnf install -y antigravity || warn "Failed to install Antigravity"
        else
            warn "Failed to refresh Antigravity repo metadata"
        fi

        log "Creating Antigravity settings..."
        mkdir -p "$HOME/.config/Antigravity/User"
        cat > "$HOME/.config/Antigravity/User/settings.json" <<'SETTINGS'
{
    "editor.fontFamily": "FiraCode Nerd Font, monospace",
    "editor.fontWeight": "600",
    "editor.fontLigatures": true,
    "editor.fontSize": 14,
    "editor.lineHeight": 1.6,
    "terminal.integrated.fontFamily": "FiraCode Nerd Font",
    "terminal.integrated.fontWeight": "600",
    "terminal.integrated.lineHeight": 1.2,
    "files.autoSave": "afterDelay"
}
SETTINGS
        success "Antigravity settings created"
    else
        dry "Add Antigravity repo and create settings.json"
    fi
    step_complete "Antigravity configured"
}

# ==============================================================================
# Flatpaks
# ==============================================================================
setup_flatpaks() {
    log "Installing Flatpaks..."
    run flatpak install -y flathub org.localsend.localsend_app io.missioncenter.MissionCenter com.vysp3r.ProtonPlus 2>/dev/null || true

    info "ProtonPlus installed - Use for Proton GE:"
    info "  • Only use if a game has issues with default Proton"
    info "  • Install latest Proton GE version from ProtonPlus"
    info "  • Set per-game in Steam: Properties → Compatibility"

    step_complete "Flatpaks installed"
}

# ==============================================================================
# Docker Setup
# ==============================================================================
setup_docker() {
    log "Configuring Docker..."

    log "Installing Docker packages..."
    run_sudo dnf install -y docker docker-cli moby-engine containerd freerdp

    if ! rpm -q moby-engine &>/dev/null && ! rpm -q docker-ce &>/dev/null; then
        warn "Docker (moby-engine/docker-ce) not installed - skipping configuration"
        step_complete "Docker (not installed)"
        return 0
    fi

    log "Configuring NetworkManager to ignore docker0..."
    if [[ ! -f /etc/NetworkManager/conf.d/10-docker.conf ]]; then
        run_sudo tee /etc/NetworkManager/conf.d/10-docker.conf >/dev/null <<'EOF'
[keyfile]
unmanaged-devices=interface-name:docker0
EOF
        run_sudo systemctl restart NetworkManager 2>/dev/null || true
        info "NetworkManager configured to ignore docker0"
    else
        info "NetworkManager already configured for Docker"
    fi

    log "Configuring firewall for Docker..."
    if [[ -f /etc/firewalld/firewalld.conf ]]; then
        if ! grep -q "IgnoreInterfaces=docker0" /etc/firewalld/firewalld.conf; then
            if grep -q "^IgnoreInterfaces=" /etc/firewalld/firewalld.conf; then
                run_sudo sed -i 's/^IgnoreInterfaces=.*/IgnoreInterfaces=docker0/' /etc/firewalld/firewalld.conf
            else
                echo "IgnoreInterfaces=docker0" | run_sudo tee -a /etc/firewalld/firewalld.conf >/dev/null
            fi
            run_sudo systemctl restart firewalld 2>/dev/null || true
            info "Firewall configured to ignore docker0 interface"
        else
            info "Firewall already configured for Docker"
        fi
    fi

    run_sudo usermod -aG docker "${USER:-$(id -un)}"

    run_sudo systemctl enable containerd.service 2>/dev/null || true
    if sudo systemctl is-failed docker &>/dev/null; then
        run_sudo systemctl reset-failed docker 2>/dev/null || true
    fi
    run_sudo systemctl enable --now docker 2>/dev/null || true

    if sudo systemctl is-active --quiet docker; then
        success "Docker running"
        info "After reboot, verify with: docker run --rm hello-world"
    else
        warn "Docker failed to start - check: sudo systemctl status docker"
        info "Common fixes:"
        info "  • Reboot and try again"
        info "  • Check: sudo journalctl -u docker --no-pager -n 20"
    fi

    log "Installing Docker Compose CLI plugin..."
    if ! $DRY_RUN; then
        DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
        mkdir -p "$DOCKER_CONFIG/cli-plugins"
        if [[ ! -f "$DOCKER_CONFIG/cli-plugins/docker-compose" ]]; then
            if github_download "docker/compose" "docker-compose-linux-x86_64$" \
                "$DOCKER_CONFIG/cli-plugins/docker-compose" \
                "https://github.com/docker/compose/releases/download/v5.0.1/docker-compose-linux-x86_64"; then
                chmod +x "$DOCKER_CONFIG/cli-plugins/docker-compose"
                success "Docker Compose installed"
            else
                warn "Failed to download Docker Compose"
                info "Manual download: https://github.com/docker/compose/releases"
            fi
        fi
    else
        dry "Download and install Docker Compose CLI plugin"
    fi

    step_complete "Docker configured"
}

# ==============================================================================
# KVM/QEMU Virtualization Setup
# ==============================================================================
setup_kvm() {
    log "Setting up KVM/QEMU Virtualization..."

    if ! grep -E 'vmx|svm' /proc/cpuinfo &>/dev/null; then
        warn "CPU virtualization (VT-x/AMD-V) not detected or not enabled in BIOS"
        if ! confirm "Continue anyway?" "N"; then
            step_complete "KVM (skipped - no virtualization support)"
            return 0
        fi
    fi

    if confirm "Install KVM/QEMU virtualization packages?" "Y"; then
        log "Installing virtualization packages..."
        run_sudo dnf install -y @virtualization qemu-kvm libvirt virt-install virt-manager libvirt-devel virt-top guestfs-tools
    fi

    if confirm "Configure virtualization services (modern socket activation)?" "Y"; then
        log "Configuring virtualization services..."
        run_sudo systemctl disable --now libvirtd.service 2>/dev/null || true
        run_sudo systemctl enable --now virtqemud.socket
        success "Virtualization services configured"
    fi

    if confirm "Configure firewall for libvirt?" "Y"; then
        log "Configuring firewall..."
        run_sudo firewall-cmd --add-service=libvirt --permanent
        run_sudo firewall-cmd --reload
        success "Firewall configured for libvirt"
    fi

    if confirm "Install VirtIO drivers (required for Windows VMs)?" "Y"; then
        log "Installing VirtIO drivers..."
        run_sudo wget https://fedorapeople.org/groups/virt/virtio-win/virtio-win.repo \
            -O /etc/yum.repos.d/virtio-win.repo 2>/dev/null || warn "Failed to add virtio-win repo"
        run_sudo dnf install -y virtio-win || warn "VirtIO drivers installation failed"
    fi

    if confirm "Enable performance optimizations (tuned virtual-host profile)?" "Y"; then
        log "Enabling performance optimizations..."
        run_sudo systemctl enable --now tuned
        run_sudo tuned-adm profile virtual-host
        success "Performance tuning applied"
    fi

    if confirm "Add current user to libvirt group?" "Y"; then
        log "Configuring user permissions..."
        run_sudo usermod -aG libvirt "${USER:-$(id -un)}"

        if [[ -f ~/.bashrc ]] && ! grep -q "LIBVIRT_DEFAULT_URI" ~/.bashrc; then
            backup_file "$HOME/.bashrc"
            echo 'export LIBVIRT_DEFAULT_URI="qemu:///system"' >> ~/.bashrc
        fi
        if [[ -f ~/.zshrc ]] && ! grep -q "LIBVIRT_DEFAULT_URI" ~/.zshrc; then
            backup_file "$HOME/.zshrc"
            echo 'export LIBVIRT_DEFAULT_URI="qemu:///system"' >> ~/.zshrc
        fi
        success "User added to libvirt group"
    fi

    warn "⚠️  REBOOT REQUIRED for group membership changes"
    info "After reboot, run the following verification commands:"
    info "  1. sudo virt-host-validate qemu"
    info "  2. virsh uri"

    if confirm "Show post-reboot storage and network setup commands?" "Y"; then
        echo ""
        log "Post-reboot commands to run manually:"
        echo ""
        info "Storage permissions fix:"
        echo "  sudo setfacl -b /var/lib/libvirt/images"
        echo "  sudo chgrp libvirt /var/lib/libvirt/images"
        echo "  sudo chmod 775 /var/lib/libvirt/images"
        echo "  sudo chmod g+s /var/lib/libvirt/images"
        echo "  sudo setfacl -m u:\$(whoami):rwx /var/lib/libvirt/images"
        echo "  sudo setfacl -m d:u:\$(whoami):rwx /var/lib/libvirt/images"
        echo ""
        info "Storage pool setup:"
        echo "  virsh pool-destroy default 2>/dev/null || true"
        echo "  virsh pool-undefine default 2>/dev/null || true"
        echo "  virsh pool-define-as --name default --type dir --target /var/lib/libvirt/images"
        echo "  virsh pool-start default"
        echo "  virsh pool-autostart default"
        echo ""
        info "Network setup:"
        echo "  virsh net-start default"
        echo "  virsh net-autostart default"
        echo ""
        info "Verification:"
        echo "  virt-host-validate qemu | grep -E '(PASS|FAIL)'"
        echo "  virsh list --all"
        echo "  virsh net-list --all"
        echo "  virsh pool-info default"
        echo ""
    fi

    step_complete "KVM/QEMU Virtualization configured"
}

# ==============================================================================
# Summary
# ==============================================================================
show_summary() {
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    local mins=$((duration / 60)) secs=$((duration % 60))

    echo -e "\n${GREEN}=== INSTALLATION SUMMARY ===${NC}"
    echo "Time: ${mins}m ${secs}s | Steps: ${COMPLETED_STEPS} completed, ${FAILED_STEPS} failed, ${SKIPPED_STEPS} skipped (of ${TOTAL_STEPS})"

    echo "Service Status:"
    systemctl is-active --quiet tlp && echo "  ✅ TLP" || echo "  ❌ TLP"
    systemctl is-active --quiet docker && echo "  ✅ Docker" || echo "  ❌ Docker"
    command -v nvidia-smi &>/dev/null && echo "  ✅ NVIDIA drivers"
    [[ "${SHELL:-}" == "$(command -v zsh 2>/dev/null)" ]] && echo "  ✅ ZSH default" || echo "  ⚠️  ZSH: not default shell"

    if confirm "Verify hardware video acceleration?" "N"; then
        log "Checking hardware acceleration..."
        echo ""
        echo "H.264 Encoders:"
        command -v ffmpeg >/dev/null && ffmpeg -encoders 2>/dev/null | grep -i "264" | head -5 || echo "  ffmpeg not found"
        echo ""
        echo "VA-API Profiles:"
        command -v vainfo >/dev/null && vainfo 2>/dev/null | grep -i "VAProfileH264" | head -3 || echo "  vainfo not found"
        echo ""
    fi

    echo "Next Steps:"
    echo "1. Reboot your system if you haven't already (Docker group, libvirt group, kernel modules)"
    echo "2. Open a new terminal to start using ZSH + Starship"
    echo "3. Review the log file: $LOG_FILE"
    echo -e "${GREEN}System ready! 🚀${NC}"
}

# ==============================================================================
# Main
# ==============================================================================
main() {
    if $DRY_RUN; then
        echo -e "\033[0;35m========================================${NC}"
        echo -e "\033[0;35m   DRY-RUN MODE - No changes will be made${NC}"
        echo -e "\033[0;35m========================================${NC}"
        echo ""
    fi

    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}   Fedora 44 Post-Install Setup v${SCRIPT_VERSION}${NC}"
    echo -e "${GREEN}========================================${NC}"
    info "Started at $(date)"
    info "Log file: $LOG_FILE"

    if confirm "Show currently installed versions?" "N"; then
        show_versions
    fi

    if confirm "Restore from previous backup?" "N"; then
        restore_backups || true
        return 0
    fi

    if ! $DRY_RUN && ! check_network; then
        error "No internet connection. Exiting."
        exit 1
    fi

    if ! $DRY_RUN; then
        check_disk_space 20 "$HOME"
    fi

    local steps=(
        "setup_dnf:DNF Configuration"
        "setup_dns:DNS Configuration"
        "setup_power:Power Management"
        "setup_nosleep:No-Sleep Settings"
        "setup_fonts:System Fonts"
        "setup_shell:ZSH + Starship"
        "setup_browser_multimedia:Brave + Multimedia"
        "setup_copr:COPR Packages"
        "setup_gnome:GNOME Tools"
        "setup_packages:Essential Packages"
        "setup_dev:Development Tools"
        "setup_antigravity:Antigravity"
        "setup_flatpaks:Flatpak Apps"
        "setup_docker:Docker Setup"
        "setup_kvm:KVM/QEMU Virtualization"
        "setup_pre_driver_reboot:Pre-Driver Reboot"
        "setup_drivers:GPU Drivers"
    )

    local -A PROFILE_STEPS
    PROFILE_STEPS[minimal]="setup_dnf setup_dns setup_fonts setup_shell setup_browser_multimedia setup_pre_driver_reboot setup_drivers"
    PROFILE_STEPS[dev]="setup_dnf setup_dns setup_power setup_nosleep setup_fonts setup_shell setup_browser_multimedia setup_gnome setup_packages setup_dev setup_antigravity setup_docker setup_kvm setup_pre_driver_reboot setup_drivers"
    PROFILE_STEPS[gaming]="setup_dnf setup_dns setup_power setup_fonts setup_shell setup_browser_multimedia setup_gnome setup_packages setup_flatpaks setup_pre_driver_reboot setup_drivers"
    PROFILE_STEPS[workstation]="setup_dnf setup_dns setup_power setup_fonts setup_shell setup_browser_multimedia setup_gnome setup_packages setup_flatpaks setup_kvm setup_pre_driver_reboot setup_drivers"
    PROFILE_STEPS[creator]="setup_dnf setup_dns setup_power setup_fonts setup_shell setup_browser_multimedia setup_copr setup_gnome setup_packages setup_flatpaks setup_kvm setup_pre_driver_reboot setup_drivers"
    PROFILE_STEPS[full]=""

    info "Profile: $PROFILE"
    [[ -n "${PROFILE_STEPS[$PROFILE]}" ]] && info "Running steps: ${PROFILE_STEPS[$PROFILE]}"

    init_state

    local filtered_steps=()
    for step in "${steps[@]}"; do
        IFS=':' read -r func _ <<< "$step"
        if [[ -z "${PROFILE_STEPS[$PROFILE]}" ]] || [[ " ${PROFILE_STEPS[$PROFILE]} " =~ " $func " ]]; then
            filtered_steps+=("$step")
        fi
    done
    TOTAL_STEPS=${#filtered_steps[@]}

    for step in "${filtered_steps[@]}"; do
        IFS=':' read -r func name <<< "$step"

        if is_step_completed "$func" && ! $FORCE_RERUN; then
            info "Already completed: $name (use --force to re-run)"
            COMPLETED_STEPS=$((COMPLETED_STEPS + 1))
            continue
        fi

        echo ""
        echo -e "${BLUE}Step: $name${NC}"
        if confirm "Run this step?" "Y"; then
            if $func; then
                if ! $DRY_RUN; then
                    mark_step_completed "$func"
                fi
            else
                warn "$name had issues"
                FAILED_STEPS=$((FAILED_STEPS + 1))
            fi
        else
            warn "Skipped: $name"
            SKIPPED_STEPS=$((SKIPPED_STEPS + 1))
        fi
    done

    show_summary

    info "Full log saved to: $LOG_FILE"
    if [[ -d "$BACKUP_DIR" ]]; then
        info "Config backups saved to: $BACKUP_DIR"
    fi
}

cleanup() {
    [[ -n "$SUDO_PID" ]] && kill "$SUDO_PID" 2>/dev/null || true
}
trap 'echo -e "\n${RED}Interrupted${NC}"; cleanup; exit 1' INT TERM
trap cleanup EXIT
main "$@"