#!/usr/bin/env bash
# ==============================================================================
# Unit & Integration Tests: Backup & Restore Subsystem
# Target: /home/kk376/code/fedora-post-install/setup.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SETUP_SCRIPT="$REPO_DIR/setup.sh"

TEST_TMP_DIR=$(mktemp -d /tmp/fpi_backup_test_XXXXXX)
trap 'rm -rf "$TEST_TMP_DIR"' EXIT

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo -e "\033[0;32m[PASS]\033[0m $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "\033[0;31m[FAIL]\033[0m $1: $2"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

info_test() {
    echo -e "\033[0;34m[TEST]\033[0m $1"
}

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Extract functions directly from setup.sh
setup_extracted_functions() {
    local fn_file="$TEST_TMP_DIR/extracted_fns.sh"
    # Extract helper and backup/restore functions up to check_network
    sed -n '/^# Logging functions/,/^check_network()/p' "$SETUP_SCRIPT" | sed '$d' > "$fn_file"
    source "$fn_file"
}

# ==============================================================================
# Test 1: Dummy Config Creation and Backup Execution
# ==============================================================================
test_backup_file_normal() {
    info_test "Test 1: backup_file with existing and non-existing config files"
    local sandbox="$TEST_TMP_DIR/test1"
    mkdir -p "$sandbox/home/.config/MangoHud" "$sandbox/etc/dnf"
    
    local zshrc="$sandbox/home/.zshrc"
    local bashrc="$sandbox/home/.bashrc"
    local dnf_conf="$sandbox/etc/dnf/dnf.conf"
    local mangohud_conf="$sandbox/home/.config/MangoHud/MangoHud.conf"
    local nonexistent="$sandbox/home/nonexistent.txt"

    echo "# test zshrc content v1" > "$zshrc"
    echo "# test bashrc content v1" > "$bashrc"
    echo "# test dnf.conf content v1" > "$dnf_conf"
    echo "# test MangoHud content v1" > "$mangohud_conf"

    export HOME="$sandbox/home"
    export DRY_RUN=false
    export BACKUP_DIR="$HOME/.config/fedora-setup-backups/$(date +%Y%m%d_%H%M%S)"
    export LOG_FILE="$sandbox/tmp/test.log"
    export STATE_FILE="$HOME/.config/fedora-setup/state.txt"

    setup_extracted_functions

    # Execute backup_file for all targets
    backup_file "$zshrc"
    backup_file "$bashrc"
    backup_file "$dnf_conf"
    backup_file "$mangohud_conf"
    backup_file "$nonexistent"

    # Verify backup directory exists
    if [[ ! -d "$BACKUP_DIR" ]]; then
        fail "Test 1" "BACKUP_DIR was not created"
        return
    fi

    # Verify backed up files exist and have exact content
    local ok=true
    for f in ".zshrc.backup" ".bashrc.backup" "dnf.conf.backup" "MangoHud.conf.backup"; do
        if [[ ! -f "$BACKUP_DIR/$f" ]]; then
            fail "Test 1" "Expected backup file $BACKUP_DIR/$f not found"
            ok=false
        fi
    done

    if [[ -f "$BACKUP_DIR/nonexistent.txt.backup" ]]; then
        fail "Test 1" "Non-existent file was incorrectly backed up"
        ok=false
    fi

    if [[ "$(cat "$BACKUP_DIR/.zshrc.backup")" != "# test zshrc content v1" ]] || \
       [[ "$(cat "$BACKUP_DIR/.bashrc.backup")" != "# test bashrc content v1" ]] || \
       [[ "$(cat "$BACKUP_DIR/dnf.conf.backup")" != "# test dnf.conf content v1" ]] || \
       [[ "$(cat "$BACKUP_DIR/MangoHud.conf.backup")" != "# test MangoHud content v1" ]]; then
        fail "Test 1" "Backup file content mismatch"
        ok=false
    fi

    if $ok; then
        pass "backup_file correctly created timestamped directory and backed up existing configs"
    fi
}

# ==============================================================================
# Test 2: Timestamped Directory Differentiation
# ==============================================================================
test_backup_timestamp_separation() {
    info_test "Test 2: Distinct backup directories on separate runs"
    local sandbox="$TEST_TMP_DIR/test2"
    mkdir -p "$sandbox/home"
    export HOME="$sandbox/home"
    export DRY_RUN=false
    
    local ts1="20260817_120000"
    local ts2="20260817_120500"
    
    BACKUP_DIR="$HOME/.config/fedora-setup-backups/$ts1"
    mkdir -p "$BACKUP_DIR"
    echo "test1" > "$BACKUP_DIR/.zshrc.backup"

    BACKUP_DIR="$HOME/.config/fedora-setup-backups/$ts2"
    mkdir -p "$BACKUP_DIR"
    echo "test2" > "$BACKUP_DIR/.zshrc.backup"

    local count
    count=$(ls -d "$HOME/.config/fedora-setup-backups"/*/ | wc -l)
    if [[ "$count" -eq 2 ]]; then
        pass "Multiple timestamped backup directories coexist independently"
    else
        fail "Test 2" "Expected 2 backup directories, found $count"
    fi
}

# ==============================================================================
# Test 3: restore_backups Identifies Latest Backup and Restores Accurately
# ==============================================================================
test_restore_backups_latest() {
    info_test "Test 3: restore_backups picks latest backup and restores modified/deleted files"
    local sandbox="$TEST_TMP_DIR/test3"
    mkdir -p "$sandbox/home/.config/MangoHud" "$sandbox/home/.config/fedora-setup" "$sandbox/etc/dnf"
    
    export HOME="$sandbox/home"
    export DRY_RUN=false
    export STATE_FILE="$HOME/.config/fedora-setup/state.txt"
    echo "step_1" > "$STATE_FILE"
    echo "step_2" >> "$STATE_FILE"

    local zshrc="$sandbox/home/.zshrc"
    local bashrc="$sandbox/home/.bashrc"
    local mangohud_conf="$sandbox/home/.config/MangoHud/MangoHud.conf"

    # Setup older backup dir
    local old_backup="$HOME/.config/fedora-setup-backups/20260817_100000"
    mkdir -p "$old_backup"
    echo "# OLD ZSHRC" > "$old_backup/.zshrc.backup"
    echo "# OLD BASHRC" > "$old_backup/.bashrc.backup"
    echo "# OLD MANGOHUD" > "$old_backup/MangoHud.conf.backup"

    # Ensure timestamp ordering
    sleep 1

    # Setup newer (latest) backup dir
    local latest_backup_dir="$HOME/.config/fedora-setup-backups/20260817_110000"
    mkdir -p "$latest_backup_dir"
    echo "# LATEST ZSHRC" > "$latest_backup_dir/.zshrc.backup"
    echo "# LATEST BASHRC" > "$latest_backup_dir/.bashrc.backup"
    echo "# LATEST MANGOHUD" > "$latest_backup_dir/MangoHud.conf.backup"

    # Modify / corrupt / delete target files
    echo "# CORRUPTED ZSHRC" > "$zshrc"
    rm -f "$bashrc" # deleted
    echo "# CORRUPTED MANGOHUD" > "$mangohud_conf"

    # Setup mock sudo in PATH
    mkdir -p "$sandbox/bin"
    cat << 'EOF' > "$sandbox/bin/sudo"
#!/usr/bin/env bash
"$@"
EOF
    chmod +x "$sandbox/bin/sudo"
    export PATH="$sandbox/bin:$PATH"

    setup_extracted_functions

    # Override confirm to auto-yes for testing
    confirm() { return 0; }

    restore_backups

    local ok=true
    if [[ ! -f "$zshrc" ]] || [[ "$(cat "$zshrc")" != "# LATEST ZSHRC" ]]; then
        fail "Test 3" ".zshrc was not restored from the latest backup (got: $(cat "$zshrc" 2>/dev/null || echo 'missing'))"
        ok=false
    fi

    if [[ ! -f "$bashrc" ]] || [[ "$(cat "$bashrc")" != "# LATEST BASHRC" ]]; then
        fail "Test 3" ".bashrc was not restored from the latest backup (got: $(cat "$bashrc" 2>/dev/null || echo 'missing'))"
        ok=false
    fi

    if [[ ! -f "$mangohud_conf" ]] || [[ "$(cat "$mangohud_conf")" != "# LATEST MANGOHUD" ]]; then
        fail "Test 3" "MangoHud.conf was not restored from the latest backup"
        ok=false
    fi

    if [[ -f "$STATE_FILE" ]]; then
        fail "Test 3" "STATE_FILE was not deleted after restore"
        ok=false
    fi

    if $ok; then
        pass "restore_backups accurately identified latest backup, restored dotfiles + configs, and reset state"
    fi
}

# ==============================================================================
# Test 4: restore_backups with No Backups
# ==============================================================================
test_restore_backups_empty() {
    info_test "Test 4: restore_backups when no backups directory exists"
    local sandbox="$TEST_TMP_DIR/test4"
    mkdir -p "$sandbox/home"
    export HOME="$sandbox/home"
    export DRY_RUN=false
    
    setup_extracted_functions

    warn_called=false
    warn() { warn_called=true; }

    set +e
    restore_backups
    local ret=$?
    set -e

    if [[ $ret -eq 1 ]] && $warn_called; then
        pass "restore_backups handled missing backups directory gracefully (returned 1 and warned)"
    else
        fail "Test 4" "Expected return code 1 and warning, got $ret"
    fi
}

# ==============================================================================
# Test 5: Dry-Run Mode for backup_file
# ==============================================================================
test_dry_run_backup_file() {
    info_test "Test 5: Dry-run mode for backup_file"
    local sandbox="$TEST_TMP_DIR/test5"
    mkdir -p "$sandbox/home"
    
    local test_file="$sandbox/home/.zshrc"
    echo "# real content" > "$test_file"

    export HOME="$sandbox/home"
    export DRY_RUN=true
    export BACKUP_DIR="$HOME/.config/fedora-setup-backups/20260817_130000"
    
    setup_extracted_functions

    dry_msg=""
    dry() { dry_msg="$1"; }

    backup_file "$test_file"

    if [[ -d "$BACKUP_DIR" ]]; then
        fail "Test 5" "BACKUP_DIR was created in dry-run mode"
    elif [[ -z "$dry_msg" ]]; then
        fail "Test 5" "dry-run message was not emitted"
    else
        pass "backup_file in dry-run mode logged intent without creating backup directory or copying files"
    fi
}

# ==============================================================================
# Test 6: Dry-Run Mode for restore_backups
# ==============================================================================
test_dry_run_restore_backups() {
    info_test "Test 6: Dry-run mode for restore_backups (default confirmation)"
    local sandbox="$TEST_TMP_DIR/test6"
    mkdir -p "$sandbox/home/.config/fedora-setup"
    
    export HOME="$sandbox/home"
    export DRY_RUN=true
    export STATE_FILE="$HOME/.config/fedora-setup/state.txt"
    echo "test_state" > "$STATE_FILE"

    local zshrc="$sandbox/home/.zshrc"
    echo "# CURRENT ZSHRC" > "$zshrc"

    local backup_dir="$HOME/.config/fedora-setup-backups/20260817_140000"
    mkdir -p "$backup_dir"
    echo "# BACKED UP ZSHRC" > "$backup_dir/.zshrc.backup"

    setup_extracted_functions

    dry_calls=()
    dry() { dry_calls+=("$1"); }

    restore_backups

    local ok=true
    if [[ "$(cat "$zshrc")" != "# CURRENT ZSHRC" ]]; then
        fail "Test 6" ".zshrc was modified during dry-run restore"
        ok=false
    fi

    if [[ ! -f "$STATE_FILE" ]]; then
        fail "Test 6" "STATE_FILE was removed during dry-run restore"
        ok=false
    fi

    local found_prompt=false
    for m in "${dry_calls[@]}"; do
        if [[ "$m" == *"Restore all files from this backup?"* ]]; then
            found_prompt=true
            break
        fi
    done

    if ! $found_prompt; then
        fail "Test 6" "Prompt dry-run message not found"
        ok=false
    fi

    if $ok; then
        pass "restore_backups in dry-run mode safely evaluated auto-no prompt without overwriting files or state"
    fi
}

# ==============================================================================
# Test 7: Simulated Dry-Run with Restoration Loop Execution
# ==============================================================================
test_dry_run_restore_execution_loop() {
    info_test "Test 7: Dry-run restore execution inside loop (with confirmed prompt)"
    local sandbox="$TEST_TMP_DIR/test7"
    mkdir -p "$sandbox/home/.config/MangoHud" "$sandbox/home/.config/fedora-setup"
    
    export HOME="$sandbox/home"
    export DRY_RUN=true
    export STATE_FILE="$HOME/.config/fedora-setup/state.txt"
    echo "test_state" > "$STATE_FILE"

    local zshrc="$sandbox/home/.zshrc"
    echo "# CURRENT ZSHRC" > "$zshrc"

    local backup_dir="$HOME/.config/fedora-setup-backups/20260817_150000"
    mkdir -p "$backup_dir"
    echo "# BACKED UP ZSHRC" > "$backup_dir/.zshrc.backup"
    echo "# BACKED UP MANGOHUD" > "$backup_dir/MangoHud.conf.backup"

    setup_extracted_functions

    dry_cps=()
    dry() { dry_cps+=("$1"); }
    confirm() { return 0; } # Forced yes to test dry branch inside loop

    restore_backups

    local ok=true
    if [[ "$(cat "$zshrc")" != "# CURRENT ZSHRC" ]]; then
        fail "Test 7" ".zshrc was modified during dry-run restore loop"
        ok=false
    fi

    if [[ ! -f "$STATE_FILE" ]]; then
        fail "Test 7" "STATE_FILE was deleted during dry-run restore"
        ok=false
    fi

    local found_zsh=false found_mango=false
    for c in "${dry_cps[@]}"; do
        [[ "$c" == *"cp "*".zshrc.backup"*"/.zshrc"* ]] && found_zsh=true
        [[ "$c" == *"cp "*"MangoHud.conf.backup"*"MangoHud.conf"* ]] && found_mango=true
    done

    if ! $found_zsh || ! $found_mango; then
        fail "Test 7" "Dry cp messages were not logged properly: ${dry_cps[*]}"
        ok=false
    fi

    if $ok; then
        pass "restore_backups loop dry-run accurately previewed cp commands without side effects"
    fi
}

# ==============================================================================
# Test 8: System file restore (/etc/dnf/dnf.conf) with run_sudo
# ==============================================================================
test_restore_system_file() {
    info_test "Test 8: System config file (/etc/dnf/dnf.conf) restoration using run_sudo"
    local sandbox="$TEST_TMP_DIR/test8"
    mkdir -p "$sandbox/home/.config/fedora-setup" "$sandbox/etc/dnf"
    
    export HOME="$sandbox/home"
    export DRY_RUN=false
    export STATE_FILE="$HOME/.config/fedora-setup/state.txt"
    echo "step_1" > "$STATE_FILE"

    local dnf_conf="/etc/dnf/dnf.conf"
    local backup_dir="$HOME/.config/fedora-setup-backups/20260817_160000"
    mkdir -p "$backup_dir"
    echo "# BACKED UP DNF CONF" > "$backup_dir/dnf.conf.backup"

    setup_extracted_functions

    # Track run_sudo calls
    sudo_called_with=""
    run_sudo() {
        sudo_called_with="$*"
        # Simulate copying into sandbox if needed
        return 0
    }
    confirm() { return 0; }

    restore_backups

    if [[ "$sudo_called_with" == *"cp $backup_dir/dnf.conf.backup /etc/dnf/dnf.conf"* ]]; then
        pass "restore_backups used run_sudo when restoring system file /etc/dnf/dnf.conf"
    else
        fail "Test 8" "Expected run_sudo call with dnf.conf.backup, got: '$sudo_called_with'"
    fi
}

# ==============================================================================
# Test 9: Unknown backup files are ignored cleanly
# ==============================================================================
test_unknown_backup_files_ignored() {
    info_test "Test 9: Unknown backup files in directory are safely ignored"
    local sandbox="$TEST_TMP_DIR/test9"
    mkdir -p "$sandbox/home/.config/fedora-setup"
    
    export HOME="$sandbox/home"
    export DRY_RUN=false
    export STATE_FILE="$HOME/.config/fedora-setup/state.txt"
    echo "step_1" > "$STATE_FILE"

    local backup_dir="$HOME/.config/fedora-setup-backups/20260817_170000"
    mkdir -p "$backup_dir"
    echo "# UNKNOWN BACKUP" > "$backup_dir/unknown_custom.conf.backup"
    echo "# RANDOM FILE" > "$backup_dir/notes.txt"

    setup_extracted_functions
    confirm() { return 0; }

    set +e
    restore_backups
    local ret=$?
    set -e

    if [[ $ret -eq 0 ]]; then
        pass "restore_backups safely handled unknown backup files without crashing"
    else
        fail "Test 9" "restore_backups failed on unknown files with code $ret"
    fi
}

# ==============================================================================
# Test 10: backup_file handles directories and special paths
# ==============================================================================
test_backup_directory_handling() {
    info_test "Test 10: backup_file on directory targets"
    local sandbox="$TEST_TMP_DIR/test10"
    mkdir -p "$sandbox/home/some_dir"
    
    export HOME="$sandbox/home"
    export DRY_RUN=false
    export BACKUP_DIR="$HOME/.config/fedora-setup-backups/20260817_180000"

    setup_extracted_functions

    # Attempt to backup a directory
    backup_file "$sandbox/home/some_dir"

    if [[ -d "$BACKUP_DIR" ]]; then
        fail "Test 10" "backup_file created backup for a directory target"
    else
        pass "backup_file skipped directory targets safely"
    fi
}

# Run all test suites
echo "========================================================"
echo "Running Backup & Restore Subsystem Test Suite"
echo "Target: $SETUP_SCRIPT"
echo "========================================================"

test_backup_file_normal
test_backup_timestamp_separation
test_restore_backups_latest
test_restore_backups_empty
test_dry_run_backup_file
test_dry_run_restore_backups
test_dry_run_restore_execution_loop
test_restore_system_file
test_unknown_backup_files_ignored
test_backup_directory_handling

echo "========================================================"
echo "Test Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "========================================================"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
