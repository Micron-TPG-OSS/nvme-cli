#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# This file is part of nvme.
# Copyright (c) 2026 Micron Technology, Inc.
#
# Apply the Micron .github overlay onto the working tree.
#
# Everything under .github/micron/overlay/ mirrors a path at the repository
# root. Applying the overlay copies each of those files into place, overwriting
# whatever is there. That is the point: upstream syncs merge freely, and the
# overlay is re-applied afterwards, so Micron-owned CI files always come back to
# their intended contents without needing a merge resolution.
#
# The overlay only ever *writes* files. It never deletes anything, so it cannot
# remove an upstream file that Micron does not own.
#
# Note: micron-sync-and-merge.yml is deliberately NOT in the overlay. It is the
# workflow that runs this script, and letting the overlay rewrite its own
# applier means a bad overlay could break the mechanism that fixes it. It is a
# Micron-only addition, so upstream merges never touch it anyway.
#
# Usage:
#   apply.sh            apply the overlay to the working tree
#   apply.sh --list     print the paths the overlay owns, one per line
#   apply.sh --check    exit non-zero if the tree differs from the overlay
#                       (use in CI to catch edits made to a projected copy)

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

OVERLAY_ROOT=".github/micron/overlay"

if [ ! -d "${OVERLAY_ROOT}" ]; then
    echo "error: ${OVERLAY_ROOT} not found" >&2
    exit 1
fi

# The owned-path list is derived from the overlay tree itself rather than
# kept in a separate manifest, so it cannot drift out of date.
list_paths() {
    find "${OVERLAY_ROOT}" -type f -print \
        | sed "s|^${OVERLAY_ROOT}/||" \
        | LC_ALL=C sort
}

MODE="apply"
case "${1:-}" in
    --list)  MODE="list" ;;
    --check) MODE="check" ;;
    "")      MODE="apply" ;;
    *)
        echo "error: unknown argument '$1'" >&2
        sed -n '/^# Usage:/,/^$/p' "$0" >&2
        exit 1
        ;;
esac

if [ "${MODE}" = "list" ]; then
    list_paths
    exit 0
fi

if [ -z "$(list_paths)" ]; then
    echo "error: overlay is empty; refusing to run" >&2
    exit 1
fi

changed=0
missing=0

while IFS= read -r rel; do
    src="${OVERLAY_ROOT}/${rel}"

    if [ "${MODE}" = "check" ]; then
        if [ ! -f "${rel}" ]; then
            echo "MISSING  ${rel}"
            missing=$((missing + 1))
        elif ! cmp -s "${src}" "${rel}"; then
            echo "DIFFERS  ${rel}"
            diff -u "${rel}" "${src}" || true
            changed=$((changed + 1))
        else
            echo "ok       ${rel}"
        fi
        continue
    fi

    mkdir -p "$(dirname "${rel}")"
    if [ -f "${rel}" ] && cmp -s "${src}" "${rel}"; then
        echo "unchanged ${rel}"
    else
        cp "${src}" "${rel}"
        echo "applied   ${rel}"
        changed=$((changed + 1))
    fi
done < <(list_paths)

if [ "${MODE}" = "check" ]; then
    if [ $((changed + missing)) -ne 0 ]; then
        echo ""
        echo "error: working tree does not match the overlay" >&2
        echo "       ${changed} file(s) differ, ${missing} missing" >&2
        echo "       edit the copy under .github/micron/overlay/ and" >&2
        echo "       re-run .github/micron/apply.sh" >&2
        exit 1
    fi
    echo ""
    echo "working tree matches the overlay"
    exit 0
fi

echo ""
echo "overlay applied (${changed} file(s) written)"
