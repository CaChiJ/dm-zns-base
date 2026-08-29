// SPDX-License-Identifier: GPL-2.0
/* Standalone kernel-module tests for the physical append allocator. */

#include <linux/completion.h>
#include <linux/blkzoned.h>
#include <linux/errno.h>
#include <linux/kthread.h>
#include <linux/module.h>
#include <linux/slab.h>

#include "../../src/zns-allocator.c"

#include "zns-test.h"

#define TEST_BLOCK_SECTORS 8
#define TEST_TOTAL_BLOCKS  128
#define TEST_WORKERS       2
#define TEST_ALLOCS_PER_WORKER 64

struct allocator_worker {
	struct zns_allocator *allocator;
	sector_t *results;
	unsigned int start;
	struct completion done;
	int ret;
};

static int allocator_worker_fn(void *data)
{
	struct allocator_worker *worker = data;
	unsigned int i;

	for (i = 0; i < TEST_ALLOCS_PER_WORKER; i++) {
		worker->ret = zns_allocator_alloc(worker->allocator,
						  &worker->results[worker->start + i]);
		if (worker->ret)
			break;
	}

	complete(&worker->done);
	return 0;
}

static int allocator_test_sequential(void)
{
	struct zns_allocator allocator;
	sector_t sector;
	int ret;

	ret = zns_allocator_init(&allocator,
				 TEST_TOTAL_BLOCKS * TEST_BLOCK_SECTORS,
				 TEST_BLOCK_SECTORS);
	if (ret)
		return ret;

	ret = zns_allocator_alloc(&allocator, &sector);
	if (ret || sector != 0)
		return -EINVAL;

	ret = zns_allocator_alloc(&allocator, &sector);
	if (ret || sector != TEST_BLOCK_SECTORS)
		return -EINVAL;

	zns_allocator_exit(&allocator);
	return 0;
}

static int allocator_test_enospc(void)
{
	struct zns_allocator allocator;
	sector_t sector;
	unsigned int i;
	int ret;

	ret = zns_allocator_init(&allocator, 2 * TEST_BLOCK_SECTORS,
				 TEST_BLOCK_SECTORS);
	if (ret)
		return ret;

	for (i = 0; i < 2; i++) {
		ret = zns_allocator_alloc(&allocator, &sector);
		if (ret)
			return ret;
	}

	ret = zns_allocator_alloc(&allocator, &sector);
	zns_allocator_exit(&allocator);
	return ret == -ENOSPC ? 0 : -EINVAL;
}

static int allocator_test_rollback(void)
{
	struct zns_zone zone = {
		.id = 0,
		.start_sector = 64,
		.length = 16,
		.capacity = 8,
		.write_pointer = 64,
		.condition = BLK_ZONE_COND_EMPTY,
	};
	struct zns_allocator allocator;
	sector_t sector;
	int ret;

	ret = zns_allocator_init(&allocator, 16, TEST_BLOCK_SECTORS);
	if (ret)
		return ret;
	ret = zns_allocator_alloc(&allocator, &sector);
	if (ret || sector != 0 || zns_allocator_rollback(&allocator, sector)) {
		zns_allocator_exit(&allocator);
		return -EINVAL;
	}
	ret = zns_allocator_alloc(&allocator, &sector);
	if (ret || sector != 0) {
		zns_allocator_exit(&allocator);
		return -EINVAL;
	}
	ret = zns_allocator_alloc(&allocator, &sector);
	if (ret || sector != TEST_BLOCK_SECTORS ||
	    zns_allocator_rollback(&allocator, 0) != -EBUSY) {
		zns_allocator_exit(&allocator);
		return -EINVAL;
	}
	zns_allocator_exit(&allocator);

	ret = zns_allocator_init_zoned(&allocator, &zone, 1,
				       TEST_BLOCK_SECTORS);
	if (ret)
		return ret;
	ret = zns_allocator_alloc(&allocator, &sector);
	if (ret || sector != 64 || allocator.active_zone != 1 ||
	    zns_allocator_rollback(&allocator, sector) ||
	    allocator.active_zone != 0) {
		zns_allocator_exit(&allocator);
		return -EINVAL;
	}
	ret = zns_allocator_alloc(&allocator, &sector);
	zns_allocator_exit(&allocator);
	if (ret || sector != 64 || zns_allocator_rollback(NULL, 0) != -EINVAL)
		return -EINVAL;

	return 0;
}

