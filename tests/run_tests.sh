#!/usr/bin/env bash
# ==============================================================================
# Test Runner for Fedora Post-Install Setup Script
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

echo -e "${CYAN}========================================================${NC}"
echo -e "${CYAN}   Fedora Post-Install: Automated Test Suite Runner${NC}"
echo -e "${CYAN}========================================================${NC}"
echo ""

SUITES=(
    "test_backup_restore.sh:Backup & Restore Subsystem"
    "test_cli_flags.sh:CLI Flags & Argument Parsing"
    "test_copr_fonts.sh:COPR Tools & Font Subsystem"
    "test_helpers.sh:Core Helper Functions & Utilities"
    "test_package_separation.sh:Package & Gaming Profile Separation"
    "test_profile_integrity.sh:Profile Matrix & Step Sequencing"
)

OVERALL_START=$(date +%s)
TOTAL_SUITES=${#SUITES[@]}
SUITES_PASSED=0
SUITES_FAILED=0

for suite_entry in "${SUITES[@]}"; do
    IFS=':' read -r script_name title <<< "$suite_entry"
    script_path="$SCRIPT_DIR/$script_name"

    if [[ ! -f "$script_path" ]]; then
        echo -e "${RED}[ERROR] Test script not found: $script_path${NC}"
        SUITES_FAILED=$((SUITES_FAILED + 1))
        continue
    fi

    echo -e "${BLUE}▶ Running Suite: ${title} (${script_name})${NC}"
    if bash "$script_path"; then
        SUITES_PASSED=$((SUITES_PASSED + 1))
        echo -e "${GREEN}✔ ${script_name} Passed${NC}\n"
    else
        SUITES_FAILED=$((SUITES_FAILED + 1))
        echo -e "${RED}✖ ${script_name} Failed${NC}\n"
    fi
done

OVERALL_END=$(date +%s)
DURATION=$((OVERALL_END - OVERALL_START))

echo -e "${CYAN}========================================================${NC}"
echo -e "${CYAN}                   FINAL TEST SUMMARY                   ${NC}"
echo -e "${CYAN}========================================================${NC}"
echo -e "Suites: ${SUITES_PASSED}/${TOTAL_SUITES} passed (${DURATION}s)"

if [[ $SUITES_FAILED -eq 0 ]]; then
    echo -e "${GREEN}All test suites completed successfully! 🚀${NC}"
    exit 0
else
    echo -e "${RED}One or more test suites failed.${NC}"
    exit 1
fi
