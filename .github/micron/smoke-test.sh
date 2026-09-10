#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Sanity-run a freshly built nvme binary.
#
# Every check here runs without an NVMe device and without root, so it is safe
# on any CI runner. It answers the one question a compile and a link cannot:
# does this executable actually start, dispatch a sub-command, format output,
# and report failure when it fails?
#
# Called by micron-release.yml, so that the binaries this fork hosts are known
# to run before they are published. The unit tests there exercise library code,
# and the import-table check proves nvme.exe pulls in no MinGW runtime DLLs --
# but a binary can pass both and still die on startup.
#
# It lives here rather than in scripts/ for the same reason
# sharepoint-publish.py does: it is a Micron-only helper for a Micron-only
# workflow, and .github/micron/ is a path upstream does not have, so a sync can
# never touch it. Nothing stops you running it against a local build by hand.
#
# This file is part of nvme.
# Copyright (c) 2026 Micron Technology, Inc.

set -u

usage() {
    echo "Usage: smoke-test.sh [--expect-version VERSION] <path-to-nvme>"
    echo ""
    echo "Run no-device sanity checks against a built nvme binary."
    echo ""
    echo " --expect-version VERSION  also require 'nvme version' to report VERSION"
}

NVME=""
EXPECT_VERSION=""

while [ $# -gt 0 ]; do
    case "$1" in
    --expect-version)
        if [ $# -lt 2 ]; then
            echo "error: --expect-version needs an argument" >&2
            exit 1
        fi
        EXPECT_VERSION="$2"
        shift 2
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    -*)
        echo "error: unknown option '$1'" >&2
        usage >&2
        exit 1
        ;;
    *)
        if [ -n "${NVME}" ]; then
            echo "error: unexpected argument '$1'" >&2
            exit 1
        fi
        NVME="$1"
        shift
        ;;
    esac
done

if [ -z "${NVME}" ]; then
    echo "error: no nvme binary given" >&2
    usage >&2
    exit 1
fi

if [ ! -x "${NVME}" ]; then
    echo "error: ${NVME} is not an executable file" >&2
    exit 1
fi

PASS=0
FAIL=0
SKIP=0
OUT=""

# Capture combined output in OUT and return the binary's exit status.
run() {
    OUT="$("${NVME}" "$@" 2>&1)"
}

pass() {
    PASS=$((PASS + 1))
    printf 'ok    %s\n' "$1"
}

skip() {
    SKIP=$((SKIP + 1))
    printf 'skip  %s (%s)\n' "$1" "$2"
}

fail() {
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s: %s\n' "$1" "$2"
    printf '%s\n' "${OUT}" | sed -n '1,15p' | sed 's/^/      | /'
}

# check <name> <0|nonzero> <required substring, or - for none> -- <nvme args...>
check() {
    local name="$1" expect="$2" needle="$3" rc
    shift 3
    [ "${1:-}" = "--" ] && shift

    run "$@"
    rc=$?

    case "${expect}" in
    0)
        if [ "${rc}" -ne 0 ]; then
            fail "${name}" "exited ${rc}, expected 0"
            return
        fi
        ;;
    nonzero)
        # A CLI that returns success on a rejected command breaks every
        # script that checks $?, so assert the failure paths too.
        if [ "${rc}" -eq 0 ]; then
            fail "${name}" "exited 0, expected a failure status"
            return
        fi
        ;;
    esac

    if [ "${needle}" != "-" ] && ! printf '%s' "${OUT}" | grep -qF -- "${needle}"; then
        fail "${name}" "output does not contain '${needle}'"
        return
    fi

    pass "${name}"
}

printf 'Sanity-running %s\n\n' "${NVME}"

check 'version reports a version'          0       'nvme version'        -- version
if [ -n "${EXPECT_VERSION}" ]; then
    check "version reports ${EXPECT_VERSION}" \
                                           0       "nvme version ${EXPECT_VERSION}" -- version
fi
check 'help lists sub-commands'            0       'usage: nvme'         -- help
check 'list runs with no device present'   0       '-'                   -- list
check 'list -o json emits Devices'         0       '"Devices"'           -- list -o json
check 'unknown sub-command fails'          nonzero 'Invalid sub-command' -- not-a-sub-command
check 'missing device argument fails'      nonzero '-'                   -- id ctrl

# "nvme list -o json" is what other tooling consumes, so a truncated or
# double-encoded document is a real defect rather than a cosmetic one. Only
# checkable where a Python is on PATH; the substring check above stands in
# otherwise.
PYTHON="$(command -v python3 || command -v python || true)"
if [ -n "${PYTHON}" ]; then
    run list -o json
    if printf '%s' "${OUT}" | "${PYTHON}" -c 'import json, sys; json.load(sys.stdin)'; then
        pass 'list -o json parses as JSON'
    else
        fail 'list -o json parses as JSON' 'the document was rejected by json.load'
    fi
else
    skip 'list -o json parses as JSON' 'no python on PATH'
fi

# Plugin dispatch is a second entry point into the command tables and worth
# exercising, but which plugins are compiled in is a build option -- so only
# require the ones this binary says it has.
run help
HELP="${OUT}"
for plugin in micron ocp; do
    if printf '%s' "${HELP}" | grep -qE "^  ${plugin} "; then
        check "${plugin} plugin dispatches" 0 "usage: nvme ${plugin}" -- "${plugin}" help
    else
        skip "${plugin} plugin dispatches" 'not built in'
    fi
done

printf '\n%d passed, %d failed, %d skipped\n' "${PASS}" "${FAIL}" "${SKIP}"
[ "${FAIL}" -eq 0 ] || exit 1
