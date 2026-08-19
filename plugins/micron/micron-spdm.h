/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Copyright (c) 2026 Micron Technology, Inc.
 *
 * Authors: Broc Going <bgoing@micron.com>
 */
#pragma once

struct command;
struct plugin;

/**
 * micron_spdm_cert() - "nvme micron vs-spdm-cert" command entry point
 * @argc:	Argument count
 * @argv:	Argument vector
 * @cmd:	Command being run
 * @plugin:	Plugin the command belongs to
 *
 * Runs the SPDM requester handshake over the NVMe Security Send/Receive
 * transport, retrieves the certificate chain from the requested slot, and
 * reports whether the device presents a self-signed certificate or a full
 * chain.
 *
 * Return: 0 on success, negative errno or an NVMe status on failure.
 */
int micron_spdm_cert(int argc, char **argv, struct command *cmd,
		     struct plugin *plugin);
