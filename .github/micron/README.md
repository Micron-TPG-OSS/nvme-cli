<!-- SPDX-License-Identifier: GPL-2.0-or-later -->

# Micron `.github` overlay

This directory is the source of truth for the CI that Micron adds on top of
upstream `linux-nvme/nvme-cli`.

```
.github/micron/
├── README.md
├── apply.sh                                    # projects the overlay onto the tree
├── sharepoint-publish.py                       # called by the sharepoint job
└── overlay/                                    # mirrors the repository root
    └── .github/workflows/micron-release.yml    # source of truth
```

`apply.sh` copies every file under `overlay/` to the matching path at the
repository root. `micron-sync-and-merge.yml` runs it after every upstream sync,
on both `master` and `mingw`, and commits the result if anything changed. So the
cycle is: sync merges upstream freely, the overlay is re-applied on top, and
Micron-owned CI files always end up at their intended contents.

## Working on an overlay-managed file

Edit the copy under `overlay/`, then project it:

```bash
.github/micron/apply.sh
```

Commit both the overlay file and the projected copy. Editing the projected copy
directly does not survive: the next sync reverts it.

```bash
.github/micron/apply.sh --list     # what the overlay owns
.github/micron/apply.sh --check    # fail if the tree has drifted
```

## Why both copies are committed

GitHub only runs workflows that physically exist in `.github/workflows/`, so the
projected copy has to be committed — the overlay copy alone is inert. That means
the file's content is stored twice, which is the deliberate cost of the pattern.
`apply.sh --check` exists so the two can never silently disagree; wire it into a
PR check if you want that enforced.

`sharepoint-publish.py` sits here rather than under `overlay/` for the same
reason `micron-sync-and-merge.yml` does: `.github/micron/` is a path upstream
does not have, so an upstream sync can never overwrite it and there is nothing
for the overlay to protect. Only files that share a directory with
upstream-owned files need projecting.

## What is deliberately *not* here

**`micron-sync-and-merge.yml`.** It is the workflow that runs `apply.sh`, and an
overlay that can rewrite its own applier can break the very mechanism that would
fix it. It is also a Micron-only addition that upstream never touches, so it
gains nothing from being managed. Edit it in place.

**`build.yml`, `codeql.yml`, `check-accessors.yml`.** On `mingw` these carry a
one-line Micron change (adding `mingw` to the CI branch triggers). They are
*not* overlay-managed, because projecting a whole-file copy of an actively
developed 13 KB upstream file would pin it at a Micron snapshot and silently
discard future upstream CI improvements. If those trigger edits ever need to
survive syncs automatically, add a transform step to `apply.sh` that rewrites
the trigger lists, rather than adding the files to `overlay/`.
