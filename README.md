# Fedora 44 Post-Install Setup Script

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

An interactive post-installation script for Fedora 44 Workstation (GNOME).

Built from years of actual Fedora usage, covering the things I find myself setting up on every fresh install: driver detection, multimedia codecs, dev tools, gaming, shell customization, Docker, virtualization, and a handful of optional extras like Cloudflare Warp.

---

## Features

- **Interactive** — every step asks before running; nothing happens behind your back
- **Hardware-aware** — detects Intel / AMD / NVIDIA GPUs, hybrid Optimus setups, and CPU virtualization support
- **Secure Boot–aware NVIDIA setup** — builds kernel modules, generates keys, and walks you through MOK enrollment
- **Idempotent** — state file tracks what's done; you can interrupt and pick up where you left off, or `--force` to re-run
- **Profile-based** — six profiles so you only install what you actually need
- **Dry-run mode** — preview everything without touching the system
- **Backup and restore** — backs up config files before modifying them

---

## What's New in v5.1.0

- Restructured execution order: GPU driver setup now runs last, after all packages are installed
- Added automatic reboot checkpoint before driver setup (detects kernel mismatch from `dnf update`)
- After rebooting, re-running the script skips completed steps and resumes at driver setup
- This prevents kernel module builds against a stale kernel and avoids mid-script disruption from NVIDIA/MOK enrollment
- Updated profile step ordering for gaming and creator profiles

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

| Profile       | What it installs                                              |
| ------------- | ------------------------------------------------------------- |
| `minimal`     | DNF config, fonts, shell                                      |
| `dev`         | Minimal + dev tools, Docker, Antigravity, KVM                 |
| `gaming`      | Minimal + multimedia, packages, Flatpaks, GPU drivers (last)  |
| `workstation` | Dev + DNS, KVM/QEMU                                          |
| `creator`     | Gaming + multimedia, COPR tools, GPU drivers (last)           |
| `full`        | All steps with driver setup and reboot check at the very end  |

---

## Requirements

- **OS:** Fedora 44 Workstation
- **Desktop:** GNOME
- **Disk:** At least 20GB free (varies by profile)
- **Tested on:** Intel, AMD, and NVIDIA systems, both desktop and laptop

---

## Warnings

- Some steps require a reboot (GPU drivers, Docker group, Secure Boot, KVM)
- NVIDIA users: read the Secure Boot prompts carefully
- ZSH default shell change needs a logout/login
- Docker and libvirt group changes need a reboot or re-login
- The Antigravity repo is added with `gpgcheck=0` — this matches Google's own official Fedora/RHEL install instructions, which currently don't publish a signing key for the RPM repo (their APT/Debian instructions do). You're relying on HTTPS + Google's infrastructure for that package, not GPG signature verification. The script warns about this when the step runs; if that's not an acceptable trade-off for you, skip `setup_antigravity` and install manually once Google publishes a key.

---

## What Gets Installed

### Core

DNF optimization (parallel downloads, fastest mirror, version pinning), RPM Fusion, Flathub, optional DNS override (Google or Cloudflare), disable auto-sleep (GDM + user), system fonts and FiraCode Nerd Font.

### Shell

ZSH, Oh My Zsh, Powerlevel10k, zsh-autosuggestions, zsh-syntax-highlighting, eza/bat aliases.

### Power

TLP (optional, warns about GNOME power profiles conflict), ccache (50GB compressed), tuned virtual-host profile for KVM.

### Multimedia & Browsers

Brave Browser, FFmpeg freeworld, VA-API / NVENC support, OpenH264.

### GPU Drivers

Intel media driver, AMD freeworld VA/VDPAU, NVIDIA proprietary (akmods, Secure Boot key enrollment with guided walkthrough).

### Dev Tools

GCC, Clang, LLVM, Java, Node.js, Python, Docker + Docker Compose, Corepack, Antigravity CLI (`agy`, via Google's official installer), Rust (optional), Android tools, debuggers, build systems.

### Gaming

Steam (with H.264 unlock), MangoHud (auto-configured if installed), ProtonPlus.

### Cloud

Cloudflare Warp.

### Virtualization

KVM/QEMU, libvirt with socket activation, virt-manager, VirtIO drivers for Windows VMs, firewall and storage pool setup.

### GNOME

GNOME Tweaks, Extension Manager, extension recommendations.

---

## Testing

The repository includes automated test suites covering all profiles, CLI arguments, helper functions, and backup/restore workflows:

```bash
# Run all test suites
for t in tests/test_*.sh; do bash "$t"; done
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
git clone https://github.com/Kk376/fedora-post-install.git
cd fedora-post-install
chmod +x setup.sh
./setup.sh
```

Each step prompts before running.

---

Built and maintained by Kushagra Kumar.

## License

MIT — see [LICENSE](LICENSE).
