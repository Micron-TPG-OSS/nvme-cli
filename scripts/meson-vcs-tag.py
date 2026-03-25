#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later

import os
import subprocess
import sys


def main():
    if len(sys.argv) < 3:
        return 1

    srcdir = sys.argv[1]
    fallback = sys.argv[2]

    # Match existing behavior: only use git describe when this tree itself
    # is a git checkout or worktree.
    if not os.path.exists(os.path.join(srcdir, ".git")):
        print(fallback, end="")
        return 0

    try:
        res = subprocess.run(
            ["git", "describe", "--abbrev=7", "--dirty=+"],
            cwd=srcdir,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        print(fallback, end="")
        return 0

    if res.returncode == 0:
        out = res.stdout.strip()
        if out:
            if out.startswith("v"):
                out = out[1:]
            print(out, end="")
            return 0

    print(fallback, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())