#!/bin/bash
# Fedora 44 Post-Install Setup Script
# Author: Kushagra Kumar
# Version: 5.0.3

set -euo pipefail

# ==============================================================================
# Configuration & Flags
# ==============================================================================
DRY_RUN=false
BACKUP_DIR="$HOME/.config/fedora-setup-backups/$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/tmp/fedora-setup-$(date +%Y%m%d_%H%M%S).log"
SCRIPT_VERSION="5.1.0"
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
            echo "                           minimal     - DNF, fonts, shell only"
            echo "                           dev         - Minimal + dev tools, Docker, Antigravity"
            echo "                           gaming      - Minimal + drivers, packages, Flatpaks"
            echo "                           workstation - Dev + DNS, KVM/QEMU"
            echo "                           creator     - Gaming + Multimedia, COPR tools"
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

# Download a release asset from GitHub.
# Usage: github_download <owner/repo> <asset_pattern> <output_path> [fallback_url]
# asset_pattern is a grep -E regex to match the asset filename.
# Returns 0 on success, 1 on failure.
github_download() {
    local repo="$1" pattern="$2" output="$3" fallback="${4:-}"
    local api_url="https://api.github.com/repos/$repo/releases/latest"
    local download_url=""
    local api_response

    api_response=$(curl -sfL --max-time 10 "$api_url" 2>/dev/null)
    if [[ -n "$api_response" ]]; then
        if command -v jq &>/dev/null; then
            download_url=$(echo "$api_response" | jq -r ".assets[] | select(.name | test(\"$pattern\")) | .browser_download_url" 2>/dev/null | head -1)
        else
            download_url=$(echo "$api_response" | grep -oP '"browser_download_url":\s*"\K[^"]*' | grep -E "$pattern" | head -1)
        fi
    fi

    [[ -z "$download_url" ]] && download_url="$fallback"

    if [[ -n "$download_url" ]]; then
        curl -fL --max-time 120 -o "$output" "$download_url" 2>/dev/null
        return $?
    fi
    return 1
}