static int allocator_test_zoned_boundaries(void)
{
	struct zns_zone zones[] = {
		{
			.id = 0,
			.start_sector = 0,
			.length = 32,
			.capacity = 16,
			.write_pointer = 0,
			.condition = BLK_ZONE_COND_EMPTY,
		},
		{
			.id = 1,
			.start_sector = 32,
			.length = 32,
			.capacity = 16,
			.write_pointer = 32,
			.condition = BLK_ZONE_COND_EMPTY,
		},
	};
	const sector_t expected[] = { 0, 8, 32, 40 };
	struct zns_allocator allocator;
	sector_t sector;
	unsigned int i;
	int ret;

	ret = zns_allocator_init_zoned(&allocator, zones, ARRAY_SIZE(zones),
				       TEST_BLOCK_SECTORS);
	if (ret)
		return ret;
	if (allocator.zones == zones) {
		ret = -EINVAL;
		goto out;
	}

	/* The allocator must own a copy independent of its caller. */
	zones[0].write_pointer = zones[0].start_sector + zones[0].capacity;

	for (i = 0; i < ARRAY_SIZE(expected); i++) {
		ret = zns_allocator_alloc(&allocator, &sector);
		if (ret || sector != expected[i]) {
			ret = -EINVAL;
			goto out;
		}
		if ((i == 1 && allocator.active_zone != 1) ||
		    (i == 3 && allocator.active_zone != 2)) {
			ret = -EINVAL;
			goto out;
		}
	}

	ret = zns_allocator_alloc(&allocator, &sector);
	if (ret != -ENOSPC)
		ret = -EINVAL;
	else
		ret = 0;

out:
	zns_allocator_exit(&allocator);
	if (!ret && (allocator.zones || allocator.nr_zones ||
		     allocator.sectors_per_block))
		ret = -EINVAL;
	return ret;
}

static int allocator_test_zoned_partial_capacity(void)
{
	struct zns_zone zone = {
		.id = 0,
		.start_sector = 100,
		.length = 32,
		.capacity = 20,
		.write_pointer = 100,
		.condition = BLK_ZONE_COND_EMPTY,
	};
	const sector_t expected[] = { 100, 108 };
	struct zns_allocator allocator;
	sector_t sector;
	unsigned int i;
	int ret;

	ret = zns_allocator_init_zoned(&allocator, &zone, 1,
				       TEST_BLOCK_SECTORS);
	if (ret)
		return ret;

	for (i = 0; i < ARRAY_SIZE(expected); i++) {
		ret = zns_allocator_alloc(&allocator, &sector);
		if (ret || sector != expected[i]) {
			ret = -EINVAL;
			goto out;
		}
	}
	if (allocator.active_zone != 1) {
		ret = -EINVAL;
		goto out;
	}

	ret = zns_allocator_alloc(&allocator, &sector);
	if (ret != -ENOSPC)
		ret = -EINVAL;
	else
		ret = 0;

out:
	zns_allocator_exit(&allocator);
	return ret;
}

static int allocator_test_zoned_current_wp(void)
{
	struct zns_zone zone = {
		.id = 0,
		.start_sector = 64,
		.length = 64,
		.capacity = 32,
		.write_pointer = 72,
		.condition = BLK_ZONE_COND_CLOSED,
	};
	struct zns_allocator allocator;
	sector_t sector;
	int ret;

	ret = zns_allocator_init_zoned(&allocator, &zone, 1,
				       TEST_BLOCK_SECTORS);
	if (ret)
		return ret;

	ret = zns_allocator_alloc(&allocator, &sector);
	zns_allocator_exit(&allocator);
	if (ret || sector != 72)
		return -EINVAL;

	return 0;
}

