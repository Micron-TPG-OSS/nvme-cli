#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""
Generate shell completion scripts for nvme-cli.

This script parses the nvme-cli C source files to extract command definitions
and their options, then generates bash and zsh completion scripts.

Usage:
    python3 generate-completions.py [options]

Options:
    --bash-out FILE   Output path for bash completion (default: bash-nvme-completion.sh.generated)
    --zsh-out FILE    Output path for zsh completion (default: _nvme.generated)
    --source-dir DIR  nvme-cli source directory (default: parent of this script)
    -v, --verbose     Show progress information
"""

import argparse
import glob
import os
import re
import sys
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple


class ArgType(Enum):
    """Argument type for command options."""
    NO_ARGUMENT = "no_argument"
    REQUIRED_ARGUMENT = "required_argument"


@dataclass
class Option:
    """Represents a command-line option."""
    long_name: str
    short_name: Optional[str] = None
    arg_type: ArgType = ArgType.NO_ARGUMENT
    meta: Optional[str] = None
    description: Optional[str] = None
    values: Optional[List[str]] = None  # Enumerated values for completion


@dataclass
class Command:
    """Represents an nvme command."""
    name: str
    description: str
    function_name: str
    alias: Optional[str] = None
    options: List[Option] = field(default_factory=list)


@dataclass
class Plugin:
    """Represents an nvme plugin."""
    name: str
    description: str
    version: Optional[str] = None
    commands: List[Command] = field(default_factory=list)


# Known option values for common options
KNOWN_VALUES: Dict[str, List[str]] = {
    "output-format": ["normal", "json", "binary"],
    "output-format-version": ["1", "2"],
    "sel": ["0", "1", "2", "3"],
    "sanact": ["exit-failure", "start-block-erase", "start-overwrite", "start-crypto-erase"],
    "action": ["replace", "replace-and-activate", "set-active", "replace-and-activate-immediate"],
    "csi": ["0", "1", "2"],
}

# Global options added by NVME_ARGS macro (from nvme.h)
GLOBAL_OPTIONS = [
    Option("verbose", "v", ArgType.NO_ARGUMENT, description="Increase output verbosity"),
    Option("output-format", "o", ArgType.REQUIRED_ARGUMENT, "FMT",
           description="Output format", values=["normal", "json", "binary"]),
    Option("timeout", None, ArgType.REQUIRED_ARGUMENT, "NUM",
           description="timeout value, in milliseconds"),
    Option("dry-run", None, ArgType.NO_ARGUMENT, description="show command instead of executing"),
    Option("no-retries", None, ArgType.NO_ARGUMENT, description="disable retry logic on errors"),
    Option("no-ioctl-probing", None, ArgType.NO_ARGUMENT,
           description="disable 64-bit IOCTL support probing"),
    Option("output-format-version", None, ArgType.REQUIRED_ARGUMENT, "NUM",
           description="output format version", values=["1", "2"]),
]

# FEAT_ARGS adds these options on top of NVME_ARGS
FEAT_EXTRA_OPTIONS = [
    Option("save", "s", ArgType.NO_ARGUMENT, description="specifies that the controller shall save the attribute"),
    Option("sel", "S", ArgType.REQUIRED_ARGUMENT, "NUM",
           description="select field", values=["0", "1", "2", "3"]),
]


# Regex patterns for parsing C source files
# ENTRY can have description as string literal or macro identifier
ENTRY_RE = re.compile(
    r'ENTRY\s*\(\s*"([^"]+)"\s*,\s*(?:"([^"]+)"|(\w+))\s*,\s*(\w+)(?:\s*,\s*"([^"]+)")?\s*\)',
    re.MULTILINE
)

PLUGIN_RE = re.compile(
    r'PLUGIN\s*\(\s*NAME\s*\(\s*"([^"]+)"\s*,\s*"([^"]+)"\s*,\s*(\w+)\s*\)',
    re.MULTILINE | re.DOTALL
)

# We don't need COMMAND_LIST_RE since ENTRY patterns are searched directly

# Option macro patterns
OPT_FLAG_RE = re.compile(
    r'OPT_FLAG\s*\(\s*"([^"]+)"\s*,\s*\'?([^\',]*)\'?\s*,',
    re.MULTILINE
)

OPT_INCR_RE = re.compile(
    r'OPT_INCR\s*\(\s*"([^"]+)"\s*,\s*\'?([^\',]*)\'?\s*,',
    re.MULTILINE
)

OPT_VALUE_RE = re.compile(
    r'OPT_(UINT|INT|LONG|BYTE|SHRT|DOUBLE|SUFFIX|POSITIVE)\s*\(\s*"([^"]+)"\s*,\s*\'?([^\',]*)\'?\s*,',
    re.MULTILINE
)

OPT_STRING_RE = re.compile(
    r'OPT_(STRING|FMT|FILE|LIST|STR)\s*\(\s*"([^"]+)"\s*,\s*\'?([^\',]*)\'?\s*,',
    re.MULTILINE
)

# Pattern to find function body containing NVME_ARGS or FEAT_ARGS
FUNC_PATTERN = r'static\s+int\s+{func_name}\s*\([^)]*\)\s*\{{'
ARGS_BLOCK_RE = re.compile(
    r'(NVME_ARGS|FEAT_ARGS)\s*\(\s*opts\s*,([^;]*?OPT_[^;]*?)\)\s*;',
    re.MULTILINE | re.DOTALL
)


def parse_short_option(s: str) -> Optional[str]:
    """Parse short option character, handling '0' and empty string as None."""
    s = s.strip().strip("'")
    if not s or s == '0' or s == '\\0':
        return None
    return s


def sanitize_description(desc: str) -> str:
    """Sanitize a description string for use in shell completion scripts."""
    # Remove C-style line continuation (backslash at end of line)
    desc = re.sub(r'\\\n\s*', ' ', desc)
    # Remove literal \n sequences
    desc = desc.replace('\\n', ' ')
    desc = desc.replace('\n', ' ')
    # Remove remaining backslashes that might cause issues
    desc = desc.replace('\\', '')
    # Collapse multiple spaces
    desc = ' '.join(desc.split())
    # Escape single quotes for shell - use '\'' pattern (end quote, escaped quote, start quote)
    # This works in both bash and zsh single-quoted strings
    desc = desc.replace("'", "'\\''")
    desc = desc.replace('\u2019', "'\\''")  # RIGHT SINGLE QUOTATION MARK (')
    desc = desc.replace('\u2018', "'\\''")  # LEFT SINGLE QUOTATION MARK (')
    return desc


def parse_builtin_commands(builtin_h_path: Path) -> List[Command]:
    """Parse nvme-builtin.h to extract main command definitions."""
    content = builtin_h_path.read_text()

    commands = []
    for match in ENTRY_RE.finditer(content):
        # Groups: 1=name, 2=desc_string, 3=desc_macro, 4=func, 5=alias
        name = match.group(1)
        description = match.group(2) if match.group(2) else match.group(3) or "No description"
        function_name = match.group(4)
        alias = match.group(5) if match.lastindex >= 5 and match.group(5) else None

        cmd = Command(
            name=name,
            description=description,
            function_name=function_name,
            alias=alias
        )
        commands.append(cmd)
    return commands


def parse_plugin_header(plugin_h_path: Path) -> Optional[Plugin]:
    """Parse a plugin header to extract plugin info and commands."""
    content = plugin_h_path.read_text()

    # Find PLUGIN macro
    plugin_match = PLUGIN_RE.search(content)
    if not plugin_match:
        return None

    plugin = Plugin(
        name=plugin_match.group(1),
        description=plugin_match.group(2),
        version=plugin_match.group(3)
    )

    # Find all ENTRY macros in the file (they should be inside COMMAND_LIST)
    # We search from the PLUGIN match position onwards
    search_content = content[plugin_match.start():]
    for entry_match in ENTRY_RE.finditer(search_content):
        # Groups: 1=name, 2=desc_string, 3=desc_macro, 4=func, 5=alias
        name = entry_match.group(1)
        description = entry_match.group(2) if entry_match.group(2) else entry_match.group(3) or "No description"
        function_name = entry_match.group(4)
        alias = entry_match.group(5) if entry_match.lastindex >= 5 and entry_match.group(5) else None

        cmd = Command(
            name=name,
            description=description,
            function_name=function_name,
            alias=alias
        )
        plugin.commands.append(cmd)

    return plugin


def find_function_options(content: str, function_name: str) -> Tuple[List[Option], bool]:
    """
    Find NVME_ARGS/FEAT_ARGS block for a given function and extract options.
    Returns (options, is_feat_args).
    """
    # Find the function definition
    func_pattern = rf'static\s+int\s+{re.escape(function_name)}\s*\([^)]*\)\s*\{{'
    func_match = re.search(func_pattern, content)
    if not func_match:
        return [], False

    # Extract function body (rough estimate - until next function or end)
    func_start = func_match.start()
    # Look for next function definition or end of file
    rest = content[func_start + 100:]
    next_func = re.search(r'\n\s*static\s+int\s+\w+\s*\(', rest)
    if next_func:
        func_end = func_start + 100 + next_func.start()
    else:
        func_end = len(content)

    func_body = content[func_start:func_end]

    # Find NVME_ARGS or FEAT_ARGS block
    args_match = ARGS_BLOCK_RE.search(func_body)
    if not args_match:
        return [], False

    is_feat_args = args_match.group(1) == "FEAT_ARGS"
    args_block = args_match.group(2)

    options = []

    # Parse OPT_FLAG (no_argument)
    for match in OPT_FLAG_RE.finditer(args_block):
        short = parse_short_option(match.group(2))
        opt = Option(
            long_name=match.group(1),
            short_name=short,
            arg_type=ArgType.NO_ARGUMENT
        )
        options.append(opt)

    # Parse OPT_INCR (no_argument, but increments)
    for match in OPT_INCR_RE.finditer(args_block):
        short = parse_short_option(match.group(2))
        opt = Option(
            long_name=match.group(1),
            short_name=short,
            arg_type=ArgType.NO_ARGUMENT
        )
        options.append(opt)

    # Parse numeric types (required_argument)
    for match in OPT_VALUE_RE.finditer(args_block):
        short = parse_short_option(match.group(3))
        long_name = match.group(2)
        opt = Option(
            long_name=long_name,
            short_name=short,
            arg_type=ArgType.REQUIRED_ARGUMENT,
            meta="NUM",
            values=KNOWN_VALUES.get(long_name)
        )
        options.append(opt)

    # Parse string types (required_argument)
    meta_map = {"FMT": "FMT", "FILE": "FILE", "LIST": "LIST", "STR": "STRING", "STRING": "STRING"}
    for match in OPT_STRING_RE.finditer(args_block):
        opt_type = match.group(1)
        long_name = match.group(2)
        short = parse_short_option(match.group(3))
        opt = Option(
            long_name=long_name,
            short_name=short,
            arg_type=ArgType.REQUIRED_ARGUMENT,
            meta=meta_map.get(opt_type, "STRING"),
            values=KNOWN_VALUES.get(long_name)
        )
        options.append(opt)

    return options, is_feat_args


def find_all_c_files_for_plugin(plugin_dir: Path) -> List[Path]:
    """Find all .c files in a plugin directory."""
    return list(plugin_dir.glob("*.c"))


def populate_command_options(commands: List[Command], c_file_path: Path, verbose: bool = False):
    """Populate options for commands by parsing the C source file."""
    if not c_file_path.exists():
        return

    content = c_file_path.read_text()

    for cmd in commands:
        opts, is_feat = find_function_options(content, cmd.function_name)

        # Add command-specific options
        cmd.options = opts

        # Add FEAT_ARGS extra options if applicable
        if is_feat:
            # Check if save/sel already exist
            existing = {o.long_name for o in cmd.options}
            for feat_opt in FEAT_EXTRA_OPTIONS:
                if feat_opt.long_name not in existing:
                    cmd.options.append(feat_opt)

        # Add global options
        existing = {o.long_name for o in cmd.options}
        for global_opt in GLOBAL_OPTIONS:
            if global_opt.long_name not in existing:
                cmd.options.append(global_opt)

        if verbose and opts:
            print(f"  Found {len(opts)} options for {cmd.name}")


def generate_bash_completion(commands: List[Command], plugins: List[Plugin]) -> str:
    """Generate the bash completion script."""
    lines = []

    # Header
    lines.append("# SPDX-License-Identifier: GPL-2.0-or-later")
    lines.append("#")
    lines.append("# bash tab completion for the nvme command line utility")
    lines.append("# Auto-generated by completions/generate-completions.py")
    lines.append("# DO NOT EDIT MANUALLY")
    lines.append("")

    # NO_OPTS constant
    lines.append('NO_OPTS=""')
    lines.append("")

    # Helper function for value completion detection
    lines.append("""# Helper function to detect if we're completing an option's value.
