# Shell Completion Generator Notes

## Current Approach: C Source Parsing

The generator (`generate-completions.py`) parses C source files using regex to extract:
- Command definitions from `ENTRY` macros in `nvme-builtin.h` and plugin headers
- Options from `OPT_*` macros inside `NVME_ARGS`/`FEAT_ARGS` blocks in .c files

### Pros
- Works offline, no need to build or run nvme
- Extracts all defined options directly from source of truth

### Cons
- Regex-based parsing is fragile if macro formats change
- Cannot detect runtime-conditional options
- Option descriptions are minimal (extracted from macro params, not help text)
- **Complexity concern**: The generator is 884 lines of Python with multiple regex patterns. If something breaks in the future (e.g., macro format changes), debugging and fixing may be difficult

## Alternative Approaches to Consider

### 1. Modify macros to generate metadata
- Enhance ENTRY, OPT_*, NVME_ARGS macros to emit metadata (JSON, header, etc.)
- Could use preprocessor tricks or X-macros to dual-purpose the definitions
- Question: Is this even possible with C preprocessor limitations?
- Pros: Single source of truth, always in sync
- Cons: May require clever macro tricks, unknown feasibility

### 2. Metadata-driven commands and completions
- Restructure nvme-cli to define commands/options in a metadata format (JSON, YAML, etc.)
- Generate both the C code AND completion scripts from the same metadata
- Pros: True single source of truth, enables other tooling
- Cons: Significant refactor of existing codebase, may be too invasive

## Analysis

**Idea 1 (Macro modification)** is more pragmatic for nvme-cli's current state:
- The C preprocessor alone can't emit separate files, but there are workarounds
- X-macros pattern: Define options once, expand differently based on context
- Build-time trick: Run preprocessor with a special define that expands macros to print statements, capture output
- Example: `#ifdef EMIT_METADATA` could make `OPT_FLAG` expand to `printf("opt:flag:%s\n", ...)` instead of the actual struct
- Achievable without massive changes, though somewhat hacky
- Could prototype with one command to test feasibility

**Idea 2 (Metadata-driven)** is architecturally cleaner:
- One JSON/YAML file defines a command, generator produces C code, completions, man pages
- How some modern CLI tools work (e.g., Kubernetes code generators)
- But it's a big refactor - probably too invasive for upstream acceptance unless they're already considering such a change

**Current regex approach** is "good enough" for now:
- No upstream changes required
- But the 884-line parser with complex regexes is a maintenance risk
- If macros change format, fixing the regexes may be non-trivial

## Files
- `generate-completions.py` - Current generator (884 lines)
- `bash-nvme-completion.sh.generated` - Generated bash completion
- `_nvme.generated` - Generated zsh completion
