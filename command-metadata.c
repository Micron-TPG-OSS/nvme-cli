/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Command/option metadata dump for nvme-cli.
 *
 * Builds an in-memory model of every command and its options, then writes it to
 * stdout as JSON for the `dump-commands-and-options` subcommand. The shell
 * completion scripts are generated from that JSON by
 * completions/generate-completions.py.
 *
 * The model is captured by walking the live plugin/command tree and, for each
 * command, intercepting the options array it builds on its stack via NVME_ARGS.
 * Capture installs a hook in argconfig_parse() (see argconfig_set_parse_hook):
 * when a command calls into the parser, the hook copies the options array into
 * the model and returns a sentinel so the command unwinds before opening any
 * device.
 */

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "command-metadata.h"
#include "nvme.h"
#include "util/json.h"

/*
 * Returned by the capture hook to unwind the command's fn before it opens a
 * device. Distinct from values real parsing returns (0, -EINVAL, -errno);
 * the driver does not rely on it, detecting capture via the "captured" flag.
 */
#define COMPLETION_GEN_SENTINEL (-ECANCELED)

/*
 * Version of the emitted JSON schema, bumped on any breaking change to the
 * output structure (renamed/removed keys, changed value semantics). Additive
 * changes that keep existing keys stable do not require a bump. Consumers
 * should reject a major version they do not understand.
 */
#define COMMAND_METADATA_SCHEMA_VERSION 1

/* The command currently being captured; set by the driver, read by the hook. */
static struct gen_command *gen_cur_command;

/* ------------------------------------------------------------------ */
/* Pass 1: capture                                                    */
/* ------------------------------------------------------------------ */

static char *xstrdup(const char *s)
{
	return s ? strdup(s) : NULL;
}

/*
 * Deep-copy an opt_val table. The table is valid while the parser runs (and
 * thus while the hook runs), but may reference command-local storage, so copy
 * it rather than alias it.
 */
static struct argconfig_opt_val *copy_opt_val(const struct argconfig_opt_val *src)
{
	struct argconfig_opt_val *dst;
	size_t n = 0, i;

	if (!src)
		return NULL;

	for (; src[n].str; n++)
		;

	dst = calloc(n + 1, sizeof(*dst));
	if (!dst)
		return NULL;

	for (i = 0; i < n; i++) {
		dst[i] = src[i];
		dst[i].str = xstrdup(src[i].str);
	}
	dst[n].str = NULL;

	return dst;
}

static struct gen_option *gen_copy_options(const struct argconfig_commandline_options *opts,
					   size_t *n_out)
{
	const struct argconfig_commandline_options *s;
	struct gen_option *out;
	size_t n = 0, i;

	for (s = opts; s->option; s++)
		n++;

	out = calloc(n, sizeof(*out));
	if (!out) {
		*n_out = 0;
		return NULL;
	}

	/*
	 * Deep-copy: option/meta/help and the opt_val table are valid while the
	 * parser runs but may point at command-local storage that is freed once
	 * the command's fn returns, so duplicate rather than alias them.
	 */
	for (i = 0; i < n; i++) {
		out[i].option = xstrdup(opts[i].option);
		out[i].short_option = opts[i].short_option;
		out[i].meta = xstrdup(opts[i].meta);
		out[i].config_type = opts[i].config_type;
		out[i].argument_type = opts[i].argument_type;
		out[i].help = xstrdup(opts[i].help);
		out[i].opt_val = copy_opt_val(opts[i].opt_val);
		out[i].hidden = opts[i].hidden;
	}

	*n_out = n;
	return out;
}

static int completion_capture_hook(int argc, char **argv, const char *program_desc,
				   struct argconfig_commandline_options *options)
{
	if (gen_cur_command && !gen_cur_command->captured) {
		gen_cur_command->options =
			gen_copy_options(options, &gen_cur_command->n_options);
		gen_cur_command->captured = true;
	}

	return COMPLETION_GEN_SENTINEL;
}

static void gen_capture_command(struct gen_command *gc, struct command *cmd,
				struct plugin *plugin)
{
	/* argv[1] is a placeholder device; the sentinel returns before it is
	 * ever opened, so it need not exist. */
	char *argv[] = { cmd->name, (char *)"/dev/nvme0", NULL };

	gc->name = cmd->name;
	gc->alias = cmd->alias;
	gc->help = cmd->help;
	gc->captured = false;
	gc->no_args = false;

	/* Don't invoke the dump command itself: it would re-enter
	 * dump_commands_and_options() and recurse forever. It has no
	 * completable options. */
	if (!strcmp(cmd->name, "dump-commands-and-options")) {
		gc->no_args = true;
		return;
	}

	gen_cur_command = gc;
	(void)cmd->fn(2, argv, cmd, plugin);
	gen_cur_command = NULL;

	/* Hook never fired: the command returned before reaching the parser
	 * (e.g. gen-hostnqn), so it has no completable options. */
	if (!gc->captured)
		gc->no_args = true;
}

