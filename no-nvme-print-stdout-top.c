// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Implements nvme top dashboard
 *
 * Copyright (c) 2026 Nilay Shroff, IBM
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 */

#include "nvme-print.h"

void stdout_top(int refresh_interval)
{
	nvme_show_error("nvme-top is not supported on this platform\n");
}
