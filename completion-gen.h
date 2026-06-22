/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Shell completion generator.
 *
 * Builds an in-memory model of the command tree and each command's options by
 * walking the live plugin/command tree and capturing the options array that
 * each command builds via NVME_ARGS (see argconfig_set_parse_hook), then emits
 * a completion script for the requested shell from that model.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>

#include "plugin.h"
#include "util/argconfig.h"

/* A single command-line option, copied from struct argconfig_commandline_options.
 * String fields and the opt_val table are deep-copied (and owned) because they
 * may point at command-local storage that is freed once the command's fn
 * returns; see gen_copy_options().
 */
struct gen_option {
	const char *option;		/* long name; "" for a group separator */
	char short_option;		/* 0 if none */
	const char *meta;		/* value placeholder ("NUM"/"FMT"/...) or NULL */
	enum argconfig_types config_type;
	int argument_type;		/* no_/required_/optional_argument */
	const char *help;
	const struct argconfig_opt_val *opt_val; /* NULL or .str==NULL terminated */
	bool hidden;			/* not shown in help/completion */
};

struct gen_command {
	const char *name;
	const char *alias;		/* may be NULL */
	const char *help;
	struct gen_option *options;	/* heap array */
	size_t n_options;
	bool captured;			/* hook fired -> options valid */
	bool no_args;			/* fn returned before reaching parse */
};

struct gen_plugin {
	const char *name;		/* NULL for the builtin plugin */
	const char *desc;
	struct gen_command *commands;	/* heap array */
	size_t n_commands;
};

struct gen_program {
	const char *name;
	const char *version;
	const char *desc;
	struct gen_plugin *plugins;	/* heap array, builtin first */
	size_t n_plugins;
};

/*
 * Entry point for the `nvme gen-completions <bash|zsh|powershell>` subcommand.
 * Builds the model from prog and writes the requested completion script to
 * stdout. Returns 0 on success, negative errno on failure.
 */
int gen_run(int argc, char **argv, struct program *prog);
