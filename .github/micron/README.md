<!-- SPDX-License-Identifier: GPL-2.0-or-later -->

# Micron `.github` overlay

This directory is the source of truth for the CI that Micron adds on top of
upstream `linux-nvme/nvme-cli`.

```
.github/micron/
├── README.md
├── apply.sh                                    # projects the overlay onto the tree
├── scan_deps_pe.sh                             # gate: no MinGW runtime in nvme.exe
├── sharepoint-publish.py                       # called by the sharepoint job
├── tests/
│   └── test_scan_deps_pe.sh                    # the gate, against known-bad input
└── overlay/                                    # mirrors the repository root
    └── .github/workflows/micron-release.yml    # source of truth
```

The workflows that use all of this are `.github/workflows/micron-release.yml`
(overlay-managed), `micron-sync-and-merge.yml` and `micron-ci.yml` (both edited
in place — see [What is deliberately *not* here](#what-is-deliberately-not-here)).

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
`apply.sh --check` exists so the two can never silently disagree, and
`micron-ci.yml` runs it on every pull request that touches these paths, so the
disagreement cannot reach master. Before that check existed the two copies could
drift and the symptom was a release behaving like the copy nobody read: GitHub
runs `.github/workflows/`, reviewers read `overlay/`.

`sharepoint-publish.py` sits here rather than under `overlay/` for the same
reason `micron-sync-and-merge.yml` does: `.github/micron/` is a path upstream
does not have, so an upstream sync can never overwrite it and there is nothing
for the overlay to protect. Only files that share a directory with
upstream-owned files need projecting.

## The release gate: `scan_deps_pe.sh`

The Windows release is a single `nvme.exe` in a zip. There is no installer to
carry a dependency, so an exe that imports `libwinpthread-1.dll` does not start
on the recipient's machine and nothing can be done about it after the zip has
been sent. `scan_deps_pe.sh` reads the artifact's PE import table and fails if a
MinGW/MSYS2 runtime DLL appears — it asserts that meson's
`--default-library=static` actually took, rather than trusting the build flags.

```bash
.github/micron/scan_deps_pe.sh .build-release/nvme.exe
.github/micron/scan_deps_pe.sh --imports-from imports.txt   # check a list
.github/micron/scan_deps_pe.sh --out imports.txt nvme.exe   # and keep the list
```

Exit `0` clean, `1` a runtime leak, `2` nothing was checked. The last is the
point of the split: "I could not read the import table" and "the import table is
clean" must not produce the same answer, because a pass on a binary nobody looked
at also produces a record saying the binary was checked.

Two things are worth knowing before copying this gate anywhere:

- **It reads the import table, not `ldd`.** `ldd` resolves through the MSYS2
  runtime, which is x86_64 even on `windows-11-arm`, so it cannot be trusted for
  the aarch64 binary. Import names are host-independent.
- **There is no network gate here, and one must not be added.** The sibling tools
  `mld` and `mldcli` fail if the binary imports any networking DLL, because they
  read customer logs and must be unable to transmit them. nvme-cli speaks NVMe-oF
  over TCP: `ws2_32.dll` is correct behaviour here, and a gate that fires on a
  working build is a gate somebody switches off.

`tests/test_scan_deps_pe.sh` runs the denylist against real import tables — clean
x64 (including `WS2_32.dll`) and arm64, one case per denied runtime, an uppercase
case, `vcruntime140.dll` and `ucrtbase.dll` asserted *not* to fire, and an empty
list asserted to exit 2. It needs no Windows runner and no build. It exists
because this check used to be inline YAML in `micron-release.yml`, which meant its
denylist ran once per release against one input and its failing branch — the one
that matters — had never executed. The empty-list case failed on the suite's
first run and found a real hole.

## What is deliberately *not* here

**`micron-sync-and-merge.yml`.** It is the workflow that runs `apply.sh`, and an
overlay that can rewrite its own applier can break the very mechanism that would
fix it. It is also a Micron-only addition that upstream never touches, so it
gains nothing from being managed. Edit it in place.

**`micron-ci.yml`.** Same two reasons: it runs `apply.sh --check`, so an overlay
able to rewrite it could disable the check that would have caught the breakage,
and upstream has no file of that name to conflict with. Edit it in place.

**`build.yml`, `codeql.yml`, `check-accessors.yml`.** On `mingw` these carry a
one-line Micron change (adding `mingw` to the CI branch triggers). They are
*not* overlay-managed, because projecting a whole-file copy of an actively
developed 13 KB upstream file would pin it at a Micron snapshot and silently
discard future upstream CI improvements. If those trigger edits ever need to
survive syncs automatically, add a transform step to `apply.sh` that rewrites
the trigger lists, rather than adding the files to `overlay/`.

## Shared conventions with the sibling tools

Micron ships three tools that hand a binary to someone outside the team: this
fork of nvme-cli, **swworkbench** (`mldcli`, `msecli2`) and **mldcs** (`mld`).
They share one set of CI conventions, each stated with its reasoning in
`docs/CI_CONVENTIONS.md` in the **mldcs** repository. The notes here are only
about how they land in a *fork*, which is the thing that makes this repository
different from the other two.

**The overlay is the fork-specific convention.** Everything Micron adds either
lives at a path upstream does not have (`.github/micron/`) or is projected from
`overlay/`. Nothing else in the tree is edited for Micron's benefit — not
`docs/`, not `meson.build`, not upstream's workflows — because every such edit is
a merge conflict on every sync, forever, resolved by whoever is on sync duty that
day. When a convention cannot be met without editing an upstream file, it does
not get met here; that is the trade the fork makes.

Met here:

- **Gates fail closed, and "could not check" is not "clean".** `scan_deps_pe.sh`
  exits 2 for the first and 0 for the second.
- **Actions pinned to a commit SHA with the version in a trailing comment.** All
  Micron-owned workflow files. Upstream's own workflows are already pinned and are
  not ours to change; Dependabot (upstream's config) keeps both current.
- **Permissions declared per job, defaulting to read.** Every job in
  `micron-release.yml` names what it needs, including the OIDC job's
  `id-token: write`.
- **Every run records what it produced.** Three step-summary blocks: the resolved
  upstream release, per-architecture version and imports, and the published
  assets.
- **The gate is adapted to the tool, not ported.** No no-network gate here; see
  above.

Still open, in the order they would pay off:

1. **The gate never meets a real binary before a release.** Upstream's
   `build.yml` does build Windows on every pull request — `windows-msys2-ucrt64`
   and `windows-msys2-clangarm64` — but those are `scripts/build.sh -b release`
   CI builds into `.build-ci`, without the release job's
   `--default-library=static` and `EXTRA_LINK_ARGS`. Pointing
   `scan_deps_pe.sh` at that exe would report a leak on a perfectly correct CI
   build, which is the anti-pattern the script's own header warns about. So
   `micron-ci.yml` tests the *gate*, and the gate still first sees a shipping
   binary at release. Closing this means a Micron job that builds with the
   release's link configuration, not reusing upstream's.
2. **The build is not attested.** `actions/attest-build-provenance` would let a
   recipient verify with `gh attestation verify` that a given zip came from this
   workflow, from this commit — the one convention swworkbench meets and the other
   two do not.
3. **No PR template.** Deliberate for now: most pull requests here are upstream
   syncs, and a Micron-specific template on a fork of an upstream project is
   mostly noise. Revisit if hand-written Micron changes become common.
