// SPDX-License-Identifier: GPL-2.0
#include <linux/errno.h>
#include "zns-gc.h"

static bool should_gc(struct zns_gc_context *ctx)
{
	return false;
}

static int run_gc(struct zns_gc_context *ctx)
{
	return -ENOSPC;
}

const struct zns_gc_policy zns_gc_policy = {
	.name = "none",
	.should_gc = should_gc,
	.run_gc = run_gc,
};
