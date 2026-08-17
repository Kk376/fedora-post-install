#!/usr/bin/env bash
# Test harness for Fedora Post-Install setup.sh argument parsing and CLI matrix

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_SCRIPT="${SCRIPT_DIR}/setup.sh"

PASSED=0
FAILED=0
TOTAL=0

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

run_test() {
    local test_name="$1"
    local expected_code="$2"
    local expected_pattern="$3"
    shift 3
    local args=("$@")

    TOTAL=$((TOTAL + 1))
    
    local output
    local exit_code=0
    output=$(bash "$SETUP_SCRIPT" "${args[@]}" 2>&1) || exit_code=$?

    local pass=true
    local fail_reason=""

    if [[ "$exit_code" -ne "$expected_code" ]]; then
        pass=false
        fail_reason="expected exit code $expected_code, got $exit_code"
    elif [[ -n "$expected_pattern" ]] && ! echo "$output" | grep -qE "$expected_pattern"; then
        pass=false
        fail_reason="output did not match pattern '$expected_pattern'"
    fi

    if $pass; then
        echo -e "[${GREEN}PASS${NC}] $test_name"
        PASSED=$((PASSED + 1))
    else
        echo -e "[${RED}FAIL${NC}] $test_name ($fail_reason)"
        echo "       Args: ${args[*]:-none}"
        echo "       Output snippet: $(echo "$output" | head -n 3 | tr '\n' ' ')"
        FAILED=$((FAILED + 1))
    fi
}

echo "Running CLI Flags & Options Matrix Tests..."
echo "Target script: $SETUP_SCRIPT"
echo "------------------------------------------------------------"

# 1. Help flags
run_test "Help long flag (--help)" 0 "Usage: .*setup\.sh \[OPTIONS\]" --help
run_test "Help short flag (-h)" 0 "Usage: .*setup\.sh \[OPTIONS\]" -h
run_test "Help flag displays version" 0 "Fedora 44 Post-Install Setup Script v[0-9]+\.[0-9]+\.[0-9]+" --help
run_test "Help precedes subsequent flags" 0 "Usage: .*setup\.sh \[OPTIONS\]" -h --invalid

# 2. Dry-run flags
run_test "Dry-run long flag (--dry-run)" 0 "DRY-RUN MODE - No changes will be made" --dry-run
run_test "Dry-run short flag (-n)" 0 "DRY-RUN MODE - No changes will be made" -n

# 3. Force flags (paired with -n for safe dry-run)
run_test "Force long flag (--force -n)" 0 "DRY-RUN MODE" --force -n
run_test "Force short flag (-f -n)" 0 "DRY-RUN MODE" -f -n
run_test "Force flag reversed order (-n --force)" 0 "DRY-RUN MODE" -n --force
run_test "Force flag reversed short (-n -f)" 0 "DRY-RUN MODE" -n -f

# 4. Profile flags (--profile=VALUE and --profile VALUE)
# Minimal profile (7 steps)
run_test "Profile minimal (= syntax)" 0 "Profile: minimal" --profile=minimal -n
run_test "Profile minimal step count (= syntax)" 0 "of 7" --profile=minimal -n
run_test "Profile minimal (space syntax)" 0 "Profile: minimal" --profile minimal -n
run_test "Profile minimal step count (space syntax)" 0 "of 7" --profile minimal -n

# Dev profile (15 steps)
run_test "Profile dev (= syntax)" 0 "Profile: dev" --profile=dev -n
run_test "Profile dev step count (= syntax)" 0 "of 15" --profile=dev -n
run_test "Profile dev (space syntax)" 0 "Profile: dev" --profile dev -n
run_test "Profile dev step count (space syntax)" 0 "of 15" --profile dev -n

# Gaming profile (11 steps)
run_test "Profile gaming (= syntax)" 0 "Profile: gaming" --profile=gaming -n
run_test "Profile gaming step count (= syntax)" 0 "of 11" --profile=gaming -n
run_test "Profile gaming (space syntax)" 0 "Profile: gaming" --profile gaming -n
run_test "Profile gaming step count (space syntax)" 0 "of 11" --profile gaming -n

# Workstation profile (12 steps)
run_test "Profile workstation (= syntax)" 0 "Profile: workstation" --profile=workstation -n
run_test "Profile workstation step count (= syntax)" 0 "of 12" --profile=workstation -n
run_test "Profile workstation (space syntax)" 0 "Profile: workstation" --profile workstation -n
run_test "Profile workstation step count (space syntax)" 0 "of 12" --profile workstation -n

# Creator profile (13 steps)
run_test "Profile creator (= syntax)" 0 "Profile: creator" --profile=creator -n
run_test "Profile creator step count (= syntax)" 0 "of 13" --profile=creator -n
run_test "Profile creator (space syntax)" 0 "Profile: creator" --profile creator -n
run_test "Profile creator step count (space syntax)" 0 "of 13" --profile creator -n

# Full profile (17 steps)
run_test "Profile full (= syntax)" 0 "Profile: full" --profile=full -n
run_test "Profile full step count (= syntax)" 0 "of 17" --profile=full -n
run_test "Profile full (space syntax)" 0 "Profile: full" --profile full -n
run_test "Profile full step count (space syntax)" 0 "of 17" --profile full -n

# Default profile (when no profile flag passed)
run_test "Default profile is full" 0 "Profile: full" -n
run_test "Default profile step count" 0 "of 17" -n

# 5. Invalid options & validation checks
run_test "Invalid flag (--invalid)" 1 "Unknown option: --invalid" --invalid
run_test "Invalid short flag (-x)" 1 "Unknown option: -x" -x
run_test "Invalid option with dash (--unknown)" 1 "Unknown option: --unknown" --unknown
run_test "Invalid profile (= syntax)" 1 "Unknown profile: invalid" --profile=invalid
run_test "Invalid profile (space syntax)" 1 "Unknown profile: invalid" --profile invalid
run_test "Invalid profile name custom" 1 "Unknown profile: nonexistent" --profile=nonexistent
run_test "Invalid option after valid option" 1 "Unknown option: --bogus" -n --bogus
run_test "Profile missing argument" 1 "Option --profile requires an argument" --profile

# 6. Flag combinations and ordering
run_test "Combo: -n -f --profile=minimal" 0 "Profile: minimal" -n -f --profile=minimal
run_test "Combo: --profile=creator -f -n" 0 "Profile: creator" --profile=creator -f -n
run_test "Combo: --profile workstation -n --force" 0 "Profile: workstation" --profile workstation -n --force
run_test "Combo: -n --profile=dev -f" 0 "Profile: dev" -n --profile=dev -f
run_test "Combo: --dry-run -h (help exit)" 0 "Usage: .*setup\.sh \[OPTIONS\]" --dry-run -h

echo "------------------------------------------------------------"
echo "Results: $PASSED / $TOTAL passed, $FAILED failed."

if [[ "$FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
