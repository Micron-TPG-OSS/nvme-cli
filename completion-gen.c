/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Shell completion generator for nvme-cli.
 *
 * Pass 1 walks the live plugin/command tree and, for each command, captures the
 * options array that the command builds on its stack via NVME_ARGS. Capture is
 * done by installing a hook in argconfig_parse() (see argconfig_set_parse_hook):
 * when a command calls into the parser, the hook copies the options array into
 * the model and returns a sentinel so the command unwinds before opening any
 * device.
 *
 * Pass 2 (the gen_<shell> functions) is fully decoupled from argconfig: it walks
 * the model and emits a completion script for the requested shell.
 */

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "completion-gen.h"
#include "nvme.h"

/*
 * Returned by the capture hook to unwind the command's fn before it opens a
 * device. Distinct from values real parsing returns (0, -EINVAL, -errno);
 * the driver does not rely on it, detecting capture via the "captured" flag.
 */
#define COMPLETION_GEN_SENTINEL (-ECANCELED)

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

	/* Don't invoke the generator command itself: it would re-enter
	 * gen_run() and recurse forever. It has no completable options. */
	if (!strcmp(cmd->name, "gen-completions")) {
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
	return !strcmp(c->name, "help") || !strcmp(c->name, "version");
}

/* ------------------------------------------------------------------ */
/* Pass 2: bash                                                       */
/* ------------------------------------------------------------------ */

static const char bash_header[] =
"# SPDX-License-Identifier: GPL-2.0-or-later\n"
"#\n"
"# bash tab completion for the nvme command line utility\n"
"#\n"
"# This file is generated by `nvme gen-completions bash`. Do not edit.\n"
"\n"
"# Helper function to detect if we're completing an option's value.\n"
"# Uses: $cur, $prev, $words, $cword (from _init_completion)\n"
"# Sets: $opt (the option name), $val (partial value), $completing_value (0 or 1)\n"
"_nvme_detect_value_completion() {\n"
"	completing_value=0\n"
"	opt=\"\"\n"
"	val=\"\"\n"
"\n"
"	if [[ $cur == --*= ]]; then\n"
"		opt=\"${cur%=}\"\n"
"		completing_value=1\n"
"	elif [[ $cur == \"=\" ]] && [[ $prev == --* ]]; then\n"
"		opt=\"$prev\"\n"
"		completing_value=1\n"
"	elif [[ $cur != -* ]] && [[ $cur != \"\" ]] && [[ $prev == \"=\" ]] && [[ ${words[$cword-2]} == --* ]]; then\n"
"		opt=\"${words[$cword-2]}\"\n"
"		val=\"$cur\"\n"
"		completing_value=1\n"
"	elif [[ $cur != -* ]] && [[ $cur != \"\" ]] && [[ $prev == --* ]]; then\n"
"		opt=\"$prev\"\n"
"		val=\"$cur\"\n"
"		completing_value=1\n"
"	elif [[ $cur == \"\" ]] && [[ $prev == --* ]]; then\n"
"		opt=\"$prev\"\n"
"		completing_value=1\n"
"	elif [[ $cur == \"\" ]] && [[ $prev == \"=\" ]]; then\n"
"		opt=\"${words[$cword-2]}\"\n"
"		completing_value=1\n"
"	elif [[ $cur == \"\" ]] && [[ $prev == -? ]]; then\n"
"		opt=\"$prev\"\n"
"		completing_value=1\n"
"	elif [[ $cur != -* ]] && [[ $cur != \"\" ]] && [[ $prev == -? ]]; then\n"
"		opt=\"$prev\"\n"
"		val=\"$cur\"\n"
"		completing_value=1\n"
"	fi\n"
"}\n";

/* Emit the option tokens for one option: "--name=" / "--name" plus " -s". */
static void bash_emit_option(FILE *out, const struct gen_option *o)
{
	if (!opt_is_emittable(o))
		return;

	fprintf(out, " --%s%s", o->option, opt_takes_value(o) ? "=" : "");
	if (o->short_option)
		fprintf(out, " -%c", o->short_option);
}

