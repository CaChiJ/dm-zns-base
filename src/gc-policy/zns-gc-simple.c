// SPDX-License-Identifier: GPL-2.0
#include <linux/errno.h>
#include "zns-gc.h"

static bool should_gc(const struct zns_gc_context *ctx)
{
	return !ctx->has_write_space;
}

static int select_victim(const struct zns_gc_context *ctx)
{
	for (unsigned int zone = 0; zone < ctx->nr_zones; zone++) {
		struct zns_gc_zone_info info = ctx->get_zone_info(ctx, zone);

		if (!info.is_reserve && info.resettable && !info.free_blocks &&
		    info.valid_blocks < info.capacity_blocks &&
		    info.valid_blocks <= ctx->reserve_free_blocks) {
			return zone;
		}
	}
	return -ENOSPC;
}

const struct zns_gc_policy zns_gc_policy = {
	.name = "simple",
	.should_gc = should_gc,
	.select_victim = select_victim,
};