static int allocator_test_zoned_skips_unwritable(void)
{
	struct zns_zone zones[] = {
		{
			.id = 0, .start_sector = 0, .length = 32,
			.capacity = 16, .write_pointer = 16,
			.condition = BLK_ZONE_COND_FULL,
		},
		{
			.id = 1, .start_sector = 32, .length = 32,
			.capacity = 16, .write_pointer = 32,
			.condition = BLK_ZONE_COND_READONLY,
		},
		{
			.id = 2, .start_sector = 64, .length = 32,
			.capacity = 16, .write_pointer = 64,
			.condition = BLK_ZONE_COND_OFFLINE,
		},
		{
			.id = 3, .start_sector = 96, .length = 32,
			.capacity = 16, .write_pointer = 96,
			.condition = BLK_ZONE_COND_EMPTY,
		},
	};
	const sector_t expected[] = { 96, 104 };
	struct zns_allocator allocator;
	sector_t sector;
	unsigned int i;
	int ret;

	ret = zns_allocator_init_zoned(&allocator, zones, ARRAY_SIZE(zones),
				       TEST_BLOCK_SECTORS);
	if (ret)
		return ret;

	for (i = 0; i < ARRAY_SIZE(expected); i++) {
		ret = zns_allocator_alloc(&allocator, &sector);
		if (ret || sector != expected[i]) {
			ret = -EINVAL;
			goto out;
		}
	}

	ret = zns_allocator_alloc(&allocator, &sector);
	if (ret != -ENOSPC)
		ret = -EINVAL;
	else
		ret = 0;

out:
	zns_allocator_exit(&allocator);
	return ret;
}

static int allocator_test_zoned_invalid_init(void)
{
	struct zns_zone zone = {
		.start_sector = 0,
		.length = 32,
		.capacity = 16,
		.write_pointer = 0,
		.condition = BLK_ZONE_COND_EMPTY,
	};
	struct zns_allocator allocator;

	if (zns_allocator_init_zoned(NULL, &zone, 1, TEST_BLOCK_SECTORS) !=
	    -EINVAL)
		return -EINVAL;
	if (zns_allocator_init_zoned(&allocator, NULL, 1,
				     TEST_BLOCK_SECTORS) != -EINVAL)
		return -EINVAL;
	if (zns_allocator_init_zoned(&allocator, &zone, 0,
				     TEST_BLOCK_SECTORS) != -EINVAL)
		return -EINVAL;
	if (zns_allocator_init_zoned(&allocator, &zone, 1, 0) != -EINVAL)
		return -EINVAL;

	zone.capacity = zone.length + 1;
	if (zns_allocator_init_zoned(&allocator, &zone, 1,
				     TEST_BLOCK_SECTORS) != -EINVAL)
		return -EINVAL;

	return 0;
}

static int allocator_test_concurrent(void)
{
	struct allocator_worker workers[TEST_WORKERS];
	struct task_struct *tasks[TEST_WORKERS];
	struct zns_allocator allocator;
	sector_t *results;
	unsigned int i, j;
	int ret;

	results = kmalloc_array(TEST_WORKERS * TEST_ALLOCS_PER_WORKER,
				       sizeof(*results), GFP_KERNEL);
	if (!results)
		return -ENOMEM;

	ret = zns_allocator_init(&allocator,
				 TEST_TOTAL_BLOCKS * TEST_BLOCK_SECTORS,
				 TEST_BLOCK_SECTORS);
	if (ret)
		goto free_results;

	for (i = 0; i < TEST_WORKERS; i++) {
		workers[i].allocator = &allocator;
		workers[i].results = results;
		workers[i].start = i * TEST_ALLOCS_PER_WORKER;
		workers[i].ret = 0;
		init_completion(&workers[i].done);
		tasks[i] = kthread_run(allocator_worker_fn, &workers[i],
					"zns-allocator-%u", i);
		if (IS_ERR(tasks[i])) {
			ret = PTR_ERR(tasks[i]);
			while (i-- > 0) {
				kthread_stop(tasks[i]);
				wait_for_completion(&workers[i].done);
			}
			goto exit_allocator;
		}
	}

	for (i = 0; i < TEST_WORKERS; i++)
		wait_for_completion(&workers[i].done);

	for (i = 0; i < TEST_WORKERS; i++) {
		if (workers[i].ret) {
			ret = workers[i].ret;
			goto exit_allocator;
		}
	}

	for (i = 0; i < TEST_WORKERS * TEST_ALLOCS_PER_WORKER; i++)
		for (j = i + 1;
		     j < TEST_WORKERS * TEST_ALLOCS_PER_WORKER; j++)
			if (results[i] == results[j]) {
				ret = -EINVAL;
				goto exit_allocator;
			}

	ret = 0;

exit_allocator:
	zns_allocator_exit(&allocator);
free_results:
	kfree(results);
	return ret;
}

