#!/usr/bin/env bash
#
# Edge Eloquent - Master Test Suite Runner
# Executes all test suites across Model, Audio, Cleanup, Cloudflare Security,
# History Store, and Feather Source components in Linux CI / local development.
#

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASSED_COUNT=0
FAILED_COUNT=0
TOTAL_TESTS=7

print_header() {
    echo -e "\n${BLUE}${BOLD}======================================================================${NC}"
    echo -e "${BLUE}${BOLD} $1 ${NC}"
    echo -e "${BLUE}${BOLD}======================================================================${NC}"
}

run_suite() {
    local suite_name="$1"
    local command="$2"

    print_header "Running: ${suite_name}"
    echo -e "${YELLOW}Command: ${command}${NC}\n"

    if eval "${command}"; then
        echo -e "\n${GREEN}${BOLD}✓ PASS: ${suite_name}${NC}"
        ((PASSED_COUNT++))
    else
        echo -e "\n${RED}${BOLD}✗ FAIL: ${suite_name}${NC}"
        ((FAILED_COUNT++))
    fi
}

echo -e "${BOLD}======================================================================${NC}"
echo -e "${BOLD} Edge Eloquent - Comprehensive Test Runner${NC}"
echo -e "${BOLD} Environment: Linux $(uname -s) $(uname -m)${NC}"
echo -e "${BOLD} Python: $(python3 --version 2>&1)${NC}"
echo -e "${BOLD} Node.js: $(node --version 2>&1)${NC}"
echo -e "${BOLD}======================================================================${NC}"

# 1. Model Weights Absence Assertions
run_suite "Suite 1: Model Weights Exclusion Assertion" \
    "./scripts/assert_no_weights.sh"

# 2. Model Specifications & Allowlist Verification
run_suite "Suite 2: Model Specifications & RAM Constraints" \
    "python3 -m unittest Tests/test_model_spec.py"

# 3. Audio Encoder & PCM Format Verification
run_suite "Suite 3: Audio WAV/PCM 16kHz Mono Encoder" \
    "python3 -m unittest Tests/test_audio_encoder.py"

# 4. Transcript Cleanup (Russian & English Fillers, Stutter, Duplicates)
run_suite "Suite 4: Local Transcript Cleaner" \
    "python3 -m unittest Tests/test_transcript_cleaner.py"

# 5. Cloudflare Text-Only Air-Gap & Worker Regression Tests
run_suite "Suite 5: Cloudflare Security & Text-Only Air-Gap" \
    "python3 -m unittest Tests/test_cloudflare_security.py"

# 6. History Store Persistence, Serialization & Recovery
run_suite "Suite 6: Transcription History Store" \
    "python3 -m unittest Tests/test_history_store.py"

# 7. Feather Source JSON Schema Validation
run_suite "Suite 7: Feather Source JSON Schema" \
    "python3 Tests/validate_feather.py"

# 8. Optional: Swift Test Suite if swiftc/swift is available
if command -v swift >/dev/null 2>&1; then
    ((TOTAL_TESTS++))
    run_suite "Suite 8: Native Swift Test Suites (swift test)" \
        "swift test"
else
    echo -e "\n${YELLOW}Note: 'swift' toolchain not detected in environment. Skipping native Swift package tests.${NC}"
    echo -e "${YELLOW}Native Swift suites in Tests/EdgeEloquentTests/ remain ready for Xcode/macOS CI.${NC}"
fi

# Summary Report
print_header "Test Summary Report"
echo -e "Total Suites:  ${TOTAL_TESTS}"
echo -e "Passed:        ${GREEN}${BOLD}${PASSED_COUNT}${NC}"
echo -e "Failed:        ${RED}${BOLD}${FAILED_COUNT}${NC}"

if [ "${FAILED_COUNT}" -eq 0 ]; then
    echo -e "\n${GREEN}${BOLD}ALL TEST SUITES PASSED SUCCESSFULLY!${NC}\n"
    exit 0
else
    echo -e "\n${RED}${BOLD}SOME TEST SUITES FAILED. PLEASE REVIEW LOGS ABOVE.${NC}\n"
    exit 1
fi
