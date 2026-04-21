// SPDX-License-Identifier: LGPL-2.1-or-later
/*
 * This file is part of libnvme.
 * Copyright (c) 2020 Western Digital Corporation or its affiliates.
 *
 * Authors: Keith Busch <keith.busch@wdc.com>
 * 	    Chaitanya Kulkarni <chaitanya.kulkarni@wdc.com>
 */

#include <errno.h>
#include <fcntl.h>
#ifndef _GNU_SOURCE
#include <libgen.h>
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <sys/param.h>
#include <sys/stat.h>

#ifndef _GNU_SOURCE
#include <libgen.h>
#endif

#include <libnvme.h>

#include "cleanup.h"
#include "cleanup-linux.h"
#include "private.h"
#include "compiler-attributes.h"

#define NVMF_HOSTID_SIZE	37

#define NVMF_HOSTNQN_FILE	SYSCONFDIR "/nvme/hostnqn"
#define NVMF_HOSTID_FILE	SYSCONFDIR "/nvme/hostid"

static int __nvme_set_attr(const char *path, const char *value)
{
	__cleanup_fd int fd = -1;

	fd = open(path, O_WRONLY);
	if (fd < 0) {
#if 0
		libnvme_msg(LIBNVME_LOG_DEBUG, "Failed to open %s: %s\n", path,
			 strerror(errno));
#endif
		return -errno;
	}
	return write(fd, value, strlen(value));
}

int libnvme_set_attr(const char *dir, const char *attr, const char *value)
{
	__cleanup_free char *path = NULL;
	int ret;

	ret = asprintf(&path, "%s/%s", dir, attr);
	if (ret < 0)
		return -ENOMEM;

	return __nvme_set_attr(path, value);
}

static char *__nvme_get_attr(const char *path)
{
	char value[4096] = { 0 };
	int ret, fd;
	int saved_errno;

	fd = open(path, O_RDONLY);
	if (fd < 0)
		return NULL;

	ret = read(fd, value, sizeof(value) - 1);
	saved_errno = errno;
	close(fd);
	if (ret < 0) {
		errno = saved_errno;
		return NULL;
	}
	errno = 0;
	if (!strlen(value))
		return NULL;

	if (value[strlen(value) - 1] == '\n')
		value[strlen(value) - 1] = '\0';
	while (strlen(value) > 0 && value[strlen(value) - 1] == ' ')
		value[strlen(value) - 1] = '\0';

	return strlen(value) ? strdup(value) : NULL;
}

__public char *libnvme_get_attr(const char *dir, const char *attr)
{
	__cleanup_free char *path = NULL;
	int ret;

	ret = asprintf(&path, "%s/%s", dir, attr);
	if (ret < 0)
		return NULL;

	return __nvme_get_attr(path);
}

__public char *libnvme_get_subsys_attr(libnvme_subsystem_t s, const char *attr)
{
	return libnvme_get_attr(libnvme_subsystem_get_sysfs_dir(s), attr);
}

__public char *libnvme_get_ctrl_attr(libnvme_ctrl_t c, const char *attr)
{
	return libnvme_get_attr(libnvme_ctrl_get_sysfs_dir(c), attr);
}

__public char *libnvme_get_ns_attr(libnvme_ns_t n, const char *attr)
{
	return libnvme_get_attr(libnvme_ns_get_sysfs_dir(n), attr);
}

__public char *libnvme_get_path_attr(libnvme_path_t p, const char *attr)
{
	return libnvme_get_attr(libnvme_path_get_sysfs_dir(p), attr);
}

static int uuid_from_device_tree(char *system_uuid)
{
	__cleanup_fd int f = -1;
	ssize_t len;

	f = open(libnvme_uuid_ibm_filename(), O_RDONLY);
	if (f < 0)
		return -ENXIO;

	memset(system_uuid, 0, NVME_UUID_LEN_STRING);
	len = read(f, system_uuid, NVME_UUID_LEN_STRING - 1);
	if (len < 0)
		return -ENXIO;

	return strlen(system_uuid) ? 0 : -ENXIO;
}

/*
 * See System Management BIOS (SMBIOS) Reference Specification
 * https://www.dmtf.org/sites/default/files/standards/documents/DSP0134_3.2.0.pdf
 */
#define DMI_SYSTEM_INFORMATION	1

static bool is_dmi_uuid_valid(const char *buf, size_t len)
{
	int i;

	/* UUID bytes are from byte 8 to 23 */
	if (len < 24)
		return false;

	/* Test it's a invalid UUID with all zeros */
	for (i = 8; i < 24; i++) {
		if (buf[i])
			break;
	}
	if (i == 24)
		return false;

	return true;
}

