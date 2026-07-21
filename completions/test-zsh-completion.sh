#!/bin/zsh
# Test harness for zsh completion
# Simulates the completion environment to test _nvme completions

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counter
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Initialize zsh completion system
autoload -Uz compinit
compinit -u 2>/dev/null

# Source the completion file
source "$(dirname "$0")/_nvme"

# Capture completions by overriding completion functions
typeset -a captured_completions

# Override _values to capture what would be completed
_values() {
    shift  # skip the first empty string argument
    captured_completions=("$@")
}

# Override _describe to capture completions
_describe() {
    local tag=$2
    local varname=$3
    # Get the array contents
    captured_completions=(${(P)varname})
}

# Override _files to indicate file completion was requested
_files() {
    captured_completions=("__FILES__")
}

# Override _arguments to shift words like the real one does
# The real _arguments '*:: :->subcmds' shifts words and adjusts CURRENT
_arguments() {
    # Simulate the shift that _arguments does
    if [[ $# -gt 0 ]] && [[ "$1" == "*:: :->subcmds" ]]; then
        # Shift words array (remove first element - the command name)
        words=("${words[@]:1}")
        ((CURRENT--))
    fi
    return 1  # Return non-zero so _nvme continues processing
}

# Simulate completion and return results
simulate_completion() {
    local cmdline="$1"

    # Reset captured completions
    captured_completions=()

    # Parse command line into words array (zsh arrays are 1-indexed)
    # Use (z) flag to split like the shell would
    words=("${(z)cmdline}")

    # If the command ends with a space, we're completing a new word
    if [[ "$cmdline" == *" " ]]; then
        words+=("")
    fi

    CURRENT=${#words}

    echo "  DEBUG: words=(${words[*]})"
    echo "  DEBUG: CURRENT=$CURRENT, words[CURRENT-1]='${words[CURRENT-1]}'"

    # Call the completion function
    _nvme

    echo "  DEBUG: captured=(${captured_completions[*]})"
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

    local result="${captured_completions[*]}"

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
echo "Zsh Completion Test Harness"
echo "========================================"

# Test cases for value completion (matching bash tests)

# Long options with = form
test_completion \
    "--output-format=<TAB> should show values" \
    "nvme feat power-meas --output-format=" \
    "normal.*json.*binary.*tabular"

test_completion \
    "--output-format=j<TAB> should complete to json" \
    "nvme feat power-meas --output-format=j" \
    "normal.*json.*binary.*tabular"

test_completion \
    "--sel=<TAB> should show 0 1 2 3" \
    "nvme feat power-meas --sel=" \
    "0.*1.*2.*3"

# Long options with space form
test_completion \
    "--output-format <TAB> (space) should show values" \
    "nvme feat power-meas --output-format " \
    "normal.*json.*binary.*tabular"

test_completion \
    "--output-format j<TAB> should complete to json" \
    "nvme feat power-meas --output-format j" \
    "normal.*json.*binary.*tabular"

test_completion \
    "--sel <TAB> should show 0 1 2 3" \
    "nvme feat power-meas --sel " \
    "0.*1.*2.*3"

# Short options
test_completion \
    "-o <TAB> should show output format values" \
    "nvme feat power-meas -o " \
    "normal.*json.*binary.*tabular"

test_completion \
    "-o j<TAB> should complete to json" \
    "nvme feat power-meas -o j" \
    "normal.*json.*binary.*tabular"

test_completion \
    "-S <TAB> should show sel values 0 1 2 3" \
    "nvme feat power-meas -S " \
    "0.*1.*2.*3"

# Command-specific options
test_completion \
    "--act <TAB> for power-meas should show 0 1" \
    "nvme feat power-meas --act " \
    "0.*1"

test_completion \
    "--act=<TAB> for power-meas should show 0 1" \
    "nvme feat power-meas --act=" \
    "0.*1"

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
