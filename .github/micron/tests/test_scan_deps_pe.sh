#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Exercise scan_deps_pe.sh against known-good and known-bad import tables.
#
# WHY THIS EXISTS
# The check it tests used to be inline YAML inside micron-release.yml, which meant
# its denylist ran exactly once per release, against one input, in a context where
# the only observable outcome was "the release went out". A regex that has never
# been observed to fail is a regex nobody has tested: the failing branch is the
# one that matters, and it had never executed.
#
# The import lists below are real. The clean ones are what nvme.exe actually
# imports on each architecture; the dirty one is the leak this gate exists to
# catch.
#
# Usage: .github/micron/tests/test_scan_deps_pe.sh
# Exit:  0 all cases behaved as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$HERE/../scan_deps_pe.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$SCAN" ] || { echo "not found: $SCAN" >&2; exit 1; }

PASS=0
FAIL=0

# check <name> <expected-exit> <<< imports
check() {
    local name="$1" want="$2" file="$WORK/$1.txt" got
    cat > "$file"
    "$SCAN" --imports-from "$file" >"$WORK/$1.log" 2>&1
    got=$?
    if [ "$got" -eq "$want" ]; then
        printf 'ok    %-34s exit=%s\n' "$name" "$got"
        PASS=$((PASS + 1))
    else
        printf 'FAIL  %-34s exit=%s, expected %s\n' "$name" "$got" "$want"
        sed 's/^/        /' "$WORK/$1.log"
        FAIL=$((FAIL + 1))
    fi
}

# --- clean: what a correctly linked nvme.exe imports -------------------------
# Every one of these is an in-box Windows DLL. ws2_32 is here because nvme-cli
# speaks NVMe-oF over TCP: a networking import is correct behaviour for this
# tool, and a gate copied from mld or mldcli would reject this binary.
check self-contained-x64 0 <<'EOF'
ADVAPI32.dll
KERNEL32.dll
msvcrt.dll
SETUPAPI.dll
ucrtbase.dll
WS2_32.dll
EOF

check self-contained-arm64 0 <<'EOF'
api-ms-win-crt-heap-l1-1-0.dll
api-ms-win-crt-runtime-l1-1-0.dll
api-ms-win-crt-stdio-l1-1-0.dll
KERNEL32.dll
ucrtbase.dll
EOF

# --- dirty: each denied runtime, one at a time -------------------------------
# libwinpthread is the usual single leak, and the reason this check was written.
check leak-libwinpthread 1 <<'EOF'
KERNEL32.dll
libwinpthread-1.dll
msvcrt.dll
EOF

check leak-libjson-c 1 <<'EOF'
KERNEL32.dll
libjson-c-5.dll
EOF

check leak-libgcc 1 <<'EOF'
KERNEL32.dll
libgcc_s_seh-1.dll
EOF

check leak-libstdc++ 1 <<'EOF'
KERNEL32.dll
libstdc++-6.dll
EOF

check leak-libunwind 1 <<'EOF'
KERNEL32.dll
libunwind.dll
EOF

check leak-libnvme 1 <<'EOF'
KERNEL32.dll
libnvme-1.dll
EOF

check leak-msys 1 <<'EOF'
KERNEL32.dll
msys-2.0.dll
EOF

# Case-insensitive: PE import names are not case-normalised, and a toolchain that
# emits LIBWINPTHREAD-1.DLL must not slip past.
check leak-uppercase 1 <<'EOF'
KERNEL32.dll
LIBWINPTHREAD-1.DLL
EOF

# --- must NOT fire ------------------------------------------------------------
# vcruntime140 is an MSVC redistributable and a real problem for an MSVC build,
# but this is a MinGW toolchain and it cannot appear. Asserted so that anyone
# adding it later has to add it deliberately.
check msvc-runtime-not-in-scope 0 <<'EOF'
KERNEL32.dll
vcruntime140.dll
EOF

# ucrtbase and the CRT api-sets are in-box Windows. A port of this gate that
# treats any CRT import as a redistributable leak fails on every correct build.
check ucrt-is-not-a-violation 0 <<'EOF'
api-ms-win-crt-math-l1-1-0.dll
ucrtbase.dll
EOF

# --- fail closed --------------------------------------------------------------
# An empty import table must not read as "no bad imports". Exit 2, not 1: nothing
# was checked, which is a different statement from "checked and clean". Every
# Windows executable imports at least KERNEL32, so an empty list means the
# extraction was truncated. This case failed on the first run of this suite --
# the script checked for it when extracting imports itself and not when handed
# them, so the --imports-from path reported PASS on nothing.
check empty-import-list 2 <<'EOF'
EOF

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

# Setup errors are exit 2, distinct from a violation. Checked separately because
# they take arguments rather than stdin.
#
# Run under `timeout` because the failure mode being tested is not only a wrong
# exit code: an option whose value is missing used to spin in the argument loop
# forever, because "shift 2" with one argument left fails without shifting. A
# hung job is the one failure a test suite cannot report, so bound it.
setup_case() {
    local name="$1"; shift
    timeout 20 "$SCAN" "$@" >/dev/null 2>&1
    local got=$?
    if [ "$got" -eq 2 ]; then
        printf 'ok    %-34s exit=2\n' "$name"
    else
        printf 'FAIL  %-34s exit=%s, expected 2%s\n' "$name" "$got" \
            "$([ "$got" -eq 124 ] && echo ' (timed out -- argument loop did not terminate)')"
        exit 1
    fi
}
setup_case no-arguments
setup_case missing-binary            "$WORK/does-not-exist.exe"
setup_case missing-imports-file      --imports-from "$WORK/nope.txt"
setup_case both-inputs               --imports-from /dev/null some.exe
setup_case unknown-option            --nonsense
setup_case imports-from-without-value --imports-from
setup_case out-without-value          --out

# --out has to produce the list the release's Report step puts in the step
# summary, and has to produce it on a failing run too: the run where the gate
# fired is the run somebody needs the import list from.
printf 'KERNEL32.dll\nlibwinpthread-1.dll\n' > "$WORK/dirty.txt"
"$SCAN" --imports-from "$WORK/dirty.txt" --out "$WORK/written.txt" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 1 ] && diff -q "$WORK/dirty.txt" "$WORK/written.txt" >/dev/null; then
    printf 'ok    %-34s exit=1, list written\n' "out-on-failing-run"
else
    printf 'FAIL  %-34s exit=%s\n' "out-on-failing-run" "$rc"
    exit 1
fi

echo
echo "all cases behaved as expected"
