<!-- SPDX-License-Identifier: GPL-2.0-or-later -->

# Micron CI helpers

This directory holds the scripts that Micron's own workflows call, on top of
upstream `linux-nvme/nvme-cli`.

```
.github/micron/
├── README.md
└── sharepoint-publish.py                       # called by the sharepoint job
```

## Why the files live where they do

The upstream sync (`micron-sync-and-merge.yml`) is a plain `git merge` of
`linux-nvme/nvme-cli` master into this fork. Files introduced only in this fork
have no upstream-side change to merge, so a sync leaves them untouched. That
covers this directory and the Micron workflows in `.github/workflows/` too:
`micron-release.yml` and `micron-sync-and-merge.yml` are Micron-only names, so
they are edited in place like any other file.

Keep Micron-only files under Micron-only names. A file that shares a name with
an upstream file is the one case that can conflict on a sync.

## What carries a Micron delta on an upstream file

**`build.yml`, `check-accessors.yml`.** On `mingw` these carry a
one-line Micron change (adding `mingw` to the CI branch triggers). Git merges
upstream changes around that line, so it survives a sync unless upstream edits
the same trigger list, in which case the `mingw` merge fails and needs resolving
by hand. Do not replace these with whole-file Micron copies: that would pin them
at a Micron snapshot and silently discard future upstream CI improvements.
