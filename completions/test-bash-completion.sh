#!/bin/bash
# Test harness for bash completion
# Simulates the completion environment to test plugin_feat_opts

# Source the completion file
source "$(dirname "$0")/bash-nvme-completion.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counter
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Simulate completion and return COMPREPLY
simulate_completion() {
    local cmdline="$1"

    # Reset COMPREPLY
    COMPREPLY=()

    # Split command line into words (respecting = as word break like bash does)
    # This simulates COMP_WORDBREAKS containing =
    local IFS=$' \t\n='
    read -ra words <<< "$cmdline"

    # Reconstruct with = as separate words
    local new_words=()
    for word in "${words[@]}"; do
        new_words+=("$word")
    done
    words=("${new_words[@]}")

    # Actually, let's be more precise about = splitting
    # Reset and parse more carefully
    words=()
    local current_word=""
    local char
    for (( i=0; i<${#cmdline}; i++ )); do
        char="${cmdline:$i:1}"
        if [[ "$char" == "=" ]]; then
            [[ -n "$current_word" ]] && words+=("$current_word")
            words+=("=")
            current_word=""
        elif [[ "$char" == " " || "$char" == $'\t' ]]; then
            [[ -n "$current_word" ]] && words+=("$current_word")
            current_word=""
        else
            current_word+="$char"
        fi
    done
    [[ -n "$current_word" ]] && words+=("$current_word")

    # Add empty word if cmdline ends with space or =
    if [[ "$cmdline" == *" " ]] || [[ "$cmdline" == *"=" ]]; then
        words+=("")
    fi

    local cword=$(( ${#words[@]} - 1 ))
    local cur="${words[$cword]}"
    local prev="${words[$cword-1]:-}"

    echo "  DEBUG: words=(${words[*]})"
    echo "  DEBUG: cword=$cword, cur='$cur', prev='$prev'"

    # Call _init_completion equivalent (set up variables)
    # We're simulating what _init_completion does

    # Now call the function we want to test
    # For feat plugin, we need to call plugin_feat_opts with subcommand
    if [[ ${words[1]} == "feat" ]] && [[ ${#words[@]} -ge 3 ]]; then
        plugin_feat_opts "${words[2]}" "$prev"
    fi

    echo "  DEBUG: COMPREPLY=(${COMPREPLY[*]})"
}

# Test function
test_completion() {
    local description="$1"
    local cmdline="$2"
    local expected_pattern="$3"

    TESTS_RUN=$((TESTS_RUN + 1))

    echo ""
    echo "TEST $TESTS_RUN: $description"
    echo "  Command: '$cmdline<TAB>'"

    simulate_completion "$cmdline"

    local result="${COMPREPLY[*]}"

    if [[ "$result" =~ $expected_pattern ]]; then
        echo -e "  ${GREEN}PASS${NC}: Got '$result'"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC}: Expected pattern '$expected_pattern'"
        echo -e "  ${RED}FAIL${NC}: Got '$result'"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

echo "========================================"
echo "Bash Completion Test Harness"
echo "========================================"

# Test cases for value completion
test_completion \
    "--output-format=<TAB> should show values" \
    "nvme feat power-meas --output-format=" \
    "normal.*json.*binary.*tabular"

test_completion \
    "--output-format <TAB> (space) should show values" \
    "nvme feat power-meas --output-format " \
    "normal.*json.*binary.*tabular"

test_completion \
    "--output-format j<TAB> should complete to json" \
    "nvme feat power-meas --output-format j" \
    "json"

test_completion \
    "--output-format=j<TAB> should complete to json" \
    "nvme feat power-meas --output-format=j" \
    "json"

test_completion \
    "--sel=<TAB> should show 0 1 2 3" \
    "nvme feat power-meas --sel=" \
    "0.*1.*2.*3"

test_completion \
    "--sel <TAB> should show 0 1 2 3" \
    "nvme feat power-meas --sel " \
    "0.*1.*2.*3"

# Test that options complete properly (not values)
test_completion \
    "--output-f<TAB> should complete option, not show values" \
    "nvme feat power-meas --output-f" \
    "--output-format"

# Test edge case: = is the current word (no trailing empty string)
# This happens depending on how bash splits COMP_WORDS
test_completion_direct() {
    local description="$1"
    shift
    local -a input_words=("$@")

    TESTS_RUN=$((TESTS_RUN + 1))

    echo ""
    echo "TEST $TESTS_RUN: $description"

    # Directly set up variables as bash would
    words=("${input_words[@]}")
    cword=$((${#words[@]} - 1))
    cur="${words[$cword]}"
    prev="${words[$cword-1]:-}"

    echo "  words=(${words[*]})"
    echo "  cword=$cword, cur='$cur', prev='$prev'"

    COMPREPLY=()
    plugin_feat_opts "${words[2]}" "$prev"

    local result="${COMPREPLY[*]}"
    echo "  COMPREPLY=(${COMPREPLY[*]})"

    if [[ ${#COMPREPLY[@]} -gt 0 ]]; then
        echo -e "  ${GREEN}PASS${NC}: Got completions"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC}: COMPREPLY was empty (would fall back to file completion)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

test_completion_direct \
    "--output-format= edge case: cur='=' should show values" \
    nvme feat power-meas --output-format =

# Short option tests
test_completion \
    "-o <TAB> should show output format values" \
    "nvme feat power-meas -o " \
    "normal.*json.*binary.*tabular"

test_completion \
    "-o j<TAB> should complete to json" \
    "nvme feat power-meas -o j" \
    "json"

test_completion \
    "-S <TAB> should show sel values 0 1 2 3" \
    "nvme feat power-meas -S " \
    "0.*1.*2.*3"

echo ""
echo "========================================"
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "${RED}$TESTS_FAILED tests failed${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed${NC}"
    exit 0
fi