static int allocator_test_zoned_concurrent(void)
{
	struct zns_zone zones[] = {
		{
			.id = 0, .start_sector = 0, .length = 1024,
			.capacity = 512, .write_pointer = 0,
			.condition = BLK_ZONE_COND_EMPTY,
		},
		{
			.id = 1, .start_sector = 1024, .length = 1024,
			.capacity = 512, .write_pointer = 1024,
			.condition = BLK_ZONE_COND_EMPTY,
		},
	};
	struct allocator_worker workers[TEST_WORKERS];
	struct task_struct *tasks[TEST_WORKERS];
	struct zns_allocator allocator;
	sector_t *results;
	unsigned int i, j;
	int ret;

	results = kmalloc_array(TEST_WORKERS * TEST_ALLOCS_PER_WORKER,
			       sizeof(*results), GFP_KERNEL);
	if (!results)
		return -ENOMEM;

	ret = zns_allocator_init_zoned(&allocator, zones, ARRAY_SIZE(zones),
				       TEST_BLOCK_SECTORS);
	if (ret)
		goto free_results;

	for (i = 0; i < TEST_WORKERS; i++) {
		workers[i].allocator = &allocator;
		workers[i].results = results;
		workers[i].start = i * TEST_ALLOCS_PER_WORKER;
		workers[i].ret = 0;
		init_completion(&workers[i].done);
		tasks[i] = kthread_run(allocator_worker_fn, &workers[i],
				     "zns-zoned-allocator-%u", i);
		if (IS_ERR(tasks[i])) {
			ret = PTR_ERR(tasks[i]);
			while (i-- > 0) {
				kthread_stop(tasks[i]);
				wait_for_completion(&workers[i].done);
			}
			goto exit_allocator;
		}
	}

	for (i = 0; i < TEST_WORKERS; i++)
		wait_for_completion(&workers[i].done);

	for (i = 0; i < TEST_WORKERS; i++) {
		if (workers[i].ret) {
			ret = workers[i].ret;
			goto exit_allocator;
		}
	}

	for (i = 0; i < TEST_WORKERS * TEST_ALLOCS_PER_WORKER; i++) {
		sector_t sector = results[i];
		bool in_zone_0 = sector < 512 &&
			sector + TEST_BLOCK_SECTORS <= 512;
		bool in_zone_1 = sector >= 1024 &&
			sector + TEST_BLOCK_SECTORS <= 1536;

		if ((!in_zone_0 && !in_zone_1) ||
		    sector % TEST_BLOCK_SECTORS) {
			ret = -EINVAL;
			goto exit_allocator;
		}

		for (j = i + 1;
		     j < TEST_WORKERS * TEST_ALLOCS_PER_WORKER; j++)
			if (sector == results[j]) {
				ret = -EINVAL;
				goto exit_allocator;
			}
	}

	ret = 0;

exit_allocator:
	zns_allocator_exit(&allocator);
free_results:
	kfree(results);
	return ret;
}

static const struct zns_test_case allocator_cases[] = {
	ZNS_TEST_CASE(allocator_test_sequential,
		      "when blocks are allocated in order, the allocator returns 0, 8, 16 and on"),
	ZNS_TEST_CASE(allocator_test_enospc,
		      "when every block is used, the next allocation reports -ENOSPC"),
	ZNS_TEST_CASE(allocator_test_rollback,
		      "when the latest reservation is unused, rollback makes it allocatable again"),
	ZNS_TEST_CASE(allocator_test_zoned_boundaries,
		      "when a zone reaches capacity, allocation moves on to the next zone"),
	ZNS_TEST_CASE(allocator_test_zoned_partial_capacity,
		      "when capacity is not a block multiple, the partial tail is left unused"),
	ZNS_TEST_CASE(allocator_test_zoned_current_wp,
		      "when a zone is already written, allocation resumes at its write pointer"),
	ZNS_TEST_CASE(allocator_test_zoned_skips_unwritable,
		      "when a zone is full, read-only, or offline, the allocator skips it"),
	ZNS_TEST_CASE(allocator_test_zoned_invalid_init,
		      "when the zone geometry is invalid, initialization is refused"),
	ZNS_TEST_CASE(allocator_test_concurrent,
		      "when two kthreads allocate at once, no linear block is handed out twice"),
	ZNS_TEST_CASE(allocator_test_zoned_concurrent,
		      "when two kthreads allocate at once, zoned blocks stay inside capacity"),
};

static int __init allocator_test_init(void)
{
	return zns_test_run("allocator", allocator_cases,
			    ARRAY_SIZE(allocator_cases));
}

static void __exit allocator_test_exit(void)
{
}

module_init(allocator_test_init);
module_exit(allocator_test_exit);

MODULE_DESCRIPTION("dm-zns-base physical allocator tests");
MODULE_LICENSE("GPL");
