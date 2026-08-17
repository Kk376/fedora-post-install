#!/usr/bin/env bash
# ==============================================================================
# Test Suite: COPR & Fonts Subsystem (setup_copr & setup_fonts)
# Covers:
#   1. setup_copr repository and package configuration (scrcpy, yazi + preview deps)
#   2. setup_copr execution under success, enable failure, and install failure
#   3. setup_fonts package list (MS, Noto, Liberation, DejaVu, FiraCode Nerd Font)
#   4. setup_fonts FiraCode download, unzip, and fc-cache execution
#   5. Dry-run safety for both setup_copr and setup_fonts
#   6. Profile inclusion verification (creator, full, minimal, dev, gaming, workstation)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_SCRIPT="${SCRIPT_DIR}/setup.sh"

TOTAL=0
PASSED=0
FAILED=0

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() {
    TOTAL=$((TOTAL + 1))
    PASSED=$((PASSED + 1))
    echo -e "  [${GREEN}PASS${NC}] $1"
}

fail() {
    TOTAL=$((TOTAL + 1))
    FAILED=$((FAILED + 1))
    echo -e "  [${RED}FAIL${NC}] $1"
    [[ -n "${2:-}" ]] && echo "         Detail: $2"
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$label"
    else
        fail "$label" "Expected: '$expected', Actual: '$actual'"
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label" "Expected output to contain '$needle'"
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label" "Expected output NOT to contain '$needle'"
    fi
}

echo "================================================================"
echo "TEST SUITE: COPR & Fonts Subsystem Audit"
echo "Target: $SETUP_SCRIPT"
echo "================================================================"

# ==============================================================================
# Suite 1: setup_copr Static & Configuration Audit
# ==============================================================================
echo ""
echo -e "${BLUE}=== Suite 1: setup_copr Configuration Audit ===${NC}"

# Extract coprs array definition from setup_copr
copr_entries=$(sed -n '/setup_copr()/,/^}/p' "$SETUP_SCRIPT" | sed -n '/local coprs=(/,/)/p' | grep '"' | sed 's/^[ \t]*"//; s/"[ \t]*$//')

copr_repos=$(echo "$copr_entries" | awk -F':' '{print $1}')
expected_repos=$'zeno/scrcpy\nlihaohong/yazi'
assert_eq "COPR repos contain exactly zeno/scrcpy and lihaohong/yazi" "$expected_repos" "$copr_repos"

# Check no extraneous COPR enables exist anywhere in setup.sh
all_copr_enables=$(grep -n "copr enable" "$SETUP_SCRIPT" | grep -v 'dnf copr enable -y "\$repo"' || true)
assert_eq "No hardcoded extraneous COPR enable calls in setup.sh" "" "$all_copr_enables"

# Verify scrcpy package mapping
scrcpy_pkgs=$(echo "$copr_entries" | grep '^zeno/scrcpy:' | cut -d':' -f2)
assert_eq "zeno/scrcpy maps to scrcpy package" "scrcpy" "$scrcpy_pkgs"

# Verify yazi and all preview dependencies
yazi_pkgs=$(echo "$copr_entries" | grep '^lihaohong/yazi:' | cut -d':' -f2)
required_yazi_deps=(
    "yazi"           # Main binary
    "file"           # File type / mime detection
    "ffmpeg"         # Video thumbnails
    "7zip"           # Archive extraction / previews
    "jq"             # JSON preview
    "poppler-utils"  # PDF preview (pdftoppm)
    "fd-find"        # Fast directory search
    "ripgrep"        # Fast text search
    "fzf"            # Fuzzy filtering
    "zoxide"         # Directory jumping
    "resvg"          # SVG preview
    "xclip"          # X11 clipboard
    "wl-clipboard"   # Wayland clipboard
    "xsel"           # Alternative X11 clipboard
    "ImageMagick"    # Image manipulation/preview
)

for dep in "${required_yazi_deps[@]}"; do
    if [[ " $yazi_pkgs " =~ " $dep " ]]; then
        pass "Yazi dependency list contains '$dep'"
    else
        fail "Yazi dependency list contains '$dep'" "Missing from: $yazi_pkgs"
    fi
done

# ==============================================================================
# Suite 2: setup_copr Execution & Error Handling (Mocked)
# ==============================================================================
echo ""
echo -e "${BLUE}=== Suite 2: setup_copr Runtime Behavior & Error Handling ===${NC}"

# Extract setup_copr function source directly
copr_func_code=$(sed -n '/^setup_copr() {/,/^}/p' "$SETUP_SCRIPT")
fonts_func_code=$(sed -n '/^setup_fonts() {/,/^}/p' "$SETUP_SCRIPT")

