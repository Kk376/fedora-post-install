# Fedora 44 Post-Install Setup Script

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

An interactive post-installation script for Fedora 44 Workstation (GNOME).

Built from years of actual Fedora usage, covering the things I find myself setting up on every fresh install: driver detection, multimedia codecs, dev tools, gaming, shell customization, Docker, and virtualization.

---

## Features

- **Interactive**: every step asks before running; nothing happens behind your back
- **Hardware-aware**: detects Intel / AMD / NVIDIA GPUs, hybrid Optimus setups, and CPU virtualization support
- **Secure Boot-aware NVIDIA setup**: builds kernel modules, generates keys, and walks you through MOK enrollment
- **Idempotent**: state file tracks what's done; you can interrupt and pick up where you left off, or `--force` to re-run
- **Profile-based**: six profiles so you only install what you actually need
- **Dry-run mode**: preview everything without touching the system
- **Backup and restore**: backs up config files before modifying them

---

## What's New in v5.2.0

- **Starship Prompt:** Replaced Oh My Zsh and Powerlevel10k with Starship and standalone ZSH plugins (`zsh-autosuggestions`, `zsh-syntax-highlighting`), deploying a custom `~/.config/starship.toml` and clean `.zshrc`.
- **DNS Brief & Prompts:** Added interactive DNS selection (`setup_dns`) with an informational brief across all profiles (Cloudflare default, Google, or skip).
- **Safe GDM No-Sleep:** Implemented login screen power management via `/etc/dconf/db/gdm.d/01-power` and `dconf update` to eliminate D-Bus session and SELinux permission errors.
- **Gaming & MangoHud Profile Filtering:** Restricted Steam and MangoHud installation and configuration (H.264 unlock, `MangoHud.conf`) to gaming-oriented profiles (`gaming`, `workstation`, `creator`, `full`).
- **Driver Setup Uniformity:** Standardized all profiles to run the pre-driver reboot checkpoint and GPU driver setup at the end of their execution sequence.
- **COPR & Warp Cleanup:** Removed obsolete `eza` COPR repo (available natively in Fedora) and removed Cloudflare Warp.
- **Secure Boot & MOK Disclaimer:** Added detailed documentation and MOK enrollment guidance for NVIDIA kernel module signing.

See [CHANGELOG.md](CHANGELOG.md) for the full history.

---

## Usage

```bash
# Full profile, interactive
./setup.sh

# Preview without changes
./setup.sh --dry-run

# Pick a profile
./setup.sh --profile=minimal
./setup.sh --profile=dev
./setup.sh --profile=gaming
./setup.sh --profile=workstation
./setup.sh --profile=creator

# Re-run already-completed steps
./setup.sh --force
```

### Profiles

| Profile       | What it installs                                                                                             |
| ------------- | ------------------------------------------------------------------------------------------------------------ |
| `minimal`     | DNF config, DNS, fonts, shell (Starship), Brave & codecs, GPU drivers (last)                                 |
| `dev`         | Minimal + power, no-sleep, GNOME tools, dev tools, Antigravity, Docker, KVM/QEMU, GPU drivers (last)        |
| `gaming`      | Minimal + power, GNOME tools, gaming packages (Steam, MangoHud, Vesktop), Flatpaks, GPU drivers (last)       |
| `workstation` | Minimal + power, GNOME tools, packages, Flatpaks, KVM/QEMU, GPU drivers (last)                               |
| `creator`     | Gaming + COPR tools (Yazi, Scrcpy), KVM/QEMU, GPU drivers (last)                                            |
| `full`        | All steps: DNF, DNS, power, no-sleep, fonts, shell, codecs, COPR, GNOME, packages, dev, Antigravity, Flatpaks, Docker, KVM, GPU drivers (last) |

---

## Requirements

- **OS:** Fedora 44 Workstation
- **Desktop:** GNOME
- **Disk:** At least 20GB free (varies by profile)
- **Tested on:** Intel, AMD, and NVIDIA systems, both desktop and laptop

---

## Warnings

- Some steps require a reboot (GPU drivers, Docker group, Secure Boot, KVM)
- NVIDIA users: read the Secure Boot prompts carefully; follow the MOK enrollment steps when prompted and complete key enrollment on reboot
- ZSH default shell change needs a logout/login
- Docker and libvirt group changes need a reboot or re-login
- The Antigravity repo is added with `gpgcheck=0` — this matches Google's own official Fedora/RHEL install instructions, which currently don't publish a signing key for the RPM repo (their APT/Debian instructions do). You're relying on HTTPS + Google's infrastructure for that package, not GPG signature verification. The script warns about this when the step runs; if that's not an acceptable trade-off for you, skip `setup_antigravity` and install manually once Google publishes a key.

---

## What Gets Installed

### Core

DNF optimization (parallel downloads, fastest mirror, version pinning), RPM Fusion, Flathub, optional DNS override (Cloudflare or Google), disable auto-sleep (GDM system dconf keyfile + user session), system fonts and FiraCode Nerd Font.

### Shell

ZSH, Starship prompt, zsh-autosuggestions, zsh-syntax-highlighting, eza/bat aliases.

### Power

TLP (optional, warns about GNOME power profiles conflict), ccache (50GB compressed), tuned virtual-host profile for KVM.

### Multimedia & Browsers

Brave Browser, FFmpeg freeworld, VA-API / NVENC support, OpenH264.

### GPU Drivers

Intel media driver, AMD freeworld VA/VDPAU, NVIDIA proprietary (akmods, Secure Boot key enrollment with guided walkthrough).

### Dev Tools

GCC, Clang, LLVM, Java, Node.js, Python, Docker + Docker Compose, Corepack, Antigravity CLI (`agy`, via Google's official installer), Rust (optional), Android tools, debuggers, build systems.

### Gaming

Steam (with H.264 unlock), MangoHud (auto-configured if installed), ProtonPlus. Included on `gaming`, `workstation`, `creator`, and `full` profiles.

### Virtualization

KVM/QEMU, libvirt with socket activation, virt-manager, VirtIO drivers for Windows VMs, firewall and storage pool setup.

### GNOME

GNOME Tweaks, Extension Manager, extension recommendations.

---

## Testing

The repository includes automated test suites covering all profiles, CLI arguments, helper functions, and backup/restore workflows:

```bash
# Run all test suites
bash tests/run_tests.sh
```

---

## Troubleshooting

**Script failed mid-run?**
Re-run it. The state file tracks progress, so it picks up from the last successful step.

**Low disk space warning?**
Free up space or acknowledge the prompt to continue anyway.

**Docker not working after install?**
Reboot to apply group membership, then test:
```bash
docker run --rm hello-world
```

**KVM permission denied?**
Run the post-reboot commands the script shows you, or:
```bash
sudo usermod -aG libvirt $USER
# Then reboot
```

**NVIDIA drivers not loading?**
Complete MOK enrollment on reboot (the blue "MOK Manager" screen).

---

## Getting Started

```bash
git clone https://github.com/kk376/fedora-post-install.git
cd fedora-post-install
chmod +x setup.sh
./setup.sh
```

Each step prompts before running.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines and testing instructions.

## License

MIT. See [LICENSE](LICENSE).