static int uuid_from_dmi_entries(char *system_uuid)
{
	__cleanup_dir DIR *d = NULL;
	const char *entries_dir = libnvme_dmi_entries_dir();
	int f;
	struct dirent *de;
	char buf[512] = {0};

	system_uuid[0] = '\0';
	d = opendir(entries_dir);
	if (!d)
		return -ENXIO;
	while ((de = readdir(d))) {
		char filename[PATH_MAX];
		int len, type;

		if (de->d_name[0] == '.')
			continue;
		sprintf(filename, "%s/%s/type", entries_dir, de->d_name);
		f = open(filename, O_RDONLY);
		if (f < 0)
			continue;
		len = read(f, buf, 512);
		close(f);
		if (len <= 0)
			continue;
		if (sscanf(buf, "%d", &type) != 1)
			continue;
		if (type != DMI_SYSTEM_INFORMATION)
			continue;
		sprintf(filename, "%s/%s/raw", entries_dir, de->d_name);
		f = open(filename, O_RDONLY);
		if (f < 0)
			continue;
		len = read(f, buf, 512);
		close(f);
		if (len <= 0)
			continue;

		if (!is_dmi_uuid_valid(buf, len))
			continue;

		/* Sigh. https://en.wikipedia.org/wiki/Overengineering */
		/* DMTF SMBIOS 3.0 Section 7.2.1 System UUID */
		sprintf(system_uuid,
			"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-"
			"%02x%02x%02x%02x%02x%02x",
			(uint8_t)buf[8 + 3], (uint8_t)buf[8 + 2],
			(uint8_t)buf[8 + 1], (uint8_t)buf[8 + 0],
			(uint8_t)buf[8 + 5], (uint8_t)buf[8 + 4],
			(uint8_t)buf[8 + 7], (uint8_t)buf[8 + 6],
			(uint8_t)buf[8 + 8], (uint8_t)buf[8 + 9],
			(uint8_t)buf[8 + 10], (uint8_t)buf[8 + 11],
			(uint8_t)buf[8 + 12], (uint8_t)buf[8 + 13],
			(uint8_t)buf[8 + 14], (uint8_t)buf[8 + 15]);
		break;
	}
	return strlen(system_uuid) ? 0 : -ENXIO;
}

#define PATH_DMI_PROD_UUID  "/sys/class/dmi/id/product_uuid"

/**
 * uuid_from_product_uuid() - Get system UUID from product_uuid
 * @system_uuid: Where to save the system UUID.
 *
 * Return: 0 on success, -ENXIO otherwise.
 */
static int uuid_from_product_uuid(char *system_uuid)
{
	__cleanup_file FILE *stream = NULL;
	ssize_t nread;
	__cleanup_free char *line = NULL;
	size_t len = 0;

	stream = fopen(PATH_DMI_PROD_UUID, "re");
	if (!stream)
		return -ENXIO;
	system_uuid[0] = '\0';

	nread = getline(&line, &len, stream);
	if (nread != NVME_UUID_LEN_STRING)
		return -ENXIO;

	/* The kernel is handling the byte swapping according DMTF
	 * SMBIOS 3.0 Section 7.2.1 System UUID */

	memcpy(system_uuid, line, NVME_UUID_LEN_STRING - 1);
	system_uuid[NVME_UUID_LEN_STRING - 1] = '\0';

	return 0;
}

/**
 * uuid_from_dmi() - read system UUID
 * @system_uuid: buffer for the UUID
 *
 * The system UUID can be read from two different locations:
 *
 *     1) /sys/class/dmi/id/product_uuid
 *     2) /sys/firmware/dmi/entries
 *
 * Note that the second location is not present on Debian-based systems.
 *
 * Return: 0 on success, negative errno otherwise.
 */
static int uuid_from_dmi(char *system_uuid)
{
	int ret = uuid_from_product_uuid(system_uuid);
	if (ret != 0)
		ret = uuid_from_dmi_entries(system_uuid);
	return ret;
}

__public char *libnvme_generate_hostid(void)
{
	int ret;
	char uuid_str[NVME_UUID_LEN_STRING];
	unsigned char uuid[NVME_UUID_LEN];

	ret = uuid_from_dmi(uuid_str);
	if (ret < 0)
		ret = uuid_from_device_tree(uuid_str);
	if (ret < 0) {
		if (libnvme_random_uuid(uuid) < 0)
			memset(uuid, 0, NVME_UUID_LEN);
		libnvme_uuid_to_string(uuid, uuid_str);
	}

	return strdup(uuid_str);
}

__public char *libnvme_generate_hostnqn_from_hostid(char *hostid)
{
	char *hid = NULL;
	char *hostnqn;
	int ret;

	if (!hostid)
		hostid = hid = libnvme_generate_hostid();

	ret = asprintf(&hostnqn, "nqn.2014-08.org.nvmexpress:uuid:%s", hostid);
	free(hid);

	return (ret < 0) ? NULL : hostnqn;
}

__public char *libnvme_generate_hostnqn(void)
{
	return libnvme_generate_hostnqn_from_hostid(NULL);
}

static char *nvmf_read_file(const char *f, int len)
{
	char buf[len];
	__cleanup_fd int fd = -1;
	int ret;

	fd = open(f, O_RDONLY);
	if (fd < 0)
		return NULL;

	memset(buf, 0, len);
	ret = read(fd, buf, len - 1);

	if (ret < 0 || !strlen(buf))
		return NULL;
	return strndup(buf, strcspn(buf, "\n"));
}

__public char *libnvme_read_hostnqn(void)
{
	char *hostnqn = getenv("LIBNVME_HOSTNQN");

	if (hostnqn) {
		if (!strcmp(hostnqn, ""))
			return NULL;
		return strdup(hostnqn);
	}

	return nvmf_read_file(NVMF_HOSTNQN_FILE, NVMF_NQN_SIZE);
}

__public char *libnvme_read_hostid(void)
{
	char *hostid = getenv("LIBNVME_HOSTID");

	if (hostid) {
		if (!strcmp(hostid, ""))
			return NULL;
		return strdup(hostid);
	}

	return nvmf_read_file(NVMF_HOSTID_FILE, NVMF_HOSTID_SIZE);
}