_nvme_detect_value_completion() {
	completing_value=0
	opt=""
	val=""

	if [[ $cur == --*= ]]; then
		opt="${cur%=}"
		completing_value=1
	elif [[ $cur == "=" ]] && [[ $prev == --* ]]; then
		opt="$prev"
		completing_value=1
	elif [[ $cur != -* ]] && [[ $cur != "" ]] && [[ $prev == "=" ]] && [[ ${words[$cword-2]} == --* ]]; then
		opt="${words[$cword-2]}"
		val="$cur"
		completing_value=1
	elif [[ $cur != -* ]] && [[ $cur != "" ]] && [[ $prev == --* ]]; then
		opt="$prev"
		val="$cur"
		completing_value=1
	elif [[ $cur == "" ]] && [[ $prev == --* ]]; then
		opt="$prev"
		completing_value=1
	elif [[ $cur == "" ]] && [[ $prev == "=" ]]; then
		opt="${words[$cword-2]}"
		completing_value=1
	elif [[ $cur == "" ]] && [[ $prev == -? ]]; then
		opt="$prev"
		completing_value=1
	elif [[ $cur != -* ]] && [[ $cur != "" ]] && [[ $prev == -? ]]; then
		opt="$prev"
		val="$cur"
		completing_value=1
	fi
}
""")

    # Main nvme_list_opts function
    lines.append("nvme_list_opts () {")
    lines.append('	local opts=""')
    lines.append('	local vals=""')
    lines.append('	local opt=""')
    lines.append('	local val=""')
    lines.append('	local completing_value=0')
    lines.append("")
    lines.append("	local nonopt_args=0")
    lines.append("	for (( i=0; i < ${#words[@]}-1; i++ )); do")
    lines.append('		if [[ ${words[i]} != -* ]]; then')
    lines.append("			let nonopt_args+=1")
    lines.append("		fi")
    lines.append("	done")
    lines.append("")
    lines.append("	if [ $nonopt_args -eq 2 ]; then")
    lines.append('		opts="/dev/nvme* "')
    lines.append("	fi")
    lines.append("")
    lines.append('	_nvme_detect_value_completion')
    lines.append("")
    lines.append('	case "$1" in')

    # Generate case for each main command
    for cmd in commands:
        opts_str = format_bash_options(cmd.options)
        lines.append(f'		"{cmd.name}")')
        lines.append(f'		opts+=" {opts_str}"')

        # Add value completions if any
        value_cases = generate_bash_value_cases(cmd.options)
        if value_cases:
            lines.append('		case $opt in')
            lines.extend(value_cases)
            lines.append('		esac')

        lines.append('			;;')

        # Handle alias if present
        if cmd.alias:
            lines.append(f'		"{cmd.alias}")')
            lines.append(f'		opts+=" {opts_str}"')
            if value_cases:
                lines.append('		case $opt in')
                lines.extend(value_cases)
                lines.append('		esac')
            lines.append('			;;')

    lines.append('	esac')
    lines.append("")
    lines.append('	if [[ $completing_value -eq 1 ]] && [[ -n "$vals" ]]; then')
    lines.append('		COMPREPLY+=( $( compgen -W "$vals" -- "$val" ) )')
    lines.append("	else")
    lines.append('		COMPREPLY+=( $( compgen -W "$opts" -- $cur ) )')
    lines.append("	fi")
    lines.append("}")
    lines.append("")

    # Generate plugin-specific functions
    for plugin in plugins:
        func_name = f"plugin_{plugin.name.replace('-', '_')}_opts"
        lines.append(f"{func_name} () {{")
        lines.append('	local opts=""')
        lines.append('	local vals=""')
        lines.append('	local opt=""')
        lines.append('	local val=""')
        lines.append('	local completing_value=0')
        lines.append("")
        lines.append('	_nvme_detect_value_completion')
        lines.append("")
        lines.append('	case "$1" in')

        for cmd in plugin.commands:
            opts_str = format_bash_options(cmd.options)
            lines.append(f'		"{cmd.name}")')
            lines.append(f'		opts+=" {opts_str}"')

            value_cases = generate_bash_value_cases(cmd.options)
            if value_cases:
                lines.append('		case $opt in')
                lines.extend(value_cases)
                lines.append('		esac')

            lines.append('			;;')

        lines.append('	esac')
        lines.append("")
        lines.append('	if [[ $completing_value -eq 1 ]] && [[ -n "$vals" ]]; then')
        lines.append('		COMPREPLY+=( $( compgen -W "$vals" -- "$val" ) )')
        lines.append("	else")
        lines.append('		COMPREPLY+=( $( compgen -W "$opts" -- $cur ) )')
        lines.append("	fi")
        lines.append("}")
        lines.append("")

    # Main nvme_list_cmds function
    lines.append("nvme_list_cmds () {")
    lines.append('	local cmds=(')

    # Main commands
    for cmd in commands:
        lines.append(f'		"{cmd.name}"')
        if cmd.alias:
            lines.append(f'		"{cmd.alias}"')

    # Plugin names
    for plugin in plugins:
        lines.append(f'		"{plugin.name}"')

    lines.append('		"version"')
    lines.append('		"help"')
    lines.append('	)')
    lines.append('	COMPREPLY+=( $( compgen -W "${cmds[*]}" -- $cur ) )')
    lines.append("}")
    lines.append("")

    # Plugin subcommand list functions
    for plugin in plugins:
        func_name = f"plugin_{plugin.name.replace('-', '_')}_cmds"
        lines.append(f"{func_name} () {{")
        lines.append('	local cmds=(')
        for cmd in plugin.commands:
            lines.append(f'		"{cmd.name}"')
        lines.append('	)')
        lines.append('	COMPREPLY+=( $( compgen -W "${cmds[*]}" -- $cur ) )')
        lines.append("}")
        lines.append("")

    # Main completion function
    lines.append("_nvme () {")
    lines.append("	local cur prev words cword")
    lines.append("	_init_completion || return")
    lines.append("")
    lines.append("	if [[ $cword -eq 1 ]]; then")
    lines.append("		nvme_list_cmds")
    lines.append("		return")
    lines.append("	fi")
    lines.append("")
    lines.append('	case "${words[1]}" in')

    # Main commands
    for cmd in commands:
        if cmd.alias:
            lines.append(f'		"{cmd.name}"|"{cmd.alias}")')
        else:
            lines.append(f'		"{cmd.name}")')
        lines.append(f'		nvme_list_opts "{cmd.name}"')
        lines.append("		;;")

    # Plugins
    for plugin in plugins:
        func_name_opts = f"plugin_{plugin.name.replace('-', '_')}_opts"
        func_name_cmds = f"plugin_{plugin.name.replace('-', '_')}_cmds"
        lines.append(f'		"{plugin.name}")')
        lines.append("		if [[ $cword -eq 2 ]]; then")
        lines.append(f"			{func_name_cmds}")
        lines.append("		else")
        lines.append(f'			{func_name_opts} "${{words[2]}}"')
        lines.append("		fi")
        lines.append("		;;")

    lines.append('		"version"|"help")')
    lines.append("		;;")
    lines.append("	esac")
    lines.append("}")
    lines.append("")
    lines.append("complete -F _nvme nvme")
    lines.append("")

    return '\n'.join(lines)


def format_bash_options(options: List[Option]) -> str:
    """Format options for bash completion."""
    parts = []
    seen = set()

    for opt in options:
        if opt.long_name in seen:
            continue
        seen.add(opt.long_name)

        # Long option
        if opt.arg_type == ArgType.REQUIRED_ARGUMENT:
            parts.append(f"--{opt.long_name}=")
        else:
            parts.append(f"--{opt.long_name}")

        # Short option
        if opt.short_name:
            parts.append(f"-{opt.short_name}")

    return ' '.join(parts)


def generate_bash_value_cases(options: List[Option]) -> List[str]:
    """Generate bash case statements for option value completion."""
    lines = []

    for opt in options:
        if opt.values:
            # Build option pattern (long and short forms)
            patterns = [f"--{opt.long_name}"]
            if opt.short_name:
                patterns.append(f"-{opt.short_name}")
            pattern = "|".join(patterns)

            lines.append(f'			{pattern})')
            lines.append(f'			vals+=" {" ".join(opt.values)}"')
            lines.append('				;;')

    return lines


def generate_zsh_completion(commands: List[Command], plugins: List[Plugin]) -> str:
    """Generate the zsh completion script."""
    lines = []

    # Header
    lines.append("#compdef _nvme nvme")
    lines.append("# SPDX-License-Identifier: GPL-2.0-or-later")
    lines.append("#")
    lines.append("# zsh completions for the nvme command-line interface")
    lines.append("# Auto-generated by completions/generate-completions.py")
    lines.append("# DO NOT EDIT MANUALLY")
    lines.append("")

    lines.append("_nvme () {")
    lines.append("	local -a _cmds")
    lines.append("	_cmds=(")

    # Main commands
    for cmd in commands:
        desc = sanitize_description(cmd.description)
        lines.append(f"	'{cmd.name}:{desc}'")
        if cmd.alias:
            lines.append(f"	'{cmd.alias}:{desc}'")

    # Plugins
    for plugin in plugins:
        desc = sanitize_description(plugin.description)
        lines.append(f"	'{plugin.name}:{desc}'")

    lines.append("	'version:show the program version'")
    lines.append("	'help:print brief descriptions of all nvme commands'")
    lines.append("	)")
    lines.append("")

    # Helper functions
    lines.append("""	# Helper function to describe options with proper suffix handling
	_nvme_describe() {
		local desc="$1"
		local -a opts=("${(@P)2}")
		local -a eq_opts noeq_opts
		local opt

		for opt in "${opts[@]}"; do
			if [[ "${opt%%:*}" == *= ]]; then
				eq_opts+=("$opt")
			else
				noeq_opts+=("$opt")
			fi
		done

		(( ${#noeq_opts} )) && _describe -t options "$desc" noeq_opts
		(( ${#eq_opts} )) && _describe -t eq-options "$desc" eq_opts -S ''
	}
""")

    lines.append("	local expl")
    lines.append("")
    lines.append("	_arguments '*:: :->subcmds' && return 0")
    lines.append("")
    lines.append("	if (( CURRENT == 1 )); then")
    lines.append('		_describe -t commands "nvme subcommands" _cmds')
    lines.append("		return")
    lines.append("	elif (( CURRENT > 2 )); then")
    lines.append("		case ${words[1]} in")

    # Plugin subcommand handling
    for plugin in plugins:
        lines.append(f"		({plugin.name})")
        lines.append("			case ${words[2]} in")

        for cmd in plugin.commands:
            var_name = f"_{plugin.name.replace('-', '_')}_{cmd.name.replace('-', '_')}"
            lines.append(f"			({cmd.name})")
            lines.append(f"				local {var_name}")
            lines.append(f"				{var_name}=(")
            lines.append("				/dev/nvme':supply a device to use (required)'")

            for opt_line in format_zsh_options(cmd.options):
                lines.append(f"				{opt_line}")

            lines.append("				)")
            lines.append("				_arguments '*:: :->subcmds'")
            lines.append(f'				_nvme_describe "nvme {plugin.name} {cmd.name} options" {var_name}')
            lines.append("				;;")

        lines.append("			(*)")
        lines.append("				_files")
        lines.append("				;;")
        lines.append("			esac")
        lines.append("			;;")

    lines.append("		esac")
    lines.append("		return")
    lines.append("	else")

    # Main command handling - uses words[CURRENT-1] for command at position 2
    lines.append("		case ${words[CURRENT-1]} in")

    for cmd in commands:
        var_name = f"_{cmd.name.replace('-', '_')}"
        pattern = f"({cmd.name})"
        if cmd.alias:
            pattern = f"({cmd.name}|{cmd.alias})"

        lines.append(f"		{pattern}")
        lines.append(f"			local {var_name}")
        lines.append(f"			{var_name}=(")
        lines.append("			/dev/nvme':supply a device to use (required)'")

        for opt_line in format_zsh_options(cmd.options):
            lines.append(f"			{opt_line}")

        lines.append("			)")
        lines.append("			_arguments '*:: :->subcmds'")
        lines.append(f'			_nvme_describe "nvme {cmd.name} options" {var_name}')
        lines.append("			;;")

    # Plugin subcommand lists (shown at CURRENT == 2 when user types "nvme plugin-name <TAB>")
    for plugin in plugins:
        lines.append(f"		({plugin.name})")
        lines.append(f"			local _{plugin.name.replace('-', '_')}_cmds")
        lines.append(f"			_{plugin.name.replace('-', '_')}_cmds=(")
        for cmd in plugin.commands:
            desc = sanitize_description(cmd.description)
            lines.append(f"			'{cmd.name}:{desc}'")
        lines.append("			)")
        lines.append(f'			_describe -t commands "nvme {plugin.name} subcommands" _{plugin.name.replace("-", "_")}_cmds')
        lines.append("			;;")

    lines.append("		(version|help)")
    lines.append("			;;")
    lines.append("		(*)")
    lines.append("			_files")
    lines.append("			;;")
    lines.append("		esac")
    lines.append("		return")
    lines.append("	fi")
    lines.append("")
    lines.append("	_files")
    lines.append("}")
    lines.append("")

    return '\n'.join(lines)


def format_zsh_options(options: List[Option]) -> List[str]:
    """Format options for zsh completion array."""
    lines = []
    seen = set()

    for opt in options:
        if opt.long_name in seen:
            continue
        seen.add(opt.long_name)

        desc = opt.description or f"{opt.long_name} option"
        desc = sanitize_description(desc)

        # Add value hints to description if available
        if opt.values:
            desc += f" ({', '.join(opt.values)})"

        # Long option - zsh format is: option':description'
        if opt.arg_type == ArgType.REQUIRED_ARGUMENT:
            lines.append(f"--{opt.long_name}=':{desc}'")
        else:
            lines.append(f"--{opt.long_name}':{desc}'")

        # Short option
        if opt.short_name:
            lines.append(f"-{opt.short_name}':alias for --{opt.long_name}'")

    return lines


def main():
    parser = argparse.ArgumentParser(description='Generate nvme-cli shell completions')
    parser.add_argument('--bash-out', default='bash-nvme-completion.sh.generated',
                        help='Output path for bash completion')
    parser.add_argument('--zsh-out', default='_nvme.generated',
                        help='Output path for zsh completion')
    parser.add_argument('--source-dir', default=None,
                        help='nvme-cli source directory')
    parser.add_argument('-v', '--verbose', action='store_true',
                        help='Show progress')
    args = parser.parse_args()

    # Determine source directory
    if args.source_dir:
        src = Path(args.source_dir)
    else:
        # Default to parent of this script's directory
        src = Path(__file__).parent.parent

    # Determine output paths
    completions_dir = Path(__file__).parent
    bash_out = completions_dir / args.bash_out
    zsh_out = completions_dir / args.zsh_out

    if args.verbose:
        print(f"Source directory: {src}")
        print(f"Bash output: {bash_out}")
        print(f"Zsh output: {zsh_out}")
        print()

    # Parse builtin commands
    builtin_h = src / 'nvme-builtin.h'
    if args.verbose:
        print(f"Parsing {builtin_h}...")
    commands = parse_builtin_commands(builtin_h)
    if args.verbose:
        print(f"  Found {len(commands)} builtin commands")

    # Parse options for builtin commands from nvme.c
    nvme_c = src / 'nvme.c'
    if args.verbose:
        print(f"Parsing options from {nvme_c}...")
    populate_command_options(commands, nvme_c, args.verbose)

    # Parse plugins
    plugins = []
    plugin_dirs = list((src / 'plugins').iterdir()) if (src / 'plugins').exists() else []

    for plugin_dir in sorted(plugin_dirs):
        if not plugin_dir.is_dir():
            continue

        # Find plugin header files
        headers = list(plugin_dir.glob('*-nvme.h')) + list(plugin_dir.glob('*.h'))
        headers = [h for h in headers if 'print' not in h.name.lower()]

        for h_path in headers:
            plugin = parse_plugin_header(h_path)
            if plugin:
                if args.verbose:
                    print(f"Parsing plugin {plugin.name} from {h_path}...")
                    print(f"  Found {len(plugin.commands)} commands")

                # Find C files for option parsing
                c_files = find_all_c_files_for_plugin(plugin_dir)
                for c_file in c_files:
                    populate_command_options(plugin.commands, c_file, args.verbose)

                plugins.append(plugin)
                break  # Only use first matching header per directory

    if args.verbose:
        print()
        print(f"Total: {len(commands)} builtin commands, {len(plugins)} plugins")
        total_plugin_cmds = sum(len(p.commands) for p in plugins)
        print(f"Total plugin commands: {total_plugin_cmds}")
        print()

    # Generate bash completion
    if args.verbose:
        print(f"Generating bash completion...")
    bash_content = generate_bash_completion(commands, plugins)
    bash_out.write_text(bash_content)
    print(f"Generated {bash_out}")

    # Generate zsh completion
    if args.verbose:
        print(f"Generating zsh completion...")
    zsh_content = generate_zsh_completion(commands, plugins)
    zsh_out.write_text(zsh_content)
    print(f"Generated {zsh_out}")


if __name__ == '__main__':
    main()
