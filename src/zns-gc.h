/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _ZNS_GC_H
#define _ZNS_GC_H

#include <linux/types.h>

struct zns_gc_context {
	void *private;
	unsigned int nr_zones;
	bool (*has_space)(struct zns_gc_context *ctx);
	bool (*eligible)(struct zns_gc_context *ctx, unsigned int zone);
	int (*clean)(struct zns_gc_context *ctx, unsigned int zone);
};

struct zns_gc_policy {
	const char *name;
	bool (*should_gc)(struct zns_gc_context *ctx);
	int (*run_gc)(struct zns_gc_context *ctx);
};

extern const struct zns_gc_policy zns_gc_policy;
#endif
