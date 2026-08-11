// SPDX-License-Identifier: LGPL-2.1-or-later
/*
 * This file is part of nvme-cli.
 * Copyright (c) 2026 SUSE Software Solutions
 *
 * Authors: Daniel Wagner <dwagner@suse.de>
 */

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <shr-assert.h>

#ifdef _WIN32
#define popen _popen
#define pclose _pclose
#else
#include <sys/wait.h>
#endif

/*
 * Re-invoked with this argument, the test becomes the child whose failing
 * assertion is under test. Windows has no fork(), so the child is a fresh
 * process running this same binary rather than a copy of it.
 */
#define CHILD_ARG "--assert-child"

static bool check_bool(const char *name, bool got, bool want)
{
	if (got == want) {
		printf(" - %s [PASS]\n", name);
		return true;
	}

	printf(" - %s: got %d, want %d [FAIL]\n", name, got, want);
	return false;
}

/*
 * shr_assert() must be a no-op when the condition holds: no output, no
 * termination.
 */
static bool test_pass_is_silent(void)
{
	printf("test_pass_is_silent:\n");

	shr_assert(1 == 1);

	return check_bool("condition true", true, true);
}

/*
 * The child half of test_fail_flushes_and_reports(): print unterminated
 * (buffered) output, then fail a shr_assert(). Never returns.
 */
static void assert_child(void)
{
	/* Unterminated: only survives if something flushes it. */
	printf("marker-before-failure");
	shr_assert(1 == 2);
	_Exit(EXIT_SUCCESS); /* unreachable */
}

/*
 * Run this binary again as a child that fails an assertion. Capture
 * everything it writes to stdout/stderr and how it exits, to verify:
 *  - the buffered output written before the failure was not lost, i.e.
 *    fflush(NULL) actually flushes stdio buffers before exiting - the
 *    exact case plain assert()/abort() gets wrong.
 *  - the diagnostic names this file and the failing condition text.
 *  - the process exits normally instead of being killed by a signal
 *    (contrasts with assert()'s SIGABRT via abort()).
 */
static bool test_fail_flushes_and_reports(const char *self)
{
	char buf[4096] = { 0 };
	char cmd[4096];
	size_t total = 0;
	bool pass = true;
	FILE *child;
	int status;

	printf("test_fail_flushes_and_reports:\n");

	/*
	 * 2>&1 so the diagnostic on stderr and the marker on stdout arrive
	 * interleaved on the one pipe, as they did through the shared fd pair
	 * this test used before.
	 */
	if (snprintf(cmd, sizeof(cmd), "\"%s\" " CHILD_ARG " 2>&1", self) >=
	    (int)sizeof(cmd)) {
		printf(" - own path too long to re-invoke [FAIL]\n");
		return false;
	}

	child = popen(cmd, "r");
	if (!child) {
		printf(" - popen() failed [FAIL]\n");
		return false;
	}

	total = fread(buf, 1, sizeof(buf) - 1, child);
	buf[total] = '\0';

	status = pclose(child);

	/*
	 * pclose() hands back a wait status on POSIX but the child's exit code
	 * directly on Windows. Either way a signal death shows up as something
	 * other than a clean nonzero exit, which is what this asserts.
	 */
#ifdef _WIN32
	pass &= check_bool("child exited (not signaled)", status >= 0, true);
	pass &= check_bool("child exit status nonzero", status != 0, true);
#else
	pass &= check_bool("child exited (not signaled)", WIFEXITED(status), true);
	if (WIFEXITED(status))
		pass &= check_bool("child exit status nonzero",
				   WEXITSTATUS(status) != 0, true);
#endif

	pass &= check_bool("buffered output before failure survived",
			   strstr(buf, "marker-before-failure") != NULL, true);
	pass &= check_bool("diagnostic names this file",
			   strstr(buf, "test-shr-assert.c") != NULL, true);
	pass &= check_bool("diagnostic names failing condition",
			   strstr(buf, "1 == 2") != NULL, true);

	if (!pass)
		printf(" - captured output:\n%s\n", buf);

	return pass;
}

int main(int argc, char *argv[])
{
	bool pass = true;

	if (argc > 1 && !strcmp(argv[1], CHILD_ARG))
		assert_child();

	pass &= test_pass_is_silent();
	pass &= test_fail_flushes_and_reports(argv[0]);

	fflush(stdout);
	exit(pass ? EXIT_SUCCESS : EXIT_FAILURE);
}
