// SPDX-License-Identifier: LGPL-2.1-or-later
/*
 * This file is part of nvme-cli.
 * Copyright (c) 2026 Micron Technology, Inc.
 *
 * Authors: Broc Going <bgoing@micron.com>
 */
#include <errno.h>
#include <sys/wait.h>
#include <unistd.h>

#include "proc-util.h"

int shr_pipe(int fds[2])
{
	return pipe(fds) ? -errno : 0;
}

int shr_spawn_sync(const char *const argv[], int out_fd, int err_fd,
		   bool *exited, int *code)
{
	int status;
	pid_t pid;

	pid = fork();
	if (pid < 0)
		return -errno;

	if (pid == 0) {
		if (out_fd >= 0)
			dup2(out_fd, STDOUT_FILENO);
		if (err_fd >= 0)
			dup2(err_fd, STDERR_FILENO);

		execv(argv[0], (char *const *)argv);
		_exit(127); /* exec failed */
	}

	while (waitpid(pid, &status, 0) < 0) {
		if (errno != EINTR)
			return -errno;
	}

	*exited = WIFEXITED(status);
	*code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;

	return 0;
}
