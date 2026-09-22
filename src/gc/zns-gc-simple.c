// SPDX-License-Identifier: GPL-2.0
#include <linux/errno.h>
#include "zns-gc.h"

static bool should_gc(struct zns_gc_context *ctx)
{
	return !ctx->has_space(ctx);
}

static int run_gc(struct zns_gc_context *ctx)
{
	unsigned int zone;

	for (zone = 0; zone < ctx->nr_zones; zone++)
		if (ctx->eligible(ctx, zone))
			return ctx->clean(ctx, zone);
	return -ENOSPC;
}

const struct zns_gc_policy zns_gc_policy = {
	.name = "simple",
	.should_gc = should_gc,
	.run_gc = run_gc,
};
