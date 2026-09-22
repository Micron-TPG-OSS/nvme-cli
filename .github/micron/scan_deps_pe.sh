#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Fail if a Windows nvme.exe imports a MinGW/MSYS2 runtime DLL.
#
# WHAT THIS PROTECTS
# The Windows release is a single .exe in a zip. There is no installer to carry a
# dependency and no runtime check, so a binary that imports libwinpthread-1.dll
# does not start on the recipient's machine and there is nothing we can do about
# it after the zip has been sent. meson's --default-library=static is what links
# json-c and libwinpthread in-process; this asserts that it worked, by reading
# the import table of the artifact rather than trusting the build flags.
#
# WHY THE IMPORT TABLE AND NOT ldd
# ldd resolves paths through the MSYS2 runtime, which is x86_64 even on
# windows-11-arm, so it cannot be relied on for the aarch64 binary. Import names
# are host-independent. binutils ships objdump, the clang toolchain ships
# llvm-objdump; both print "DLL Name:" lines for PE files.
#
# WHY THERE IS NO NETWORK GATE HERE
# The sibling tools mld and mldcli gate on importing any networking DLL, because
# they read a customer's logs off a customer's drive and must be unable to
# transmit them. Do not copy that gate here. nvme-cli speaks NVMe-oF over TCP, so
# importing ws2_32.dll is correct behaviour, and a gate that fires on a working
# build is one that gets switched off. Adapt a gate to the tool or do not adopt
# it.
#
# Usage:
#   scan_deps_pe.sh <nvme.exe>              read the imports from a PE binary
#   scan_deps_pe.sh --imports-from <file>   check an already-extracted list,
#                                           one DLL name per line
#   scan_deps_pe.sh --out <file> ...        also write the import list there,
#                                           one DLL name per line, whether the
#                                           check passes or fails
#
# Exit: 0 clean, 1 violations found, 2 usage or setup error.
#
# The two exits are kept apart deliberately. "I could not read the import table"
# and "the import table is clean" must never produce the same answer: the second
# is a claim about the binary and the first is a claim about the runner, and a
# check that reports a pass on a binary nobody looked at is worse than no check,
# because it also produces a record saying the binary was checked.

set -uo pipefail

# Runtime DLLs that must not appear. Left-anchored, because these are whole
# filenames from a PE import table and not a substring search: anchoring stops
# "libnvme" from matching a hypothetical system DLL with the string inside it,
# and keeps each entry readable as the file it names.
#
#   libjson-c        json-c, when --default-library=static did not take
#   libwinpthread    the pthreads shim; the usual single leak
#   libgcc_s         GCC unwinder / support runtime
#   libstdc++        C++ standard library (gcc)
#   libc++           C++ standard library (clang)
#   libunwind        clang unwinder, the ARM64 counterpart of libgcc_s
#   libatomic        libatomic, pulled in by 64-bit atomics on some toolchains
#   libssp           stack-protector runtime
#   libnvme          our own library, when it did not link statically
#   msys-            anything from the MSYS2 emulation layer
#
# ucrtbase.dll, the api-ms-win-crt-* api-sets and every other Windows system DLL
# are NOT violations. They are in-box Windows components, not something the
# recipient installs. The same distinction has to be made in any port of this
# check: mld's version of this gate treats vcruntime140.dll as a leak and
# ucrtbase.dll as correct, for exactly this reason.
DENY='^(libjson-c|libwinpthread|libgcc_s|libstdc\+\+|libc\+\+|libunwind|libatomic|libssp|libnvme|msys-)'

# Matched on the text rather than on line numbers, so that editing the comment
# above does not silently truncate the help.
usage() { sed -n '/^# Usage:/,/^# Exit:/p' "$0"; }

# An option missing its value exits rather than shifting: "shift 2" with one
# argument left fails without shifting, and this loop would then spin on the same
# argument forever. A CI job that hangs for six hours is a worse failure than one
# that prints a usage error.
need_value() {
    [ -n "${2:-}" ] || { echo "$1 needs a value" >&2; exit 2; }
}