# Ensure a line is set in ~/.zshrc: replace any line matching an ERE pattern,
# or append if no line matches. Verifies the end state via grep instead of
# trusting sed's exit code, which returns 0 whether or not anything matched.
set_zshrc_line() {
    local pattern="$1" desired="$2"
    grep -qxF "$desired" ~/.zshrc 2>/dev/null && return 0
    if grep -qE "$pattern" ~/.zshrc 2>/dev/null; then
        PAT="$pattern" REPL="$desired" awk '
            BEGIN { pat = ENVIRON["PAT"]; repl = ENVIRON["REPL"] }
            $0 ~ pat { print repl; next }
            { print }
        ' ~/.zshrc > ~/.zshrc.tmp && mv ~/.zshrc.tmp ~/.zshrc
    fi
    grep -qxF "$desired" ~/.zshrc 2>/dev/null || echo "$desired" >> ~/.zshrc
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
    local latest_backup=$(ls -td ~/.config/fedora-setup-backups/*/ 2>/dev/null | head -1)
    if [[ -z "$latest_backup" ]]; then
        warn "No backups found"
        return 1
    fi
    latest_backup="${latest_backup%/}"
    
    log "Latest backup: $latest_backup"
    if confirm "Restore all files from this backup?" "N"; then
        local prev_dotglob prev_nullglob
        prev_dotglob=$(shopt -p dotglob || true)
        prev_nullglob=$(shopt -p nullglob || true)
        shopt -s dotglob nullglob

        for backup_file in "$latest_backup"/*; do
            local filename=$(basename "$backup_file" .backup)
            local original_paths=(
                "$HOME/.zshrc"
                "$HOME/.bashrc"
                "/etc/dnf/dnf.conf"
                "$HOME/.config/MangoHud/MangoHud.conf"
            )
            for orig in "${original_paths[@]}"; do
                if [[ "$(basename "$orig")" == "$filename" ]]; then
                    if $DRY_RUN; then
                        dry "cp $backup_file $orig"
                    else
                        if [[ "$orig" =~ ^/etc/ ]]; then
                            run_sudo cp "$backup_file" "$orig"
                        else
                            cp "$backup_file" "$orig"
                        fi
                        success "Restored: $orig"
                    fi
                    break
                fi
            done
        done

        eval "$prev_dotglob"
        eval "$prev_nullglob"

        # Reset state file after restore to prevent stale state
        if ! $DRY_RUN; then
            rm -f "$STATE_FILE"
            warn "State reset due to restore - all steps will re-run"
        fi
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
if ! $DRY_RUN; then
    sudo -v || { error "Requires sudo"; exit 1; }
    while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done &
fi


# ==============================================================================
# DNF Configuration
# ==============================================================================
setup_dnf() {
    log "Configuring DNF..."
    
    # Backup config before modifying
    backup_file "/etc/dnf/dnf.conf"
    
    # Use idempotent block markers - remove old block if exists, then add fresh
    if ! $DRY_RUN; then
        run_sudo sed -i '/^# BEGIN fedora-setup$/,/^# END fedora-setup$/d' /etc/dnf/dnf.conf
        
        # DNF optimizations:
        # - fastestmirror: Auto-select fastest mirror
        # - max_parallel_downloads: Download 10 packages simultaneously
        # - keepcache: Keep downloaded packages for reinstalls
        # - best: Prefer newest package versions (version pinning)
        # - install_weak_deps: Set to False for minimal installs (optional)
        local dnf_opts="fastestmirror=True\nmax_parallel_downloads=10\nkeepcache=True\nbest=True"
        confirm "Enable defaultyes (auto-confirm)?" "N" && dnf_opts+="\ndefaultyes=True"
        
        run_sudo tee -a /etc/dnf/dnf.conf > /dev/null <<EOF
# BEGIN fedora-setup
$(echo -e "$dnf_opts")
# END fedora-setup
EOF
    else
        dry "Add fedora-setup block to dnf.conf (idempotent)"
    fi
    
    # Atomic operation: Install RPM Fusion repos together
    log "Enabling RPM Fusion & Flathub (atomic operation)..."
    local fedora_ver
    fedora_ver=$(rpm -E %fedora 2>/dev/null || echo "44")
    [[ -z "$fedora_ver" || "$fedora_ver" == "%fedora" ]] && fedora_ver="44"
    run_sudo dnf install -y --setopt=best=True \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora_ver}.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedora_ver}.noarch.rpm"
    run flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || warn "Flathub already configured or failed"
    
    # System update with version pinning
    run_sudo dnf update -y --refresh --setopt=best=True
    

    
    step_complete "DNF configured"
}

# ==============================================================================
# DNS Configuration
# ==============================================================================
setup_dns() {
    # Dry-run safety: DNS changes are interactive and can't be simulated
    if $DRY_RUN; then
        dry "DNS configuration (interactive step skipped in dry-run)"
        step_complete "DNS (dry-run)"
        return 0
    fi
    
    warn "⚠️  DNS Configuration Warning"
    echo "This will override auto DNS for ALL active connections."
    echo "Risks:"
    echo "  • May break corporate/campus networks"
    echo "  • May break VPN split DNS"
    echo "  • May break DNS-over-TLS/DNSSEC setups"
    echo "DNS Options:"
    echo "  1. Google DNS (8.8.8.8, 8.8.4.4)"
    echo "  2. Cloudflare DNS (1.1.1.1, 1.0.0.1)"
    echo "  3. Skip (keep current DNS)"
    
    local dns_choice DNS_IPV4 DNS_IPV6 DNS_NAME
    read -p "Choose DNS provider [1/2/3] (default: 3): " -n 1 dns_choice
    
    case "$dns_choice" in
        1) DNS_IPV4="8.8.8.8 8.8.4.4"; DNS_IPV6="2001:4860:4860::8888 2001:4860:4860::8844"; DNS_NAME="Google" ;;
        2) DNS_IPV4="1.1.1.1 1.0.0.1"; DNS_IPV6="2606:4700:4700::1111 2606:4700:4700::1001"; DNS_NAME="Cloudflare" ;;
        *) info "Keeping current DNS settings"; step_complete "DNS (skipped)"; return 0 ;;
    esac
    
    log "Configuring $DNS_NAME DNS..."
    local conns
    conns=$(nmcli -t -f NAME connection show --active 2>/dev/null || true)
    while IFS= read -r conn; do
        [[ -z "$conn" ]] && continue
        # Skip virtual/bridge interfaces (docker, loopback, libvirt, veth, bridge)
        if [[ "$conn" =~ ^(docker|lo|virbr|veth|br-) ]]; then
            info "Skipping virtual interface: $conn"
            continue
        fi
        log "Setting DNS for: $conn"
        nmcli connection modify "$conn" ipv4.ignore-auto-dns yes ipv4.dns "$DNS_IPV4" 2>/dev/null || warn "Failed to set IPv4 DNS for $conn"
        nmcli connection modify "$conn" ipv6.ignore-auto-dns yes ipv6.dns "$DNS_IPV6" 2>/dev/null || warn "Failed to set IPv6 DNS for $conn"
        nmcli connection down "$conn" 2>/dev/null; sleep 1; nmcli connection up "$conn" 2>/dev/null || warn "Failed to restart $conn"
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
    run_sudo mkdir -p /var/lib/gdm/.config/dconf
    run_sudo chown -R gdm:gdm /var/lib/gdm/.config && run_sudo chmod 0700 /var/lib/gdm/.config

    local keys=(
        "sleep-inactive-ac-timeout 0"
        "sleep-inactive-ac-type nothing"
        "sleep-inactive-battery-timeout 0"
        "sleep-inactive-battery-type nothing"
    )
    for entry in "${keys[@]}"; do
        local key=${entry%% *} val=${entry#* }
        run_sudo -u gdm dbus-run-session gsettings set org.gnome.settings-daemon.plugins.power "$key" "$val" 2>/dev/null || true
        run gsettings set org.gnome.settings-daemon.plugins.power "$key" "$val" 2>/dev/null || true
    done

    step_complete "No-sleep configured"
}

# ==============================================================================
# ZSH + Oh My Zsh + Powerlevel10k
# ==============================================================================
setup_shell() {
    log "Installing ZSH..."
    run_sudo dnf install -y zsh curl git fontconfig
    
    if ! $DRY_RUN; then
        [[ ! -d "$HOME/.oh-my-zsh" ]] && sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        
        run git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k" 2>/dev/null || true
        run git clone https://github.com/zsh-users/zsh-autosuggestions "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions" 2>/dev/null || true
        run git clone https://github.com/zsh-users/zsh-syntax-highlighting "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting" 2>/dev/null || true
    else
        dry "Install Oh My ZSH, Powerlevel10k, plugins"
    fi
    
    # Backup .zshrc using backup system
    backup_file "$HOME/.zshrc"
    
    if ! $DRY_RUN; then
        set_zshrc_line 'ZSH_THEME=' 'ZSH_THEME="powerlevel10k/powerlevel10k"'
        set_zshrc_line '^plugins=' 'plugins=(git zsh-autosuggestions zsh-syntax-highlighting)'
        
        cat >> ~/.zshrc <<'EOF'

# --- Custom Configs ---
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=#8a8a8a"

# bat alias
command -v bat &>/dev/null && alias cat='bat --paging=never --style=plain'

# eza alias
command -v eza &>/dev/null && alias ls='eza --group-directories-first --classify --icons --git'

EOF
    else
        dry "Configure .zshrc with theme and plugins"
    fi
    
    confirm "Set ZSH as default shell?" "Y" && run chsh -s "$(command -v zsh)"
    

    step_complete "Shell configured"
}

# ==============================================================================
# Brave Browser + Multimedia
# ==============================================================================
setup_browser_multimedia() {
    log "Installing Brave & multimedia..."
    
    # Validate RPM Fusion is installed (required for multimedia)
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

    # Check if the running kernel matches the installed kernel
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
    log "Detecting Hardware..."
    
    local CHASSIS GPU_NVIDIA GPU_AMD GPU_INTEL SB_STATE
    CHASSIS=$(hostnamectl chassis 2>/dev/null || echo "unknown")
    # More specific GPU detection to avoid false positives
    GPU_NVIDIA=$(lspci | grep -Ei 'VGA|3D|Display' | grep -i nvidia || true)
    GPU_AMD=$(lspci | grep -Ei 'VGA|3D|Display' | grep -i amd || true)
    GPU_INTEL=$(lspci | grep -Ei 'VGA|3D|Display' | grep -i intel || true)
    
    log "Detected Chassis: $CHASSIS"
    
    # 4a. Intel Drivers
    if [[ -n "$GPU_INTEL" ]]; then
        log "Intel GPU Detected: Installing intel-media-driver..."
        run_sudo dnf install -y intel-media-driver
    fi
    
    # 4b. AMD Drivers
    if [[ -n "$GPU_AMD" ]]; then
        log "AMD GPU Detected: Swapping for freeworld drivers..."
        run_sudo dnf swap -y mesa-va-drivers mesa-va-drivers-freeworld
        run_sudo dnf swap -y mesa-vdpau-drivers mesa-vdpau-drivers-freeworld
    fi
    
    # 4c. NVIDIA Drivers
    if [[ -n "$GPU_NVIDIA" ]]; then
        log "NVIDIA GPU Detected."
        
        # Common Nvidia Packages
        run_sudo dnf install -y kmodtool akmods mokutil openssl nvtop akmod-nvidia xorg-x11-drv-nvidia-cuda libva-nvidia-driver
        
        # Force build and verify modules before MOK enrollment
        log "Building NVIDIA kernel modules (this may take a few minutes)..."
        run_sudo akmods --force
        
        if modinfo nvidia &>/dev/null; then
            success "NVIDIA module built successfully"
        else
            warn "NVIDIA module not yet available - may require reboot after MOK enrollment"
        fi
        
        if [[ "$CHASSIS" == "laptop" || "$CHASSIS" == "notebook" || "$CHASSIS" == "convertible" ]]; then
            log "Laptop detected. Checking for Optimus/Hybrid setup..."
            if [[ -n "$GPU_INTEL" || -n "$GPU_AMD" ]]; then
                 log "Hybrid Graphics (Optimus) detected."
            else
                 log "Dedicated Nvidia only (MUX Switch or Desktop replacement)."
            fi
        fi
        
        log "Generating Secure Boot keys..."
        run_sudo kmodgenca -a
        
        warn "⚠️  SECURE BOOT ENROLLMENT REQUIRED ⚠️"
        echo "NVIDIA drivers require Secure Boot enrollment."
        echo ""
        echo "PREREQUISITE: Secure Boot must be ENABLED in your BIOS/UEFI."
        echo "If not enabled, stop this script using ctrl+c and do this BEFORE proceeding:"
        echo "1. Enter BIOS/UEFI"
        echo "2. Find Secure Boot option"
        echo "3. Enable it, save, and reboot to Linux"
        echo ""
        
        # Check current Secure Boot state
        SB_STATE=$(run_sudo mokutil --sb-state 2>/dev/null | grep -i "secureboot" || echo "unknown")
        
        if echo "$SB_STATE" | grep -qi "enabled"; then
            info "Secure Boot is currently ENABLED."
            if confirm "Do you want to enroll the NVIDIA driver key now?" "N"; then
                warn "IMPORTANT: Remember the password you set! You'll need it during next boot!"
                run_sudo mokutil --import /etc/pki/akmods/certs/public_key.der
                echo ""
                echo "✅ Key enrolled. Next steps after reboot:"
                echo "1. You'll see a BLUE 'MOK Manager' screen"
                echo "2. Select 'Enroll MOK' → 'Continue' → 'Yes'"
                echo "3. Enter the password you just set"
                echo "4. Select 'Reboot'"
                echo ""
                warn "The system will NOT load NVIDIA drivers until MOK enrollment is complete!"
            fi
        else
            warn "Secure Boot appears to be DISABLED or in an unknown state."
            echo "Check with: sudo mokutil --sb-state"
            echo "Enable Secure Boot in BIOS first, then re-run this step or enroll manually."
            echo "Manual enrollment: sudo mokutil --import /etc/pki/akmods/certs/public_key.der"
        fi
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
        "alternateved/eza:eza"
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
# Cloudflare Warp
# ==============================================================================
setup_warp() {
    log "Installing Cloudflare Warp..."
    run_sudo dnf install -y sassc glib2-devel libxml2 glibc-devel
    run_sudo dnf config-manager addrepo --from-repofile=https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo --overwrite 2>/dev/null || true
    run_sudo dnf install -y cloudflare-warp
    
    # Enable and start warp-svc before registration
    run_sudo systemctl enable --now warp-svc 2>/dev/null || true
    
    # Only register if not already registered
    if ! $DRY_RUN; then
        if ! warp-cli account 2>/dev/null | grep -q "Account type"; then
            check_network && warp-cli registration new 2>/dev/null || warn "Run 'warp-cli registration new' manually"
        else
            info "Warp already registered"
        fi
    else
        dry "Register warp-cli account if needed"
    fi
    step_complete "Warp installed"
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
    run_sudo dnf install -y --skip-unavailable gcc clang fastfetch make cmake perl wmctrl cargo maven bat \
        java-latest-openjdk java-latest-openjdk-devel nodejs python3 python3-pip wget htop unzip unrar \
        p7zip p7zip-plugins ntfs-3g gparted timeshift vlc steam mangohud \
        telegram-desktop vim neovim gh android-tools libva-utils gstreamer1-plugin-openh264

    run_sudo dnf config-manager setopt fedora-cisco-openh264.enabled=1
    
    # Steam H264 unlock (fixes some games)
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
    
    # MangoHud config
    if command -v mangohud &>/dev/null; then
        if ! $DRY_RUN; then
            mkdir -p ~/.config/MangoHud
            backup_file "$HOME/.config/MangoHud/MangoHud.conf"
            cat > ~/.config/MangoHud/MangoHud.conf <<'MANGOHUD'
legacy_layout=false
position=top-left
font_size=32
fps
frametime
frametime_color_change
gpu_stats
gpu_temp
cpu_stats
cpu_temp
ram
vram
MANGOHUD
            info "MangoHud configured"
        else
            dry "Create MangoHud.conf"
        fi
    fi

    # Vesktop (Linux-first Discord client without telemetry)
    log "Installing Vesktop..."
    if ! $DRY_RUN; then
        if command -v vesktop &>/dev/null || rpm -q vesktop &>/dev/null; then
            info "Vesktop already installed"
        else
            local arch
            arch="$(uname -m)"
            local fallback_url=""
            local latest_tag
            latest_tag=$(curl -sIL "https://github.com/Vencord/Vesktop/releases/latest" 2>/dev/null | grep -i "^location:" | sed -E 's/.*tag\/(v[0-9.]+).*/\1/' | tr -d '\r\n' || true)
            if [[ -n "$latest_tag" ]]; then
                local ver="${latest_tag#v}"
                fallback_url="https://github.com/Vencord/Vesktop/releases/download/${latest_tag}/vesktop-${ver}.${arch}.rpm"
            fi

            if github_download "Vencord/Vesktop" "vesktop.*\\.${arch}\\.rpm" "/tmp/vesktop.rpm" "$fallback_url"; then
                if run_sudo dnf install -y /tmp/vesktop.rpm 2>/dev/null; then
                    success "Vesktop installed"
                else
                    warn "Vesktop RPM install failed"
                fi
                rm -f /tmp/vesktop.rpm
            else
                warn "Failed to download Vesktop RPM — install manually from https://github.com/Vencord/Vesktop/releases"
            fi
        fi
    else
        dry "Download and install Vesktop RPM from GitHub Releases"
    fi
    
    step_complete "Packages installed"
}

# ==============================================================================
# Development Tools
# ==============================================================================
setup_dev() {
    log "Installing dev tools..."
    run_sudo dnf install -y bc bison ccache curl flex git git-lfs gnupg gperf ImageMagick protobuf-compiler \
        python3-protobuf libxml2 libxslt lzop lz4 pngcrush rsync schedtool squashfs-tools zip \
        openssl-devel zlib-devel elfutils-libelf-devel elfutils-devel gnutls-devel sdl12-compat-devel \
        glibc-devel.i686 libstdc++-devel.i686 zlib-ng-compat-devel.i686 libX11-devel.i686 readline-devel.i686 ncurses-devel.i686 \
        meson ninja-build automake autoconf libtool pkg-config cmake-gui cmake-fedora gdb valgrind strace ltrace clang-tools-extra bear \
        python3-devel python3-virtualenv python3-wheel python3-setuptools
    
    # Configure ccache
    if command -v ccache &>/dev/null; then
        if ! $DRY_RUN; then
            ccache --set-config=max_size=50G && ccache --set-config=compression=true
            mkdir -p ~/.ccache
            grep -qx "cache_dir = $HOME/.ccache" ~/.ccache/ccache.conf 2>/dev/null || \
                echo "cache_dir = $HOME/.ccache" >> ~/.ccache/ccache.conf
            info "ccache configured: 50G max, compression enabled"
        else
            dry "Configure ccache: 50G max, compression enabled"
        fi
    fi
    
    confirm "Install Rust toolchain?" "N" && run_sudo dnf install -y rust cargo rustup rustfmt clippy rust-analyzer
    
    # Corepack (yarn/pnpm management)
    if command -v npm >/dev/null; then
        run_sudo npm install -g corepack 2>/dev/null || true
        run_sudo corepack enable 2>/dev/null || true
        info "Corepack enabled"
    fi
    
    # Antigravity CLI (replaces discontinued Gemini CLI)
    # Not an npm package - Google ships it as a standalone binary via their own installer
    if ! $DRY_RUN; then
        if command -v agy &>/dev/null; then
            info "Antigravity CLI (agy) already installed"
        elif curl -fsSL https://antigravity.google/cli/install.sh | bash 2>/dev/null; then
            success "Antigravity CLI (agy) installed"
        else
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
    warn "Antigravity's Fedora/RHEL repo ships with gpgcheck=0 (Google's own install docs, not just this script)"
    info "Their APT instructions publish a signing key; their DNF/YUM instructions currently don't - you're trusting HTTPS+Google's infra here, not GPG package signing"
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
    else
        dry "Add Antigravity repo and install antigravity"
    fi
    
    # Install all extensions
    if ! $DRY_RUN && command -v antigravity >/dev/null; then
        log "Installing Antigravity extensions..."
        antigravity --install-extension bradlc.vscode-tailwindcss --install-extension catppuccin.catppuccin-vsc --install-extension christian-kohler.npm-intellisense --install-extension dbaeumer.vscode-eslint --install-extension devsense.composer-php-vscode --install-extension devsense.intelli-php-vscode --install-extension devsense.phptools-vscode --install-extension devsense.profiler-php-vscode --install-extension dsznajder.es7-react-js-snippets --install-extension eamodio.gitlens --install-extension esbenp.prettier-vscode --install-extension formulahendry.code-runner --install-extension golang.go --install-extension hbenl.vscode-mocha-test-adapter --install-extension hbenl.vscode-test-explorer --install-extension llvm-vs-code-extensions.vscode-clangd --install-extension meta.pyrefly --install-extension ms-azuretools.vscode-containers --install-extension ms-azuretools.vscode-docker --install-extension ms-pyright.pyright --install-extension ms-python.debugpy --install-extension ms-python.python --install-extension ms-python.vscode-python-envs --install-extension ms-vscode.cmake-tools --install-extension ms-vscode.cpptools-themes --install-extension ms-vscode.live-server --install-extension ms-vscode.test-adapter-converter --install-extension ms-vscode.vscode-typescript-next --install-extension redhat.java --install-extension shopify.ruby-lsp --install-extension vscjava.vscode-gradle --install-extension vscjava.vscode-java-debug --install-extension vscjava.vscode-java-dependency --install-extension vscjava.vscode-java-pack --install-extension vscjava.vscode-java-test --install-extension vscjava.vscode-maven --install-extension vscode-icons-team.vscode-icons 2>/dev/null || warn "Some extensions failed"
        
        # Create Antigravity settings file
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
    elif $DRY_RUN; then
        dry "Install Antigravity extensions and create settings.json"
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
    
    # Install Docker packages (Fedora's moby-engine stack - NOT Docker CE)
    log "Installing Docker packages..."
    run_sudo dnf install -y docker docker-cli moby-engine containerd freerdp
    
    # Check if docker is installed first
    if ! rpm -q moby-engine &>/dev/null && ! rpm -q docker-ce &>/dev/null; then
        warn "Docker (moby-engine/docker-ce) not installed - skipping configuration"
        step_complete "Docker (not installed)"
        return 0
    fi
    
    # Tell NetworkManager to ignore docker0 (prevents it from being assigned to FedoraWorkstation zone)
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
    
    # Fix firewall issue with Docker (tell firewalld to ignore docker0)
    log "Configuring firewall for Docker..."
    if [[ -f /etc/firewalld/firewalld.conf ]]; then
        if ! grep -q "IgnoreInterfaces=docker0" /etc/firewalld/firewalld.conf; then
            # Check if IgnoreInterfaces line exists and update it, otherwise add it
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
    
    run_sudo usermod -aG docker $USER

    # Enable and start docker + containerd
    run_sudo systemctl enable containerd.service 2>/dev/null || true
    if sudo systemctl is-failed docker &>/dev/null; then
        run_sudo systemctl reset-failed docker 2>/dev/null || true
    fi
    run_sudo systemctl enable --now docker 2>/dev/null || true
    
    if sudo systemctl is-active --quiet docker; then
        success "Docker running"
        # Note: docker test requires logout/login for group membership
        info "After reboot, verify with: docker run --rm hello-world"
    else
        warn "Docker failed to start - check: sudo systemctl status docker"
        info "Common fixes:"
        info "  • Reboot and try again"
        info "  • Check: sudo journalctl -u docker --no-pager -n 20"
    fi
    
    # Docker Compose CLI plugin
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
    
    # Check if virtualization is supported
    if ! grep -E 'vmx|svm' /proc/cpuinfo &>/dev/null; then
        warn "CPU virtualization (VT-x/AMD-V) not detected or not enabled in BIOS"
        if ! confirm "Continue anyway?" "N"; then
            step_complete "KVM (skipped - no virtualization support)"
            return 0
        fi
    fi
    
    # Step 1: Install virtualization packages
    if confirm "Install KVM/QEMU virtualization packages?" "Y"; then
        log "Installing virtualization packages..."
        run_sudo dnf install -y @virtualization qemu-kvm libvirt virt-install virt-manager libvirt-devel virt-top guestfs-tools
    fi
    
    # Step 2: Configure services
    if confirm "Configure virtualization services (modern socket activation)?" "Y"; then
        log "Configuring virtualization services..."
        run_sudo systemctl disable --now libvirtd.service 2>/dev/null || true
        run_sudo systemctl enable --now virtqemud.socket
        success "Virtualization services configured"
    fi
    
    # Step 3: Configure firewall
    if confirm "Configure firewall for libvirt?" "Y"; then
        log "Configuring firewall..."
        run_sudo firewall-cmd --add-service=libvirt --permanent
        run_sudo firewall-cmd --reload
        success "Firewall configured for libvirt"
    fi
    
    # Step 4: Install VirtIO drivers for Windows VM support
    if confirm "Install VirtIO drivers (required for Windows VMs)?" "Y"; then
        log "Installing VirtIO drivers..."
        run_sudo wget https://fedorapeople.org/groups/virt/virtio-win/virtio-win.repo \
            -O /etc/yum.repos.d/virtio-win.repo 2>/dev/null || warn "Failed to add virtio-win repo"
        run_sudo dnf install -y virtio-win || warn "VirtIO drivers installation failed"
    fi
    
    # Step 5: Performance optimizations
    if confirm "Enable performance optimizations (tuned virtual-host profile)?" "Y"; then
        log "Enabling performance optimizations..."
        run_sudo systemctl enable --now tuned
        run_sudo tuned-adm profile virtual-host
        success "Performance tuning applied"
    fi
    
    # Step 6: Fix user permissions
    if confirm "Add current user to libvirt group?" "Y"; then
        log "Configuring user permissions..."
        run_sudo usermod -aG libvirt $USER
        
        # Add LIBVIRT_DEFAULT_URI to shell configs
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
    
    # Post-reboot configuration reminder
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
    command -v warp-cli &>/dev/null && { warp-cli account 2>/dev/null | grep -q "Account" && echo "  ✅ Warp registered" || echo "  ⚠️  Warp: not registered"; }
    [[ "$SHELL" == "$(which zsh)" ]] && echo "  ✅ ZSH default" || echo "  ⚠️  ZSH: not default shell"
    
    # Hardware acceleration verification
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
    echo "1. Reboot if you haven't already (Docker group, libvirt group, MOK enrollment)"
    echo "2. p10k configure (Powerlevel10k theme)"
    echo "3. warp-cli connect"
    echo "4. docker run hello-world"
    echo -e "${GREEN}System ready! 🚀${NC}"
}



# ==============================================================================
# Main
# ==============================================================================
main() {
    # Show mode indicator
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
    
    # Pre-flight menu
    if confirm "Show currently installed versions?" "N"; then
        show_versions
    fi
    
    if confirm "Restore from previous backup?" "N"; then
        restore_backups
        return 0
    fi
    
    if ! $DRY_RUN && ! check_network; then
        error "No internet connection. Exiting."
        exit 1
    fi
    
    # Check disk space before starting
    if ! $DRY_RUN; then
        check_disk_space 20 "$HOME"
    fi
    
    local steps=(
        "setup_dnf:DNF Configuration"
        "setup_dns:DNS Configuration"
        "setup_power:Power Management"
        "setup_nosleep:No-Sleep Settings"
        "setup_fonts:System Fonts"
        "setup_shell:ZSH + Powerlevel10k"
        "setup_browser_multimedia:Brave + Multimedia"
        "setup_copr:COPR Packages"
        "setup_warp:Cloudflare Warp"
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
    
    # Define profile step filters
    local -A PROFILE_STEPS
    PROFILE_STEPS[minimal]="setup_dnf setup_fonts setup_shell"
    PROFILE_STEPS[dev]="setup_dnf setup_fonts setup_shell setup_dev setup_docker setup_antigravity setup_kvm"
    PROFILE_STEPS[gaming]="setup_dnf setup_fonts setup_shell setup_browser_multimedia setup_packages setup_flatpaks setup_pre_driver_reboot setup_drivers"
    PROFILE_STEPS[workstation]="setup_dnf setup_dns setup_fonts setup_shell setup_dev setup_docker setup_antigravity setup_kvm"
    PROFILE_STEPS[creator]="setup_dnf setup_fonts setup_shell setup_browser_multimedia setup_copr setup_packages setup_flatpaks setup_pre_driver_reboot setup_drivers"
    PROFILE_STEPS[full]=""  # Empty means all steps
    
    info "Profile: $PROFILE"
    [[ -n "${PROFILE_STEPS[$PROFILE]}" ]] && info "Running steps: ${PROFILE_STEPS[$PROFILE]}"
    
    # Initialize state file
    init_state
    
    # Filter steps and calculate TOTAL_STEPS dynamically based on profile
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

        
        # Check if step was already completed (idempotency)
        if is_step_completed "$func" && ! $FORCE_RERUN; then
            info "Already completed: $name (use --force to re-run)"
            COMPLETED_STEPS=$((COMPLETED_STEPS + 1))
            continue
        fi
        
        echo ""
        echo -e "${BLUE}Step: $name${NC}"
        if confirm "Run this step?" "Y"; then
            if $func; then
                success "$name completed"
                # Only update state in non-dry-run mode
                # Counter is incremented in step_complete
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
    
    # Final info
    info "Full log saved to: $LOG_FILE"
    if [[ -d "$BACKUP_DIR" ]]; then
        info "Config backups saved to: $BACKUP_DIR"
    fi
}

trap 'echo -e "\n${RED}Interrupted${NC}"; exit 1' INT
main "$@"