/*
 * Emit a value-completion case arm for any option whose values we can derive:
 * output-format (hard-coded to match DESC_OUTPUT_FORMAT), output-format-version,
 * and any option carrying an opt_val table.
 */
static void bash_emit_value_arm(FILE *out, const struct gen_option *o)
{
	const struct argconfig_opt_val *v;

	if (!strcmp(o->option, "output-format")) {
		fprintf(out, "\t\t\t\t--output-format|-o)\n"
#ifdef CONFIG_JSONC
			     "\t\t\t\tvals+=\" normal json binary tabular\"\n"
#else
			     "\t\t\t\tvals+=\" normal binary tabular\"\n"
#endif
			     "\t\t\t\t\t;;\n");
		return;
	}
	if (!strcmp(o->option, "output-format-version")) {
		fprintf(out, "\t\t\t\t--output-format-version)\n"
			     "\t\t\t\tvals+=\" 1 2\"\n"
			     "\t\t\t\t\t;;\n");
		return;
	}
	if (!o->opt_val)
		return;

	fprintf(out, "\t\t\t\t--%s", o->option);
	if (o->short_option)
		fprintf(out, "|-%c", o->short_option);
	fprintf(out, ")\n\t\t\t\tvals+=\"");
	for (v = o->opt_val; v->str; v++)
		fprintf(out, " %s", v->str);
	fprintf(out, "\"\n\t\t\t\t\t;;\n");
}

/* The per-command case body: command-specific options on one line. */
static void bash_emit_command_opts(FILE *out, const struct gen_command *c)
{
	size_t i;

	fprintf(out, "\t\t\"%s\")\n\t\topts+=\"", c->name);
	for (i = 0; i < c->n_options; i++) {
		if (opt_is_global_separator(&c->options[i]))
			break;
		bash_emit_option(out, &c->options[i]);
	}
	fprintf(out, "\"\n\t\t\t;;\n");
}

/*
 * Emit one bash function covering all commands of a plugin. Mirrors the
 * hand-written plugin_feat_opts(): device guard, value detection, a shared
 * arm for the global options + value completion, then per-command options.
 */
static void bash_emit_plugin_func(FILE *out, const struct gen_plugin *p,
				  const char *func, int device_argpos)
{
	const struct gen_command *globals_from = NULL;
	size_t i, j;

	fprintf(out,
		"\n%s () {\n"
		"\tlocal opts=\"\"\n"
		"\tlocal compargs=\"\"\n"
		"\tlocal vals=\"\"\n"
		"\tlocal opt=\"\"\n"
		"\tlocal val=\"\"\n"
		"\n"
		"\tlocal nonopt_args=0\n"
		"\tlocal has_device=0\n"
		"\tfor (( i=0; i < ${#words[@]}-1; i++ )); do\n"
		"\t\tif [[ ${words[i]} != -* ]] && [[ ${words[i]} != \"=\" ]]; then\n"
		"\t\t\tlet nonopt_args+=1\n"
		"\t\t\tif [[ ${words[i]} == /dev/* ]]; then\n"
		"\t\t\t\thas_device=1\n"
		"\t\t\tfi\n"
		"\t\tfi\n"
		"\tdone\n"
		"\n"
		"\tif [[ $nonopt_args -ge %d ]] && [[ $has_device -eq 0 ]] && \\\n"
		"\t   [[ \"$1\" != \"help\" ]] && [[ \"$1\" != \"version\" ]]; then\n"
		"\t\topts=\"/dev/nvme* \"\n"
		"\tfi\n"
		"\n"
		"\topts+=\" \"\n"
		"\tvals+=\" \"\n"
		"\n"
		"\tlocal completing_value=0\n"
		"\t_nvme_detect_value_completion\n"
		"\n",
		func, device_argpos);

	/* Find a captured command to source the global option block from. */
	for (i = 0; i < p->n_commands; i++) {
		if (p->commands[i].captured) {
			globals_from = &p->commands[i];
			break;
		}
	}

	/* Shared arm: global options and value completion for every command
	 * except the meta (help/version) commands. */
	fprintf(out, "\tcase \"$1\" in\n\t\t\"version\"|\"help\")\n\t\t\t;;\n\t\t*)\n\t\topts+=\"");
	if (globals_from) {
		bool in_globals = false;

		for (j = 0; j < globals_from->n_options; j++) {
			const struct gen_option *o = &globals_from->options[j];

			if (opt_is_global_separator(o)) {
				in_globals = true;
				continue;
			}
			if (in_globals)
				bash_emit_option(out, o);
		}
	}
	fprintf(out, "\"\n");
	fprintf(out, "\t\tif [[ $completing_value -eq 1 ]]; then\n\t\t\tcase $opt in\n");
	if (globals_from) {
		bool in_globals = false;

		for (j = 0; j < globals_from->n_options; j++) {
			const struct gen_option *o = &globals_from->options[j];

			if (opt_is_global_separator(o)) {
				in_globals = true;
				continue;
			}
			if (in_globals && opt_is_emittable(o))
				bash_emit_value_arm(out, o);
		}
	}
	fprintf(out, "\t\t\tesac\n\t\tfi\n\t\t\t;;\n\tesac\n\n");

	/* Per-command specific options. */
	fprintf(out, "\tcase \"$1\" in\n");
	for (i = 0; i < p->n_commands; i++) {
		if (command_is_meta(&p->commands[i]))
			continue;
		bash_emit_command_opts(out, &p->commands[i]);
	}
	fprintf(out, "\tesac\n\n");

	fprintf(out,
		"\topts+=\" -h --help\"\n"
		"\n"
		"\tif [[ $vals == \" \" ]]; then\n"
		"\t\tCOMPREPLY+=( $( compgen $compargs -W \"$opts\" -- $cur ) )\n"
		"\t\t[[ ${COMPREPLY-} == *= ]] && compopt -o nospace\n"
		"\telse\n"
		"\t\tCOMPREPLY+=( $( compgen $compargs -W \"$vals\" -- $val ) )\n"
		"\tfi\n"
		"\n"
		"\treturn 0\n"
		"}\n");
}

