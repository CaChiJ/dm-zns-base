// SPDX-License-Identifier: GPL-2.0
#include <linux/blkdev.h>
#include <linux/module.h>

#include "../../src/gc-policy/zns-gc-simple.c"
#include "zns-test.h"

static struct zns_gc_zone_info test_zone_info(const struct zns_gc_context *ctx,
					    unsigned int zone)
{
	const struct zns_gc_zone_info *zones = ctx->private;

	return zones[zone];
}

static int gc_test_selection(void)
{
	struct zns_gc_zone_info zones[] = {
		{ .resettable = true, .capacity_blocks = 100, .valid_blocks = 97 },
		{ .resettable = true, .capacity_blocks = 100, .valid_blocks = 20 },
		{ .resettable = true, .capacity_blocks = 100, .valid_blocks = 60 },
	};
	struct zns_gc_context ctx = {
		.private = zones, .nr_zones = ARRAY_SIZE(zones),
		.reserve_free_blocks = 100, .get_zone_info = test_zone_info,
	};

	/* A nearly full low-ID zone must not hide a much cheaper victim. */
	if (select_victim(&ctx) != 1)
		return -EINVAL;
	zones[2].valid_blocks = 0;
	if (select_victim(&ctx) != 2)
		return -EINVAL;
	/* Equal-cost victims retain deterministic selection. */
	zones[1].valid_blocks = 0;
	if (select_victim(&ctx) != 1)
		return -EINVAL;
	return 0;
}

static int gc_test_eligibility(void)
{
	struct zns_gc_zone_info zones[] = {
		{ .is_reserve = true, .resettable = true, .capacity_blocks = 100 },
		{ .capacity_blocks = 100 },
		{ .resettable = true, .capacity_blocks = 100, .free_blocks = 1 },
		{ .resettable = true, .capacity_blocks = 100, .valid_blocks = 100 },
		{ .resettable = true, .capacity_blocks = 100, .valid_blocks = 51 },
		{ .resettable = true, .capacity_blocks = 100, .valid_blocks = 50 },
	};
	struct zns_gc_context ctx = {
		.private = zones, .nr_zones = ARRAY_SIZE(zones),
		.reserve_free_blocks = 50, .get_zone_info = test_zone_info,
	};

	if (select_victim(&ctx) != 5)
		return -EINVAL;
	zones[5].is_reserve = true;
	if (select_victim(&ctx) != -ENOSPC)
		return -EINVAL;
	ctx.has_write_space = true;
	if (should_gc(&ctx))
		return -EINVAL;
	ctx.has_write_space = false;
	if (!should_gc(&ctx))
		return -EINVAL;
	return 0;
}

static const struct zns_test_case gc_cases[] = {
	ZNS_TEST_CASE(gc_test_selection,
		      "GC chooses the least live data and prefers copy-free victims"),
	ZNS_TEST_CASE(gc_test_eligibility,
		      "GC preserves reserve, writable-space and relocation-capacity constraints"),
};

static int __init gc_policy_test_init(void)
{
	return zns_test_run("gc-policy", gc_cases, ARRAY_SIZE(gc_cases));
}

static void __exit gc_policy_test_exit(void)
{
}

module_init(gc_policy_test_init);
module_exit(gc_policy_test_exit);
MODULE_DESCRIPTION("dm-zns-base GC policy regression tests");
MODULE_LICENSE("GPL");
