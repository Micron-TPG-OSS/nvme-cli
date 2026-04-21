// SPDX-License-Identifier: LGPL-2.1-or-later
/*
 * This file is part of libnvme.
 * Copyright (c) 2025 Micron Technology, Inc.
 *
 * Windows stub implementations for Linux-specific functionality
 * that is excluded from the Windows build (tree, filters, etc.)
 */

#include <errno.h>
#include <stdio.h>

#include <nvme/linux.h>
#include <nvme/types.h>

#include "private.h"
#include "tree.h"
#include "compiler-attributes.h"

/* Logging control for stub calls */
static int stub_log_enabled = 0;

static void stub_log(const char *func)
{
	if (stub_log_enabled)
		fprintf(stderr, "libnvme-stub: %s() called (not supported on Windows)\n", func);
}

void libnvme_stubs_set_debug(int enable)
{
	stub_log_enabled = enable;
}

/*
 * Stub implementations for tree functions (tree.c)
 * Minimal support - just return NULL/errors
 */
void __libnvme_free_host(struct libnvme_host *h)
{
	stub_log(__func__);
	(void)h;
}

__public int libnvme_scan_ctrl(struct libnvme_global_ctx *ctx, const char *name, libnvme_ctrl_t *c)
{
	stub_log(__func__);
	(void)ctx;
	(void)name;
	(void)c;
	errno = ENOTSUP;
	return -1;
}

__public int libnvme_scan_namespace(struct libnvme_global_ctx *ctx,
		const char *name, libnvme_ns_t *ns)
{
	stub_log(__func__);
	(void)ctx;
	(void)name;
	if (ns)
		*ns = NULL;
	return -ENOTSUP;
}

__public int libnvme_scan_topology(struct libnvme_global_ctx *ctx, libnvme_scan_filter_t f, void *f_args)
{
	stub_log(__func__);
	(void)ctx;
	(void)f;
	(void)f_args;
	errno = ENOTSUP;
	return -1;
}

__public libnvme_host_t libnvme_first_host(struct libnvme_global_ctx *ctx)
{
	stub_log(__func__);
	(void)ctx;
	return NULL;
}

__public libnvme_host_t libnvme_next_host(struct libnvme_global_ctx *ctx, libnvme_host_t h)
{
	stub_log(__func__);
	(void)ctx;
	(void)h;
	return NULL;
}

libnvme_host_t libnvme_lookup_host(struct libnvme_global_ctx *ctx, const char *hostnqn, const char *hostid)
{
	stub_log(__func__);
	(void)ctx;
	(void)hostnqn;
	(void)hostid;
	return NULL;
}

__public libnvme_subsystem_t libnvme_first_subsystem(libnvme_host_t h)
{
	stub_log(__func__);
	(void)h;
	return NULL;
}

__public libnvme_subsystem_t libnvme_next_subsystem(libnvme_host_t h, libnvme_subsystem_t s)
{
	stub_log(__func__);
	(void)h;
	(void)s;
	return NULL;
}

libnvme_subsystem_t libnvme_lookup_subsystem(struct libnvme_host *h, const char *name, const char *subsysnqn)
{
	stub_log(__func__);
	(void)h;
	(void)name;
	(void)subsysnqn;
	return NULL;
}

libnvme_ctrl_t libnvme_lookup_ctrl(libnvme_subsystem_t s,
			     struct libnvmf_context *fctx,
			     libnvme_ctrl_t p)
{
	stub_log(__func__);
	(void)s;
	(void)fctx;
	(void)p;
	return NULL;
}

__public libnvme_ns_t libnvme_ctrl_first_ns(libnvme_ctrl_t c)
{
	stub_log(__func__);
	(void)c;
	return NULL;
}

__public libnvme_ns_t libnvme_ctrl_next_ns(libnvme_ctrl_t c, libnvme_ns_t n)
{
	stub_log(__func__);
	(void)c;
	(void)n;
	return NULL;
}

__public libnvme_path_t libnvme_ctrl_first_path(libnvme_ctrl_t c)
{
	stub_log(__func__);
	(void)c;
	return NULL;
}

__public libnvme_path_t libnvme_ctrl_next_path(libnvme_ctrl_t c, libnvme_path_t p)
{
	stub_log(__func__);
	(void)c;
	(void)p;
	return NULL;
}

__public libnvme_subsystem_t libnvme_ns_get_subsystem(libnvme_ns_t n)
{
	stub_log(__func__);
	(void)n;
	return NULL;
}

__public libnvme_ctrl_t libnvme_ns_get_ctrl(libnvme_ns_t n)
{
	stub_log(__func__);
	(void)n;
	return NULL;
}

__public enum nvme_csi libnvme_ns_get_csi(libnvme_ns_t n)
{
	stub_log(__func__);
	(void)n;
	return 0;
}

__public const uint8_t *libnvme_ns_get_eui64(libnvme_ns_t n)
{
	stub_log(__func__);
	(void)n;
	return NULL;
}