static const struct gen_plugin *model_builtin(const struct gen_program *m)
{
	size_t i;

	for (i = 0; i < m->n_plugins; i++)
		if (!m->plugins[i].name)
			return &m->plugins[i];

	return NULL;
}

static void bash_func_name(char *buf, size_t len, const char *plugin)
{
	snprintf(buf, len, "plugin_%s_opts", plugin);
}

static void gen_bash(const struct gen_program *m, FILE *out)
{
	const struct gen_plugin *builtin = model_builtin(m);
	size_t i, j;

	fputs(bash_header, out);

	/* Builtin (top-level) commands. */
	if (builtin)
		bash_emit_plugin_func(out, builtin, "nvme_list_opts", 2);

	/* One function per plugin. */
	for (i = 0; i < m->n_plugins; i++) {
		char func[128];

		if (!m->plugins[i].name)
			continue;
		bash_func_name(func, sizeof(func), m->plugins[i].name);
		bash_emit_plugin_func(out, &m->plugins[i], func, 3);
	}

	/* Dispatcher. */
	fputs("\n_nvme_subcmds () {\n"
	      "\tlocal cur prev words cword\n"
	      "\t_init_completion || return\n"
	      "\n"
	      "\ttypeset -Ar _plugin_subcmds=(\n", out);
	for (i = 0; i < m->n_plugins; i++) {
		if (!m->plugins[i].name)
			continue;
		fprintf(out, "\t\t[%s]=\"", m->plugins[i].name);
		for (j = 0; j < m->plugins[i].n_commands; j++)
			fprintf(out, "%s%s", j ? " " : "", m->plugins[i].commands[j].name);
		fputs("\"\n", out);
	}
	fputs("\t)\n\n\ttypeset -Ar _plugin_funcs=(\n", out);
	for (i = 0; i < m->n_plugins; i++) {
		char func[128];

		if (!m->plugins[i].name)
			continue;
		bash_func_name(func, sizeof(func), m->plugins[i].name);
		fprintf(out, "\t\t[%s]=\"%s\"\n", m->plugins[i].name, func);
	}
	fputs("\t)\n\n\t_cmds=\"", out);
	if (builtin) {
		for (j = 0; j < builtin->n_commands; j++)
			fprintf(out, "%s%s", j ? " " : "", builtin->commands[j].name);
	}
	for (i = 0; i < m->n_plugins; i++) {
		if (!m->plugins[i].name)
			continue;
		fprintf(out, " %s", m->plugins[i].name);
	}
	fputs("\"\n\n"
	      "\tif [[ ${#words[*]} -lt 3 ]]; then\n"
	      "\t\tCOMPREPLY+=( $(compgen -W \"$_cmds\" -- $cur ) )\n"
	      "\telse\n"
	      "\t\tfor subcmd in \"${!_plugin_subcmds[@]}\"; do\n"
	      "\t\t\tif [[ ${words[1]} == $subcmd ]]; then\n"
	      "\t\t\t\tif [[ ${#words[*]} -lt 4 ]]; then\n"
	      "\t\t\t\t\tCOMPREPLY+=( $(compgen -W \"${_plugin_subcmds[$subcmd]}\" -- $cur ) )\n"
	      "\t\t\t\telse\n"
	      "\t\t\t\t\tfunc=${_plugin_funcs[$subcmd]}\n"
	      "\t\t\t\t\t$func ${words[2]} $prev\n"
	      "\t\t\t\tfi\n"
	      "\t\t\t\treturn 0\n"
	      "\t\t\tfi\n"
	      "\t\tdone\n"
	      "\n"
	      "\t\tnvme_list_opts ${words[1]} $prev\n"
	      "\tfi\n"
	      "\n"
	      "\treturn 0\n"
	      "}\n"
	      "\ncomplete -o default -F _nvme_subcmds nvme\n", out);
}

