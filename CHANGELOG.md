# Changelog

All notable changes to this project will be documented in this file.

Follows semantic versioning: MAJOR.MINOR.PATCH

---

## [v5.0.0] – 2026-08-14

### Added

- Updated for Fedora 44
- Antigravity CLI in dev tools (replaces discontinued Gemini CLI)
- MangoHud config folded into the packages step (auto-configures if mangohud is present)
- Reusable `github_download()` helper for GitHub release fetches

### Removed

- Gemini CLI is discontinued; replaced by Antigravity CLI in dev tools
- OnlyOffice step (LibreOffice ships with Fedora)
- Winboat step (too niche)
- LM Studio step (AppImage wrangling; use Ollama instead)
- MangoHud config as a standalone step (moved into packages)
- preload from COPR (negligible benefit on SSDs)
- ani-cli from COPR (too niche)
- Yaru theme prompt (Ubuntu theme on Fedora is uncommon)

### Improved

- Profiles updated to match the leaner step list
- Deduplicated gsettings calls in no-sleep setup
- Simplified Docker service management (removed redundant enable/start calls)
- ccache config no longer appends duplicate lines on re-run
- Corepack moved from Docker step to dev tools where it belongs
- Fixed `nvim` package name to `neovim`
- Simplified confirm prompt function
- Cleaned up script header

---

## [v4.0.0] – 2026-01-21

### Added

- KVM/QEMU virtualization module with modern socket activation (`virtqemud.socket`)
- `workstation` profile (Dev + Virtualization + Office) and `creator` profile (Gaming + Multimedia + AI)
- Rollback on failure: stops services, preserves state, points to logs
- Disk space check before starting (warns if <20GB free)
- Version pinning via `best=True` in DNF operations
- Network validation before remote operations

### Improved

- DNF config uses `best=True` and atomic RPM Fusion installation
- Better error handling with state preservation for resumption
- Modern libvirt socket activation instead of legacy service
- Documentation updated for new features and troubleshooting

### Fixed

- Progress counter in dry-run mode
- Service management during emergency rollback
- User group handling for Docker and libvirt
- Profile step filters for new profiles

---

## [v3.0.0] – 2026-01-17

### Added

- Profile system: `--profile=minimal|dev|gaming|full`
- State file (`~/.config/fedora-setup/state.txt`) for idempotency
- `--force` flag to re-run completed steps
- DNS provider choice (Google, Cloudflare, or skip)
- TLP opt-in with GNOME power profiles warning
- RPM Fusion validation before multimedia step
- Dynamic step counting based on profile

### Improved

- NVIDIA Secure Boot flow: `akmods --force` + `modinfo` check before MOK enrollment
- DNF config uses `# BEGIN/END fedora-setup` block markers for clean idempotency
- More specific GPU detection patterns (VGA|3D|Display)
- Dry-run skips DNS step; progress counters only increment in real runs
- State file reset after backup restore

### Removed

- Unused `check_existing_config()` function
- `alsa-plugins-pulseaudio` (unnecessary on PipeWire)

---

## [v2.0.2] – 2026-01-16

### Added

- Enabled `fedora-cisco-openh264` repository for OpenH264 availability

---

## [v2.0.1] – 2026-01-16

### Fixed

- Typo in `keepcache` in dnf.conf

---

## [v2.0.0] – 2026-01-16

### Added

- Backup/restore for config files before modification
- Dry-run mode to preview actions without touching the system
- Logging to file for debugging
- Post-step validation for each major step
- Version and state checks to avoid redundant work

### Improved

- Script safety and predictability
- Idempotency of installation steps
- Error visibility and troubleshooting

### Notes

- v2.0 is a breaking change internally due to new execution flow
- Review dry-run output before upgrading from v1.x

---

## [v1.0.0] – Initial Release

### Added

- Interactive Fedora post-install script
- DNF optimization and repository setup
- TLP power management with boot-time fix
- GPU driver detection (Intel / AMD / NVIDIA with Secure Boot)
- ZSH + Powerlevel10k setup
- Multimedia, gaming, and dev environment configuration
- Cloudflare Warp, Docker, Antigravity integration
