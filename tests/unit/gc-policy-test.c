// SPDX-License-Identifier: GPL-2.0
/* Standalone kernel-module tests for greedy GC victim selection. */

#include <linux/errno.h>
#include <linux/module.h>

#include "../../src/gc-policy/zns-gc-greedy.c"

#include "zns-test.h"

struct gc_policy_fixture {
	struct zns_gc_zone_info zones[5];
};

static struct zns_gc_zone_info get_zone_info(const struct zns_gc_context *ctx,
					      unsigned int zone)
{
	const struct gc_policy_fixture *fixture = ctx->private;

	return fixture->zones[zone];
}

static struct zns_gc_context make_context(struct gc_policy_fixture *fixture)
{
	return (struct zns_gc_context) {
		.private = fixture,
		.nr_zones = ARRAY_SIZE(fixture->zones),
		.has_write_space = false,
		.reserve_free_blocks = 16,
		.get_zone_info = get_zone_info,
	};
}

static void make_candidate(struct zns_gc_zone_info *zone, sector_t valid)
{
	*zone = (struct zns_gc_zone_info) {
		.resettable = true,
		.capacity_blocks = 16,
		.valid_blocks = valid,
	};
}

static int gc_policy_test_trigger(void)
{
	struct gc_policy_fixture fixture = {};
	struct zns_gc_context ctx = make_context(&fixture);

	ctx.has_write_space = true;
	if (zns_gc_policy.should_gc(&ctx))
		return -EINVAL;
	ctx.has_write_space = false;
	if (!zns_gc_policy.should_gc(&ctx))
		return -EINVAL;
	return 0;
}

static int gc_policy_test_selects_fewest_valid(void)
{
	struct gc_policy_fixture fixture = {};
	struct zns_gc_context ctx = make_context(&fixture);

	make_candidate(&fixture.zones[0], 12);
	make_candidate(&fixture.zones[1], 3);
	make_candidate(&fixture.zones[2], 9);

	return zns_gc_policy.select_victim(&ctx) == 1 ? 0 : -EINVAL;
}

static int gc_policy_test_keeps_first_tie(void)
{
	struct gc_policy_fixture fixture = {};
	struct zns_gc_context ctx = make_context(&fixture);

	make_candidate(&fixture.zones[0], 4);
	make_candidate(&fixture.zones[1], 4);

	return zns_gc_policy.select_victim(&ctx) == 0 ? 0 : -EINVAL;
}

static int gc_policy_test_skips_ineligible(void)
{
	struct gc_policy_fixture fixture = {};
	struct zns_gc_context ctx = make_context(&fixture);

	make_candidate(&fixture.zones[0], 1);
	fixture.zones[0].is_reserve = true;
	make_candidate(&fixture.zones[1], 2);
	fixture.zones[1].resettable = false;
	make_candidate(&fixture.zones[2], 3);
	fixture.zones[2].free_blocks = 1;
	make_candidate(&fixture.zones[3], 16);
	make_candidate(&fixture.zones[4], 5);

	return zns_gc_policy.select_victim(&ctx) == 4 ? 0 : -EINVAL;
}

static int gc_policy_test_requires_reserve_capacity(void)
{
	struct gc_policy_fixture fixture = {};
	struct zns_gc_context ctx = make_context(&fixture);

	ctx.reserve_free_blocks = 4;
	make_candidate(&fixture.zones[0], 5);
	make_candidate(&fixture.zones[1], 7);

	return zns_gc_policy.select_victim(&ctx) == -ENOSPC ? 0 : -EINVAL;
}

static const struct zns_test_case gc_policy_cases[] = {
	ZNS_TEST_CASE(gc_policy_test_trigger,
		      "when ordinary space is exhausted, greedy GC requests collection"),
	ZNS_TEST_CASE(gc_policy_test_selects_fewest_valid,
		      "when several zones are eligible, greedy GC selects the fewest live blocks"),
	ZNS_TEST_CASE(gc_policy_test_keeps_first_tie,
		      "when candidates tie, greedy GC selects the lower zone number"),
	ZNS_TEST_CASE(gc_policy_test_skips_ineligible,
		      "when zones are unsafe or reclaim nothing, greedy GC skips them"),
	ZNS_TEST_CASE(gc_policy_test_requires_reserve_capacity,
		      "when no live set fits the reserve, greedy GC reports ENOSPC"),
};

static int __init gc_policy_test_init(void)
{
	return zns_test_run("gc-policy", gc_policy_cases,
			    ARRAY_SIZE(gc_policy_cases));
}

static void __exit gc_policy_test_exit(void)
{
}

module_init(gc_policy_test_init);
module_exit(gc_policy_test_exit);

MODULE_DESCRIPTION("dm-zns-base greedy GC policy tests");
MODULE_LICENSE("GPL");