__public const uint8_t *libnvme_ns_get_nguid(libnvme_ns_t n)
{
	stub_log(__func__);
	(void)n;
	return NULL;
}

__public void libnvme_ns_get_uuid(libnvme_ns_t n, unsigned char out[NVME_UUID_LEN])
{
	stub_log(__func__);
	(void)n;
	(void)out;
}

int libnvme_ns_get_transport_handle(libnvme_ns_t n,
		struct libnvme_transport_handle **hdl)
{
	stub_log(__func__);
	(void)n;
	(void)hdl;
	return -ENOTSUP;
}

__public int libnvme_ns_identify(libnvme_ns_t n, struct nvme_id_ns *ns)
{
	stub_log(__func__);
	(void)n;
	(void)ns;
	errno = ENOTSUP;
	return -1;
}

__public const char *libnvme_ns_get_generic_name(libnvme_ns_t n)
{
	stub_log(__func__);
	(void)n;
	return "";
}

__public libnvme_ctrl_t libnvme_path_get_ctrl(libnvme_path_t p)
{
	stub_log(__func__);
	(void)p;
	return NULL;
}

__public libnvme_ns_t libnvme_path_get_ns(libnvme_path_t p)
{
	stub_log(__func__);
	(void)p;
	return NULL;
}

__public const char *libnvme_ctrl_get_state(libnvme_ctrl_t c)
{
	stub_log(__func__);
	(void)c;
	return "";
}

__public libnvme_subsystem_t libnvme_ctrl_get_subsystem(libnvme_ctrl_t c)
{
	stub_log(__func__);
	(void)c;
	return NULL;
}

__public struct libnvme_transport_handle *libnvme_ctrl_get_transport_handle(libnvme_ctrl_t c)
{
	stub_log(__func__);
	(void)c;
	return NULL;
}

__public void libnvme_free_ctrl(struct libnvme_ctrl *c)
{
	stub_log(__func__);
	(void)c;
}

__public void libnvme_unlink_ctrl(struct libnvme_ctrl *c)
{
	stub_log(__func__);
	(void)c;
}

/* Subsystem functions (full name) - same as subsys */
__public libnvme_host_t libnvme_subsystem_get_host(libnvme_subsystem_t s)
{
	stub_log(__func__);
	(void)s;
	return NULL;
}

__public libnvme_ctrl_t libnvme_subsystem_first_ctrl(libnvme_subsystem_t s)
{
	stub_log(__func__);
	(void)s;
	return NULL;
}

__public libnvme_ctrl_t libnvme_subsystem_next_ctrl(libnvme_subsystem_t s, libnvme_ctrl_t c)
{
	stub_log(__func__);
	(void)s;
	(void)c;
	return NULL;
}

__public libnvme_ns_t libnvme_subsystem_first_ns(libnvme_subsystem_t s)
{
	stub_log(__func__);
	(void)s;
	return NULL;
}

__public libnvme_ns_t libnvme_subsystem_next_ns(libnvme_subsystem_t s, libnvme_ns_t n)
{
	stub_log(__func__);
	(void)s;
	(void)n;
	return NULL;
}

__public int libnvme_dump_tree(struct libnvme_global_ctx *ctx)
{
	stub_log(__func__);
	(void)ctx;
	errno = ENOTSUP;
	return -1;
}

__public int libnvme_dump_config(struct libnvme_global_ctx *ctx, int fd)
{
	stub_log(__func__);
	(void)ctx;
	(void)fd;
	errno = ENOTSUP;
	return -1;
}

/*
 * Additional stubs for nvme-cli linking
 */
/* Namespace property getters (tree.c) */
__public const char *libnvme_ns_get_firmware(libnvme_ns_t n)
{
	stub_log(__func__);
	(void)n;
	return "";
}

__public const char *libnvme_ns_get_model(libnvme_ns_t n)
{
	stub_log(__func__);
	(void)n;
	return "";
}

__public const char *libnvme_ns_get_serial(libnvme_ns_t n)
{
	stub_log(__func__);
	(void)n;
	return "";
}

/* Namespace path iteration (tree.c) */
__public libnvme_path_t libnvme_namespace_first_path(libnvme_ns_t ns)
{
	stub_log(__func__);
	(void)ns;
	return NULL;
}

__public libnvme_path_t libnvme_namespace_next_path(libnvme_ns_t ns, libnvme_path_t p)
{
	stub_log(__func__);
	(void)ns;
	(void)p;
	return NULL;
}

__public char *libnvme_read_hostnqn(void)
{
	stub_log(__func__);
	/* No /etc/nvme/hostnqn equivalent on Windows */
	return NULL;
}

/* Hostnqn generation */
__public char *libnvme_generate_hostnqn(void)
{
	stub_log(__func__);
	/* Could implement UUID-based generation, but for now just fail */
	return NULL;
}

/* Path property getters (tree.c) */
__public int libnvme_path_get_queue_depth(struct libnvme_path *p)
{
	stub_log(__func__);
	(void)p;
	return 0;
}