IMPORTS_FROM=""
BINARY=""
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --imports-from) need_value "$1" "${2:-}"; IMPORTS_FROM="$2"; shift 2 ;;
        --out)          need_value "$1" "${2:-}"; OUT="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        -*)             echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)              BINARY="$1"; shift ;;
    esac
done

TMP=""
cleanup() { [ -n "$TMP" ] && rm -f "$TMP"; }
trap cleanup EXIT

if [ -n "$IMPORTS_FROM" ]; then
    # Test and diagnostic path: check a list somebody already extracted. Keeps
    # the denylist testable without a PE binary or a Windows runner, which is the
    # only way the regex above ever gets exercised against a known-bad input.
    [ -n "$BINARY" ] && { echo "pass either a binary or --imports-from, not both" >&2; exit 2; }
    [ -f "$IMPORTS_FROM" ] || { echo "no such file: $IMPORTS_FROM" >&2; exit 2; }
    # Checked on this path too, not only when extracting. Every Windows
    # executable imports at least KERNEL32, so an empty list is never a real
    # import table -- it is a truncated extraction, and reading it as "no bad
    # imports" is the exact failure the exit-code split exists to prevent. The
    # test suite covers this because the first version of this script did not.
    if [ ! -s "$IMPORTS_FROM" ]; then
        echo "::error::$IMPORTS_FROM is empty; an import table with no DLLs in it is not a clean binary"
        exit 2
    fi
    IMPORTS="$IMPORTS_FROM"
    echo "=== imports as supplied: $IMPORTS_FROM ==="
else
    [ -n "$BINARY" ] || { usage >&2; exit 2; }
    [ -f "$BINARY" ] || { echo "no such file: $BINARY" >&2; exit 2; }

    OBJDUMP="$(command -v objdump || command -v llvm-objdump || true)"
    if [ -z "$OBJDUMP" ]; then
        echo "::error::neither objdump nor llvm-objdump found; cannot verify imports"
        exit 2
    fi

    TMP="$(mktemp)"
    IMPORTS="$TMP"
    "$OBJDUMP" -p "$BINARY" \
        | awk -F'DLL Name:' '/DLL Name:/ {gsub(/[ \t\r]/, "", $2); print $2}' \
        | sort -u > "$IMPORTS"

    # An empty list is the failure this whole script exists to avoid reporting as
    # a pass: objdump succeeding on a file it did not understand, or a PE with a
    # layout the awk did not match, both look like "no bad imports".
    if [ ! -s "$IMPORTS" ]; then
        echo "::error::could not read any DLL imports from $BINARY"
        exit 2
    fi
    echo "=== imports of $BINARY (via $(basename "$OBJDUMP")) ==="
fi

cat "$IMPORTS"
echo

# Written before the verdict, not after, so the list is on disk even when the
# check fails: the release job puts it in the step summary, and the run where the
# gate fired is the run somebody needs the list from.
if [ -n "$OUT" ]; then
    cp "$IMPORTS" "$OUT" || { echo "::error::could not write $OUT" >&2; exit 2; }
fi

HITS="$(grep -Ei "$DENY" "$IMPORTS" || true)"
if [ -n "$HITS" ]; then
    echo "VIOLATIONS: imports a MinGW/MSYS2 runtime DLL"
    printf '%s\n' "$HITS" | sed 's/^/  /'
    echo
    echo "RESULT: FAIL -- this binary needs those DLLs shipped beside it and will"
    echo "               not start on a clean Windows machine without them."
    echo "               Check that meson ran with --default-library=static, and"
    echo "               that the link args reached every target and not just"
    echo "               nvme.exe (see EXTRA_LINK_ARGS in micron-release.yml)."
    exit 1
fi

echo "RESULT: PASS -- self-contained; every import is an in-box Windows DLL."
exit 0