static size_t count_commands(struct command **commands)
{
	size_t n = 0;

	while (commands && commands[n])
		n++;

	return n;
}

static size_t count_plugins(struct plugin *p)
{
	size_t n = 0;

	for (; p; p = p->next)
		n++;

	return n;
}

static struct gen_program *gen_build_model(struct program *prog)
{
	struct gen_program *model;
	struct plugin *plugin;
	int saved_stdout = -1, saved_stderr = -1, devnull;
	size_t pi;

	model = calloc(1, sizeof(*model));
	if (!model)
		return NULL;

	model->name = prog->name;
	model->version = prog->version;
	model->desc = prog->desc;
	model->n_plugins = count_plugins(prog->extensions);
	model->plugins = calloc(model->n_plugins, sizeof(*model->plugins));
	if (!model->plugins) {
		free(model);
		return NULL;
	}

	/* Suppress stdout/stderr while invoking command fns: a few commands
	 * print before they reach the parser (e.g. gen-hostnqn), and some emit
	 * parse-error diagnostics in reaction to the capture sentinel. */
	fflush(stdout);
	fflush(stderr);
	devnull = open("/dev/null", O_WRONLY);
	if (devnull >= 0) {
		saved_stdout = dup(STDOUT_FILENO);
		saved_stderr = dup(STDERR_FILENO);
		dup2(devnull, STDOUT_FILENO);
		dup2(devnull, STDERR_FILENO);
	}

	argconfig_set_parse_hook(completion_capture_hook);

	for (pi = 0, plugin = prog->extensions; plugin; plugin = plugin->next, pi++) {
		struct gen_plugin *gp = &model->plugins[pi];
		size_t ci;

		gp->name = plugin->name;
		gp->desc = plugin->desc;
		gp->n_commands = count_commands(plugin->commands);
		gp->commands = calloc(gp->n_commands, sizeof(*gp->commands));
		if (!gp->commands) {
			gp->n_commands = 0;
			continue;
		}

		for (ci = 0; ci < gp->n_commands; ci++)
			gen_capture_command(&gp->commands[ci], plugin->commands[ci],
					     plugin);
	}

	argconfig_set_parse_hook(NULL);

	fflush(stdout);
	fflush(stderr);
	if (saved_stdout >= 0) {
		dup2(saved_stdout, STDOUT_FILENO);
		close(saved_stdout);
	}
	if (saved_stderr >= 0) {
		dup2(saved_stderr, STDERR_FILENO);
		close(saved_stderr);
	}
	if (devnull >= 0)
		close(devnull);

	return model;
}

/* ------------------------------------------------------------------ */
/* Model helpers shared by emitters                                   */
/* ------------------------------------------------------------------ */

static bool opt_is_separator(const struct gen_option *o)
{
	return o->config_type == CFG_GROUP_SEPARATOR;
}

static bool opt_is_global_separator(const struct gen_option *o)
{
	return opt_is_separator(o) && o->help && !strcmp(o->help, "Global options");
}

/* "none" / "required" / "optional" — how the option consumes its argument. */
static const char *opt_arg(const struct gen_option *o)
{
	switch (o->argument_type) {
	case optional_argument:
		return "optional";
	case no_argument:
		return "none";
	default:
		return "required";
	}
}

static bool opt_takes_value(const struct gen_option *o)
{
	return o->argument_type != no_argument;
}

/* True for an option that should appear in a completion: a real, named,
 * non-hidden, non-separator option. */
static bool opt_is_emittable(const struct gen_option *o)
{
	return !opt_is_separator(o) && !o->hidden && o->option && o->option[0];
}

/* True for the synthetic version/help commands that take no device. */
static bool command_is_meta(const struct gen_command *c)
{
	return !strcmp(c->name, "help") || !strcmp(c->name, "version") ||
	       !strcmp(c->name, "dump-commands-and-options");
}

/* ------------------------------------------------------------------ */
/* Pass 2: JSON                                                       */
/* ------------------------------------------------------------------ */

#ifdef CONFIG_JSONC

/*
 * The value set for an option, when the generator can derive it. Returns a
 * json array of strings, or NULL if the option has no known value set. The
 * caller owns the returned array.
 *
 * output-format and output-format-version are special-cased because their
 * values come from a description string (DESC_OUTPUT_FORMAT, build-config
 * dependent) rather than an opt_val table; every other value set comes from
 * the option's opt_val table.
 */
static struct json_object *gen_json_option_values(const struct gen_option *o)
{
	const struct argconfig_opt_val *v;
	struct json_object *vals;

	if (!strcmp(o->option, "output-format")) {
		vals = json_create_array();
		json_array_add_value_string(vals, "normal");
		json_array_add_value_string(vals, "json");
		json_array_add_value_string(vals, "binary");
		json_array_add_value_string(vals, "tabular");
		return vals;
	}
	if (!strcmp(o->option, "output-format-version")) {
		vals = json_create_array();
		json_array_add_value_string(vals, "1");
		json_array_add_value_string(vals, "2");
		return vals;
	}
	if (!o->opt_val)
		return NULL;