/* ------------------------------------------------------------------ */
/* Pass 2: zsh                                                        */
/* ------------------------------------------------------------------ */

static const char zsh_header[] =
"#compdef _nvme nvme\n"
"# SPDX-License-Identifier: GPL-2.0-or-later\n"
"#\n"
"# zsh completions for the nvme command-line interface\n"
"#\n"
"# This file is generated by `nvme gen-completions zsh`. Do not edit.\n";

static const char zsh_helpers[] =
"\t# Describe options, giving those ending in '=' no trailing space.\n"
"\t_nvme_describe() {\n"
"\t\tlocal desc=\"$1\"\n"
"\t\tlocal -a opts=(\"${(@P)2}\")\n"
"\t\tlocal -a eq_opts noeq_opts\n"
"\t\tlocal opt\n"
"\n"
"\t\tfor opt in \"${opts[@]}\"; do\n"
"\t\t\tif [[ \"${opt%%:*}\" == *= ]]; then\n"
"\t\t\t\teq_opts+=(\"$opt\")\n"
"\t\t\telse\n"
"\t\t\t\tnoeq_opts+=(\"$opt\")\n"
"\t\t\tfi\n"
"\t\tdone\n"
"\n"
"\t\t(( ${#noeq_opts} )) && _describe -t options \"$desc\" noeq_opts\n"
"\t\t(( ${#eq_opts} )) && _describe -t eq-options \"$desc\" eq_opts -S ''\n"
"\t}\n"
"\n"
"\t# Complete the value of an option (both --opt=val and --opt val forms).\n"
"\t# Usage: _nvme_complete_option_value \"long|short\" value1 value2 ...\n"
"\t_nvme_complete_option_value() {\n"
"\t\tlocal -a opts=(\"${(s:|:)1}\")\n"
"\t\tshift\n"
"\t\tlocal -a values=(\"$@\")\n"
"\n"
"\t\tlocal opt\n"
"\t\tfor opt in \"${opts[@]}\"; do\n"
"\t\t\tif [[ ${words[CURRENT]} == ${opt}=* ]]; then\n"
"\t\t\t\t_values '' \"${values[@]}\"\n"
"\t\t\t\treturn 0\n"
"\t\t\tfi\n"
"\t\t\tif [[ ${words[CURRENT-1]} == ${opt} ]]; then\n"
"\t\t\t\t_values '' \"${values[@]}\"\n"
"\t\t\t\treturn 0\n"
"\t\t\tfi\n"
"\t\tdone\n"
"\t\treturn 1\n"
"\t}\n";

