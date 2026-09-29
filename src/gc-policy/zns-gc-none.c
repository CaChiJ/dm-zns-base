// SPDX-License-Identifier: GPL-2.0
#include <linux/errno.h>
#include "zns-gc.h"

static bool should_gc(const struct zns_gc_context *ctx)
{
	return false;
}

static int select_victim(const struct zns_gc_context *ctx)
{
	return -ENOSPC;
}

const struct zns_gc_policy zns_gc_policy = {
	.name = "none",
	.should_gc = should_gc,
	.select_victim = select_victim,
};
