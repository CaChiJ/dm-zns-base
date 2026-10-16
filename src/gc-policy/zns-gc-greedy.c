// SPDX-License-Identifier: GPL-2.0
#include <linux/errno.h>

#include "zns-gc.h"

static bool should_gc(const struct zns_gc_context *ctx)
{
	return !ctx->has_write_space;
}

/*
 * Minimize relocation work for the next collection. Data zones currently have
 * equal capacity, so the fewest live blocks is also the most garbage. Keeping
 * the first match makes ties deterministic without retaining policy state.
 */
static int select_victim(const struct zns_gc_context *ctx)
{
	sector_t fewest_valid = (sector_t)-1;
	int victim = -ENOSPC;
	unsigned int zone;

	for (zone = 0; zone < ctx->nr_zones; zone++) {
		struct zns_gc_zone_info info = ctx->get_zone_info(ctx, zone);

		if (info.is_reserve || !info.resettable || info.free_blocks ||
		    info.valid_blocks >= info.capacity_blocks ||
		    info.valid_blocks > ctx->reserve_free_blocks)
			continue;

		if (info.valid_blocks < fewest_valid) {
			fewest_valid = info.valid_blocks;
			victim = zone;
		}
	}

	return victim;
}

const struct zns_gc_policy zns_gc_policy = {
	.name = "greedy",
	.should_gc = should_gc,
	.select_victim = select_victim,
};
