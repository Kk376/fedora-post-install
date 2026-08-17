#!/usr/bin/env bash
# ==============================================================================
# Shared Test Library for Fedora Post-Install Test Suites
# ==============================================================================

# ANSI Color Codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test Counters
TESTS_PASSED=${TESTS_PASSED:-0}
TESTS_FAILED=${TESTS_FAILED:-0}

pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}[PASS]${NC} $1"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}[FAIL]${NC} $1"
    [[ -n "${2:-}" ]] && echo -e "       ${YELLOW}Detail:${NC} $2"
}

info_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

assert_eq() {
    local expected="$1" actual="$2" test_name="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$test_name"
    else
        fail "$test_name" "Expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local needle="$1" haystack="$2" test_name="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$test_name"
    else
        fail "$test_name" "String did not contain '$needle'"
    fi
}

assert_not_contains() {
    local needle="$1" haystack="$2" test_name="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$test_name"
    else
        fail "$test_name" "String unexpectedly contained '$needle'"
    fi
}

print_suite_summary() {
    local suite_name="$1"
    local total=$((TESTS_PASSED + TESTS_FAILED))
    echo ""
    echo -e "${CYAN}========================================================${NC}"
    echo -e "${CYAN} Suite Summary: ${suite_name}${NC}"
    echo -e " Total: $total | Passed: ${GREEN}${TESTS_PASSED}${NC} | Failed: ${RED}${TESTS_FAILED}${NC}"
    echo -e "${CYAN}========================================================${NC}"
    [[ $TESTS_FAILED -eq 0 ]]
}