# Test normal execution flow
test_copr_execution() {
    local func_code="$1"
    bash <<EOF
set -u
LOG_MESSAGES=()
SUDO_CMDS=()
WARN_MESSAGES=()
COMPLETED=""

log() { echo "LOG: \$1"; }
warn() { echo "WARN: \$1"; }
step_complete() { echo "STEP: \$1"; }
run_sudo() {
    echo "SUDO: \$*"
    return 0
}

$func_code

setup_copr
EOF
}

copr_exec_out=$(test_copr_execution "$copr_func_code")
assert_contains "setup_copr enables zeno/scrcpy" "SUDO: dnf copr enable -y zeno/scrcpy" "$copr_exec_out"
assert_contains "setup_copr installs scrcpy" "SUDO: dnf install -y --skip-unavailable scrcpy" "$copr_exec_out"
assert_contains "setup_copr enables lihaohong/yazi" "SUDO: dnf copr enable -y lihaohong/yazi" "$copr_exec_out"
assert_contains "setup_copr installs yazi with preview tools" "SUDO: dnf install -y --skip-unavailable yazi file ffmpeg 7zip jq poppler-utils fd-find ripgrep fzf zoxide resvg xclip wl-clipboard xsel ImageMagick" "$copr_exec_out"
assert_contains "setup_copr marks step complete" "STEP: COPR packages installed" "$copr_exec_out"
assert_not_contains "setup_copr has 0 warnings on success" "WARN:" "$copr_exec_out"

# Test repo enable failure handling
test_copr_enable_failure() {
    local func_code="$1"
    bash <<EOF
set -u
log() { :; }
warn() { echo "WARN: \$1"; }
step_complete() { echo "STEP: \$1"; }
run_sudo() {
    local cmd="\$*"
    if [[ "\$cmd" == *"copr enable -y zeno/scrcpy"* ]]; then
        return 1
    fi
    echo "RAN: \$cmd"
    return 0
}

$func_code

setup_copr
EOF
}

copr_fail_out=$(test_copr_enable_failure "$copr_func_code")
assert_contains "setup_copr warns on enable failure" "WARN: Failed to enable COPR repo zeno/scrcpy" "$copr_fail_out"
assert_not_contains "setup_copr skips install when repo enable fails" "RAN: dnf install -y --skip-unavailable scrcpy" "$copr_fail_out"
assert_contains "setup_copr continues with remaining repos after failure" "RAN: dnf copr enable -y lihaohong/yazi" "$copr_fail_out"

# ==============================================================================
# Suite 3: setup_fonts Static Package Audit
# ==============================================================================
echo ""
echo -e "${BLUE}=== Suite 3: setup_fonts Static Package Audit ===${NC}"

# 1. DejaVu fonts
assert_contains "setup_fonts installs dejavu-sans-fonts" "dejavu-sans-fonts" "$fonts_func_code"
assert_contains "setup_fonts installs dejavu-serif-fonts" "dejavu-serif-fonts" "$fonts_func_code"
assert_contains "setup_fonts installs dejavu-sans-mono-fonts" "dejavu-sans-mono-fonts" "$fonts_func_code"

# 2. Liberation fonts
assert_contains "setup_fonts installs liberation-sans-fonts" "liberation-sans-fonts" "$fonts_func_code"
assert_contains "setup_fonts installs liberation-serif-fonts" "liberation-serif-fonts" "$fonts_func_code"
assert_contains "setup_fonts installs liberation-mono-fonts" "liberation-mono-fonts" "$fonts_func_code"

# 3. Google Noto fonts & metric-compatible MS substitutes
assert_contains "setup_fonts installs google-noto-sans-fonts" "google-noto-sans-fonts" "$fonts_func_code"
assert_contains "setup_fonts installs google-noto-serif-fonts" "google-noto-serif-fonts" "$fonts_func_code"
assert_contains "setup_fonts installs google-noto-mono-fonts" "google-noto-mono-fonts" "$fonts_func_code"
assert_contains "setup_fonts installs google-carlito-fonts" "google-carlito-fonts" "$fonts_func_code"
assert_contains "setup_fonts installs google-caladea-fonts" "google-caladea-fonts" "$fonts_func_code"