/* Print s single-quote-escaped for inclusion inside a zsh '...' string. */
static void zsh_print_escaped(FILE *out, const char *s)
{
	if (!s)
		return;
	for (; *s; s++) {
		if (*s == '\'')
			fputs("'\\''", out);
		else
			fputc(*s, out);
	}
}

/* A zsh-safe local variable name derived from plugin + command. */
static void zsh_var_name(char *buf, size_t len, const char *plugin, const char *cmd)
{
	size_t n = 0;
	const char *p;

	if (n < len - 1)
		buf[n++] = '_';
	for (p = plugin; p && *p && n < len - 1; p++)
		buf[n++] = (*p == '-') ? '_' : *p;
	if (plugin && *plugin && n < len - 1)
		buf[n++] = '_';
	for (p = cmd; p && *p && n < len - 1; p++)
		buf[n++] = (*p == '-') ? '_' : *p;
	buf[n] = '\0';
}

/* Emit "_nvme_complete_option_value ... && return" lines for options whose
 * value set we can derive (output-format, output-format-version, opt_val). */
static void zsh_emit_value_completions(FILE *out, const char *tab,
				       const struct gen_command *c)
{
	const struct argconfig_opt_val *v;
	size_t i;

	for (i = 0; i < c->n_options; i++) {
		const struct gen_option *o = &c->options[i];

		if (!opt_is_emittable(o))
			continue;

		if (!strcmp(o->option, "output-format")) {
			fprintf(out, "%s_nvme_complete_option_value \"--output-format|-o\" "
#ifdef CONFIG_JSONC
				     "normal json binary tabular && return\n",
#else
				     "normal binary tabular && return\n",
#endif
				tab);
		} else if (!strcmp(o->option, "output-format-version")) {
			fprintf(out, "%s_nvme_complete_option_value \"--output-format-version\" "
				     "1 2 && return\n", tab);
		} else if (o->opt_val) {
			fprintf(out, "%s_nvme_complete_option_value \"--%s", tab, o->option);
			if (o->short_option)
				fprintf(out, "|-%c", o->short_option);
			fputc('"', out);
			for (v = o->opt_val; v->str; v++)
				fprintf(out, " %s", v->str);
			fputs(" && return\n", out);
		}
	}
}

/* Emit one command's option array as --opt=':help' / -s':alias' pairs. */
static void zsh_emit_option(FILE *out, const struct gen_option *o)
{
	if (!opt_is_emittable(o))
		return;

	fprintf(out, "\t--%s%s':", o->option, opt_takes_value(o) ? "=" : "");
	zsh_print_escaped(out, o->help);
	fputs("'\n", out);
	if (o->short_option) {
		fprintf(out, "\t-%c':alias for --%s'\n", o->short_option, o->option);
	}
}

/* Emit the case arm for one command. tab is the leading indentation. */
static void zsh_emit_command_arm(FILE *out, const char *tab, const char *path,
				 const struct gen_command *c)
{
	char var[160];
	size_t i;

	fprintf(out, "%s(%s)\n", tab, c->name);

	/* Commands that never reach the parser (e.g. gen-hostnqn) and the
	 * meta commands have no options: match the arm and offer nothing. */
	if (c->no_args || command_is_meta(c)) {
		fprintf(out, "%s\t;;\n", tab);
		return;
	}

	zsh_emit_value_completions(out, tab, c);

	zsh_var_name(var, sizeof(var), path, c->name);
	fprintf(out, "%slocal %s\n%s%s=(\n", tab, var, tab, var);
	for (i = 0; i < c->n_options; i++)
		zsh_emit_option(out, &c->options[i]);
	fprintf(out, "%s)\n", tab);
	fprintf(out, "%s_arguments '*:: :->subcmds'\n", tab);
	fprintf(out, "%s_nvme_describe \"nvme %s%s%s options\" %s\n", tab,
		path ? path : "", path ? " " : "", c->name, var);
	fprintf(out, "%scompadd -- /dev/nvme*(N)\n", tab);
	fprintf(out, "%s\t;;\n", tab);
}

