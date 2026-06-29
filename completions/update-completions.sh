#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# update-completions.sh - Regenerate the committed shell completion files.
#
# Invoked via:
#   meson compile -C <build-dir> update-completions   (developer, updates files)
#
# With -Dcheck-completions=true the meson target runs this in --check (CI)
# mode: read-only, exits non-zero if any committed completion file is stale.
#
# It is NOT run during a normal build. The completion files are pre-generated
# and committed to the source tree.
#
# Arguments (supplied by the Meson run_target):
#   $1            path to the freshly built nvme binary
#   $2            path to the python3 interpreter
#   $3            path to generate-completions.py
#   $4            output bash completion file
#   $5            output zsh completion file
#   $6            output powershell completion file
#   [--check]     optional: CI mode; read-only, exit non-zero on drift

set -euo pipefail

NVME="${1:?missing nvme binary}"
PYTHON="${2:?missing python3 interpreter}"
GENERATOR="${3:?missing generator script}"
BASH_OUT="${4:?missing bash output path}"
ZSH_OUT="${5:?missing zsh output path}"
PS_OUT="${6:?missing powershell output path}"
shift 6

CHECK_MODE=0
if [ "${1-}" = "--check" ]; then
    CHECK_MODE=1
fi

TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

MODEL="$TMPDIR_WORK/model.json"
TMP_BASH="$TMPDIR_WORK/bash"
TMP_ZSH="$TMPDIR_WORK/zsh"
TMP_PS="$TMPDIR_WORK/ps"

echo "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
echo "--- completions: begin generation ---"

# Capture the command/option model from the compiled binary, then format it.
"$NVME" dump-command-metadata > "$MODEL"
"$PYTHON" "$GENERATOR" "$MODEL" \
    --bash "$TMP_BASH" --zsh "$TMP_ZSH" --powershell "$TMP_PS"

update_if_changed() {
    local src="$1" dest="$2"

    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        printf "  unchanged: %s\n" "$(basename "$dest")"
    else
        cp "$src" "$dest"
        printf "  updated:   %s\n" "$(basename "$dest")"
        CHANGED=$((CHANGED + 1))
    fi
}

check_if_current() {
    local src="$1" dest="$2"

    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        printf "  up to date: %s\n" "$(basename "$dest")"
    else
        printf "  STALE:      %s\n" "$(basename "$dest")"
        DRIFT=$((DRIFT + 1))
    fi
}

if [ "$CHECK_MODE" -eq 1 ]; then
    DRIFT=0
    check_if_current "$TMP_BASH" "$BASH_OUT"
    check_if_current "$TMP_ZSH" "$ZSH_OUT"
    check_if_current "$TMP_PS" "$PS_OUT"
    if [ "$DRIFT" -gt 0 ]; then
        echo "ERROR: completion files are out of sync with the source."
        echo "Run 'meson compile -C <build-dir> update-completions' and commit."
        echo "--- completions: check FAILED ---"
        echo "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
        exit 1
    fi
    echo "All completion files are up to date."
else
    CHANGED=0
    update_if_changed "$TMP_BASH" "$BASH_OUT"
    update_if_changed "$TMP_ZSH" "$ZSH_OUT"
    update_if_changed "$TMP_PS" "$PS_OUT"
    if [ "$CHANGED" -gt 0 ]; then
        printf "%d completion file(s) updated. Don't forget to commit.\n" "$CHANGED"
    else
        echo "All completion files are up to date."
    fi
fi

echo "--- completions: generation complete ---"
echo "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