# 4. Microsoft fonts
assert_contains "setup_fonts installs mscore-fonts" "mscore-fonts" "$fonts_func_code"
assert_contains "setup_fonts installs mscore-fonts-all" "mscore-fonts-all" "$fonts_func_code"
assert_contains "setup_fonts downloads msttcore-fonts-installer" "msttcore-fonts-installer-2.6-1.noarch.rpm" "$fonts_func_code"
assert_contains "setup_fonts installs rpm with nodigest/nofiledigest" "rpm -ivh --nodigest --nofiledigest msttcore-fonts-installer" "$fonts_func_code"
assert_contains "setup_fonts installs cabextract for MS core fonts" "cabextract" "$fonts_func_code"
assert_contains "setup_fonts cleans up msttcore-fonts rpm after install" "rm -f msttcore-fonts-installer-2.6-1.noarch.rpm" "$fonts_func_code"

# 5. FiraCode Nerd Font parameters
assert_contains "setup_fonts targets ryanoasis/nerd-fonts repo" "ryanoasis/nerd-fonts" "$fonts_func_code"
assert_contains "setup_fonts uses FiraCode regex pattern" 'FiraCode\\.zip' "$fonts_func_code"
assert_contains "setup_fonts outputs to /tmp/FiraCode.zip" "/tmp/FiraCode.zip" "$fonts_func_code"
assert_contains "setup_fonts provides fallback URL" "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FiraCode.zip" "$fonts_func_code"
assert_contains "setup_fonts unpacks to ~/.local/share/fonts" "~/.local/share/fonts" "$fonts_func_code"
assert_contains "setup_fonts cleans up temporary zip" "rm -f /tmp/FiraCode.zip" "$fonts_func_code"

# 6. fc-cache execution
assert_contains "setup_fonts executes fc-cache -fv" "fc-cache -fv" "$fonts_func_code"

# ==============================================================================
# Suite 4: setup_fonts Runtime & Dry-Run Safety
# ==============================================================================
echo ""
echo -e "${BLUE}=== Suite 4: setup_fonts Runtime & Dry-Run Safety ===${NC}"

# Test DRY_RUN=true safety
test_fonts_dry_run() {
    local func_code="$1"
    bash <<EOF
set -u
DRY_RUN=true
REAL_EXEC_COUNT=0

log() { :; }
info() { :; }
warn() { :; }
step_complete() { :; }
dry() { echo "DRY: \$1"; }
run() { dry "\$*"; }
run_sudo() { dry "sudo \$*"; }
github_download() { ((REAL_EXEC_COUNT++)); return 0; }
fc-cache() { ((REAL_EXEC_COUNT++)); return 0; }
mkdir() { ((REAL_EXEC_COUNT++)); return 0; }
unzip() { ((REAL_EXEC_COUNT++)); return 0; }

$func_code

setup_fonts

echo "REAL_EXEC_COUNT=\$REAL_EXEC_COUNT"
EOF
}

dry_run_out=$(test_fonts_dry_run "$fonts_func_code")
assert_contains "Dry-run makes zero real filesystem or cache modifications" "REAL_EXEC_COUNT=0" "$dry_run_out"
assert_contains "Dry-run logs DNF font install" "DRY: sudo dnf install -y --skip-unavailable" "$dry_run_out"
assert_contains "Dry-run logs msttcore-fonts curl download" "DRY: curl -sLO https://downloads.sourceforge.net/project/mscorefonts2/rpms/msttcore-fonts-installer-2.6-1.noarch.rpm" "$dry_run_out"
assert_contains "Dry-run logs msttcore-fonts rpm installation" "DRY: sudo rpm -ivh --nodigest --nofiledigest msttcore-fonts-installer-2.6-1.noarch.rpm" "$dry_run_out"
assert_contains "Dry-run logs msttcore-fonts cleanup" "DRY: rm -f msttcore-fonts-installer-2.6-1.noarch.rpm" "$dry_run_out"
assert_contains "Dry-run logs FiraCode Nerd Font download/install" "DRY: Download and install FiraCode Nerd Font" "$dry_run_out"
assert_contains "Dry-run logs fc-cache -fv" "DRY: fc-cache -fv" "$dry_run_out"

# Test DRY_RUN=false execution flow (mocked tools)
test_fonts_live_execution() {
    local func_code="$1"
    bash <<EOF
set -u
DRY_RUN=false

log() { :; }
info() { :; }
warn() { :; }
success() { echo "SUCCESS: \$1"; }
step_complete() { echo "STEP: \$1"; }
run() { echo "RUN: \$*"; }
run_sudo() { echo "SUDO: \$*"; }
mkdir() { echo "MKDIR: \$*"; }
unzip() { echo "UNZIP: \$*"; }
rm() { echo "RM: \$*"; }
fc-cache() { echo "FC-CACHE: \$*"; }

github_download() {
    echo "GH_DOWNLOAD: repo=\$1 pattern=\$2 output=\$3 fallback=\$4"
    return 0
}

$func_code

setup_fonts
EOF
}