static void gen_zsh(const struct gen_program *m, FILE *out)
{
	const struct gen_plugin *builtin = model_builtin(m);
	size_t i, j;

	fputs(zsh_header, out);
	fputs("\n_nvme () {\n\tlocal -a _cmds\n\t_cmds=(\n", out);
	if (builtin) {
		for (j = 0; j < builtin->n_commands; j++) {
			const struct gen_command *c = &builtin->commands[j];

			fputs("\t'", out);
			fputs(c->name, out);
			fputc(':', out);
			zsh_print_escaped(out, c->help);
			fputs("'\n", out);
		}
	}
	for (i = 0; i < m->n_plugins; i++) {
		if (!m->plugins[i].name)
			continue;
		fputs("\t'", out);
		fputs(m->plugins[i].name, out);
		fputc(':', out);
		zsh_print_escaped(out, m->plugins[i].desc);
		fputs("'\n", out);
	}
	fputs("\t)\n\n", out);

	fputs(zsh_helpers, out);

	fputs("\n\tlocal expl\n\n"
	      "\t_arguments '*:: :->subcmds' && return 0\n\n"
	      "\tif (( CURRENT == 1 )); then\n"
	      "\t\t_describe -t commands \"nvme subcommands\" _cmds\n"
	      "\t\treturn\n"
	      "\telif (( CURRENT > 2 )); then\n"
	      "\t\tcase ${words[1]} in\n", out);

	/* Plugin arms: dispatch on the subcommand. */
	for (i = 0; i < m->n_plugins; i++) {
		const struct gen_plugin *p = &m->plugins[i];

		if (!p->name)
			continue;
		fprintf(out, "\t\t(%s)\n\t\t\tcase ${words[2]} in\n", p->name);
		for (j = 0; j < p->n_commands; j++)
			zsh_emit_command_arm(out, "\t\t\t", p->name, &p->commands[j]);
		fputs("\t\t\t(*)\n\t\t\t\t_files\n\t\t\t\t;;\n", out);
		fputs("\t\t\tesac\n\t\t\t;;\n", out);
	}

	/* Builtin (top-level) command arms. */
	if (builtin) {
		for (j = 0; j < builtin->n_commands; j++)
			zsh_emit_command_arm(out, "\t\t", NULL, &builtin->commands[j]);
	}

	fputs("\t\t(*)\n\t\t\t_files\n\t\t\t;;\n"
	      "\t\tesac\n\t\treturn\n\tfi\n\n"
	      "\t_files\n}\n", out);
}

/* ------------------------------------------------------------------ */
/* Pass 2: powershell                                                 */
/* ------------------------------------------------------------------ */

static const char ps_header[] =
"# SPDX-License-Identifier: GPL-2.0-or-later\n"
"#\n"
"# PowerShell argument completer for the nvme command line utility.\n"
"#\n"
"# This file is generated by `nvme gen-completions powershell`. Do not edit.\n"
"# Source it from your PowerShell profile to enable completion.\n";

/* Print s with PowerShell single-quote escaping (double any single quote). */
static void ps_print_escaped(FILE *out, const char *s)
{
	if (!s)
		return;
	for (; *s; s++) {
		if (*s == '\'')
			fputc('\'', out);
		fputc(*s, out);
	}
}

/* Emit "'--opt','-s'," option tokens for a command into a PowerShell array. */
static void ps_emit_command(FILE *out, const char *path, const struct gen_command *c)
{
	size_t i;

	fprintf(out, "    '");
	if (path && *path) {
		ps_print_escaped(out, path);
		fputc(' ', out);
	}
	ps_print_escaped(out, c->name);
	fputs("' = @(", out);

	if (!c->no_args && !command_is_meta(c)) {
		bool first = true;

		for (i = 0; i < c->n_options; i++) {
			const struct gen_option *o = &c->options[i];

			if (!opt_is_emittable(o))
				continue;
			fprintf(out, "%s'--%s'", first ? "" : ", ", o->option);
			first = false;
			if (o->short_option)
				fprintf(out, ", '-%c'", o->short_option);
		}
	}
	fputs(")\n", out);
}