	vals = json_create_array();
	for (v = o->opt_val; v->str; v++)
		json_array_add_value_string(vals, v->str);
	return vals;
}

/* Emit one option as a json object into the given array. */
static void gen_json_option(struct json_object *arr, const struct gen_option *o,
			    bool global)
{
	struct json_object *jo, *vals;
	char shortbuf[2] = { o->short_option, '\0' };

	if (!opt_is_emittable(o))
		return;

	jo = json_create_object();
	json_object_add_value_string(jo, "long", o->option);
	if (o->short_option)
		json_object_add_value_string(jo, "short", shortbuf);
	json_object_add_value_string(jo, "arg", opt_arg(o));
	if (o->meta && opt_takes_value(o))
		json_object_add_value_string(jo, "metavar", o->meta);
	if (o->help)
		json_object_add_value_string(jo, "help", o->help);
	if (global)
		json_object_add_value_int(jo, "global", 1);

	vals = gen_json_option_values(o);
	if (vals)
		json_object_add_value_array(jo, "values", vals);

	json_array_add_value_object(arr, jo);
}

/* Emit one command as a json object: name, alias, help, and options. */
static struct json_object *gen_json_command(const struct gen_command *c)
{
	struct json_object *jc, *opts;
	bool global = false;
	size_t i;

	jc = json_create_object();
	json_object_add_value_string(jc, "name", c->name);
	if (c->alias)
		json_object_add_value_string(jc, "alias", c->alias);
	if (c->help)
		json_object_add_value_string(jc, "help", c->help);
	if (command_is_meta(c))
		json_object_add_value_int(jc, "meta", 1);
	if (c->no_args)
		json_object_add_value_int(jc, "no_args", 1);

	opts = json_create_array();
	for (i = 0; i < c->n_options; i++) {
		/* Options after the "Global options" separator are the shared
		 * NVME_ARGS globals; flag them so generators can group them. */
		if (opt_is_global_separator(&c->options[i])) {
			global = true;
			continue;
		}
		gen_json_option(opts, &c->options[i], global);
	}
	json_object_add_value_array(jc, "options", opts);

	return jc;
}

/* Emit one plugin as a json object: name (null for builtin), desc, commands. */
static struct json_object *gen_json_plugin(const struct gen_plugin *p)
{
	struct json_object *jp, *cmds;
	size_t i;

	jp = json_create_object();
	if (p->name)
		json_object_add_value_string(jp, "name", p->name);
	if (p->desc)
		json_object_add_value_string(jp, "desc", p->desc);

	cmds = json_create_array();
	for (i = 0; i < p->n_commands; i++)
		json_array_add_value_object(cmds, gen_json_command(&p->commands[i]));
	json_object_add_value_array(jp, "commands", cmds);

	return jp;
}

static void gen_json(const struct gen_program *m, FILE *out)
{
	struct json_object *root, *builtin, *plugins;
	size_t i;

	(void)out; /* json_print_object writes to stdout */

	root = json_create_object();
	json_object_add_value_int(root, "schema_version",
				  COMMAND_METADATA_SCHEMA_VERSION);
	json_object_add_value_string(root, "name", m->name);
	if (m->version)
		json_object_add_value_string(root, "version", m->version);

	/* Builtin (top-level) commands live in their own array; named plugins
	 * go under "plugins" so generators can build the dispatch nesting. */
	builtin = json_create_array();
	plugins = json_create_array();
	for (i = 0; i < m->n_plugins; i++) {
		const struct gen_plugin *p = &m->plugins[i];
		size_t j;

		if (!p->name) {
			for (j = 0; j < p->n_commands; j++)
				json_array_add_value_object(builtin,
					gen_json_command(&p->commands[j]));
		} else {
			json_array_add_value_object(plugins, gen_json_plugin(p));
		}
	}
	json_object_add_value_array(root, "commands", builtin);
	json_object_add_value_array(root, "plugins", plugins);

	json_print_object(root, NULL);
	printf("\n");
	json_free_object(root);
}

#else /* CONFIG_JSONC */

static void gen_json(const struct gen_program *m, FILE *out)
{
	(void)m;
	(void)out;
	fprintf(stderr,
		"dump-commands-and-options requires nvme-cli built with json-c support\n");
}

#endif /* CONFIG_JSONC */

/* ------------------------------------------------------------------ */
/* Entry point                                                        */
/* ------------------------------------------------------------------ */

int dump_commands_and_options(struct program *prog)
{
	struct gen_program *model;

#ifndef CONFIG_JSONC
	fprintf(stderr,
		"dump-commands-and-options requires nvme-cli built with json-c support\n");
	return -ENOTSUP;
#endif

	model = gen_build_model(prog);
	if (!model)
		return -ENOMEM;

	gen_json(model, stdout);

	return 0;
}