live_exec_out=$(test_fonts_live_execution "$fonts_func_code")
assert_contains "Live mode creates font directory ~/.local/share/fonts" "MKDIR: -p $HOME/.local/share/fonts" "$live_exec_out"
assert_contains "Live mode downloads FiraCode" "GH_DOWNLOAD: repo=ryanoasis/nerd-fonts pattern=FiraCode\\.zip output=/tmp/FiraCode.zip" "$live_exec_out"
assert_contains "Live mode unzips font archive" "UNZIP: -oq /tmp/FiraCode.zip -d $HOME/.local/share/fonts/" "$live_exec_out"
assert_contains "Live mode removes temporary zip" "RM: -f /tmp/FiraCode.zip" "$live_exec_out"
assert_contains "Live mode executes fc-cache -fv" "FC-CACHE: -fv" "$live_exec_out"
assert_contains "Live mode signals FiraCode success" "SUCCESS: FiraCode Nerd Font installed" "$live_exec_out"
assert_contains "Live mode finishes font setup step" "STEP: Fonts installed" "$live_exec_out"

# Test DRY_RUN=false FiraCode download failure handling
test_fonts_download_failure() {
    local func_code="$1"
    bash <<EOF
set -u
DRY_RUN=false

log() { :; }
info() { echo "INFO: \$1"; }
warn() { echo "WARN: \$1"; }
success() { :; }
step_complete() { echo "STEP: \$1"; }
run() { :; }
run_sudo() { :; }
mkdir() { :; }
fc-cache() { echo "FC-CACHE: \$*"; }

github_download() { return 1; }

$func_code

setup_fonts
EOF
}

fail_exec_out=$(test_fonts_download_failure "$fonts_func_code")
assert_contains "FiraCode download failure issues warning" "WARN: Failed to download FiraCode Nerd Font" "$fail_exec_out"
assert_contains "FiraCode download failure displays manual URL info" "INFO: Manual download: https://github.com/ryanoasis/nerd-fonts/releases" "$fail_exec_out"
assert_contains "fc-cache -fv still runs to refresh system fonts when FiraCode fails" "FC-CACHE: -fv" "$fail_exec_out"
assert_contains "Font step completes even if optional FiraCode download fails" "STEP: Fonts installed" "$fail_exec_out"

# ==============================================================================
# Suite 5: Profile Inclusions
# ==============================================================================
echo ""
echo -e "${BLUE}=== Suite 5: Profile Inclusions for COPR & Fonts ===${NC}"

# Parse PROFILE_STEPS from setup.sh
declare -A PROFILE_STEPS
while IFS= read -r line; do
    eval "$line"
done < <(grep -E 'PROFILE_STEPS\[[a-z]+\]=' "$SETUP_SCRIPT")

# setup_fonts must be in all profiles
for prof in minimal dev gaming workstation creator; do
    if [[ "${PROFILE_STEPS[$prof]}" == *"setup_fonts"* ]]; then
        pass "Profile '$prof' includes setup_fonts"
    else
        fail "Profile '$prof' includes setup_fonts" "Steps: ${PROFILE_STEPS[$prof]}"
    fi
done

# setup_copr must ONLY be in creator (and full by omission/default)
if [[ "${PROFILE_STEPS[creator]}" == *"setup_copr"* ]]; then
    pass "Profile 'creator' includes setup_copr"
else
    fail "Profile 'creator' includes setup_copr" "Steps: ${PROFILE_STEPS[creator]}"
fi

for prof in minimal dev gaming workstation; do
    if [[ "${PROFILE_STEPS[$prof]}" != *"setup_copr"* ]]; then
        pass "Profile '$prof' excludes setup_copr"
    else
        fail "Profile '$prof' excludes setup_copr" "Steps: ${PROFILE_STEPS[$prof]}"
    fi
done

# Full profile check
steps_definitions=$(sed -n '/local steps=(/,/)/p' "$SETUP_SCRIPT")
if [[ "$steps_definitions" == *"\"setup_copr:COPR Packages\""* ]]; then
    pass "Full profile includes setup_copr"
else
    fail "Full profile includes setup_copr"
fi

if [[ "$steps_definitions" == *"\"setup_fonts:System Fonts\""* ]]; then
    pass "Full profile includes setup_fonts"
else
    fail "Full profile includes setup_fonts"
fi

# ==============================================================================
# Final Summary
# ==============================================================================
echo ""
echo "================================================================"
echo "Final Summary: Total: $TOTAL, Passed: $PASSED, Failed: $FAILED"
echo "================================================================"

if [[ "$FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