static void gen_powershell(const struct gen_program *m, FILE *out)
{
	const struct gen_plugin *builtin = model_builtin(m);
	size_t i, j;

	fputs(ps_header, out);

	/* Top-level command list. */
	fputs("\n$script:NvmeCommands = @(\n", out);
	if (builtin) {
		for (j = 0; j < builtin->n_commands; j++)
			fprintf(out, "    '%s'\n", builtin->commands[j].name);
	}
	for (i = 0; i < m->n_plugins; i++) {
		if (!m->plugins[i].name)
			continue;
		fprintf(out, "    '%s'\n", m->plugins[i].name);
	}
	fputs(")\n", out);

	/* Plugin -> subcommand list. */
	fputs("\n$script:NvmePluginCommands = @{\n", out);
	for (i = 0; i < m->n_plugins; i++) {
		const struct gen_plugin *p = &m->plugins[i];

		if (!p->name)
			continue;
		fprintf(out, "    '%s' = @(", p->name);
		for (j = 0; j < p->n_commands; j++)
			fprintf(out, "%s'%s'", j ? ", " : "", p->commands[j].name);
		fputs(")\n", out);
	}
	fputs("}\n", out);

	/* Per-command options, keyed by "cmd" or "plugin cmd". */
	fputs("\n$script:NvmeOptions = @{\n", out);
	if (builtin) {
		for (j = 0; j < builtin->n_commands; j++)
			ps_emit_command(out, NULL, &builtin->commands[j]);
	}
	for (i = 0; i < m->n_plugins; i++) {
		const struct gen_plugin *p = &m->plugins[i];

		if (!p->name)
			continue;
		for (j = 0; j < p->n_commands; j++)
			ps_emit_command(out, p->name, &p->commands[j]);
	}
	fputs("}\n", out);

	/* The completer. */
	fputs("\n"
	      "Register-ArgumentCompleter -Native -CommandName nvme -ScriptBlock {\n"
	      "    param($wordToComplete, $commandAst, $cursorPosition)\n"
	      "\n"
	      "    $tokens = $commandAst.CommandElements | ForEach-Object { $_.ToString() }\n"
	      "    # tokens[0] is 'nvme'. Determine command context.\n"
	      "    $nonOpt = @($tokens[1..($tokens.Count-1)] | Where-Object { $_ -notlike '-*' })\n"
	      "\n"
	      "    # Completing the (sub)command name itself.\n"
	      "    if ($nonOpt.Count -le 1) {\n"
	      "        return $script:NvmeCommands | Where-Object { $_ -like \"$wordToComplete*\" } |\n"
	      "            ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }\n"
	      "    }\n"
	      "\n"
	      "    $first = $nonOpt[0]\n"
	      "    $key = $null\n"
	      "    if ($script:NvmePluginCommands.ContainsKey($first)) {\n"
	      "        if ($nonOpt.Count -le 2) {\n"
	      "            return $script:NvmePluginCommands[$first] | Where-Object { $_ -like \"$wordToComplete*\" } |\n"
	      "                ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }\n"
	      "        }\n"
	      "        $key = \"$first $($nonOpt[1])\"\n"
	      "    } else {\n"
	      "        $key = $first\n"
	      "    }\n"
	      "\n"
	      "    if ($script:NvmeOptions.ContainsKey($key)) {\n"
	      "        return $script:NvmeOptions[$key] | Where-Object { $_ -like \"$wordToComplete*\" } |\n"
	      "            ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterName', $_) }\n"
	      "    }\n"
	      "}\n", out);
}

/* ------------------------------------------------------------------ */
/* Entry point                                                        */
/* ------------------------------------------------------------------ */

int gen_run(int argc, char **argv, struct program *prog)
{
	struct gen_program *model;
	const char *shell;

	if (argc < 2) {
		fprintf(stderr, "usage: nvme gen-completions <bash|zsh|powershell>\n");
		return -EINVAL;
	}
	shell = argv[1];

	model = gen_build_model(prog);
	if (!model)
		return -ENOMEM;

	if (!strcmp(shell, "bash"))
		gen_bash(model, stdout);
	else if (!strcmp(shell, "zsh"))
		gen_zsh(model, stdout);
	else if (!strcmp(shell, "powershell"))
		gen_powershell(model, stdout);
	else {
		fprintf(stderr, "unknown shell '%s' (expected bash|zsh|powershell)\n", shell);
		return -EINVAL;
	}

	return 0;
}
