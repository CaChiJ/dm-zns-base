/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _ZNS_GC_H
#define _ZNS_GC_H

#include <linux/types.h>

struct zns_gc_zone_info {
	bool is_reserve;
	bool resettable;
	sector_t capacity_blocks;
	sector_t free_blocks;
	sector_t valid_blocks;
};

struct zns_gc_context {
	void *private;
	unsigned int nr_zones;
	bool has_write_space;
	sector_t reserve_free_blocks;
	struct zns_gc_zone_info (*get_zone_info)(const struct zns_gc_context *ctx, unsigned int zone);
};

struct zns_gc_policy {
	const char *name;
	bool (*should_gc)(const struct zns_gc_context *ctx);
	int (*select_victim)(const struct zns_gc_context *ctx);
};

extern const struct zns_gc_policy zns_gc_policy;
#endif
