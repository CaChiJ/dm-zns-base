// SPDX-License-Identifier: GPL-2.0
/* Standalone kernel-module tests for the physical append allocator. */

#include <linux/completion.h>
#include <linux/errno.h>
#include <linux/kthread.h>
#include <linux/module.h>
#include <linux/slab.h>

#include "../src/zns-allocator.c"

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

static int __init allocator_test_init(void)
{
	int ret;

	ret = allocator_test_sequential();
	if (ret)
		goto fail;
	ret = allocator_test_enospc();
	if (ret)
		goto fail;
	ret = allocator_test_concurrent();
	if (ret)
		goto fail;

	pr_info("zns allocator test: PASS\n");
	return 0;

fail:
	pr_err("zns allocator test: FAIL (%d)\n", ret);
	return ret;
}

static void __exit allocator_test_exit(void)
{
}

module_init(allocator_test_init);
module_exit(allocator_test_exit);

MODULE_DESCRIPTION("dm-zns-base physical allocator tests");
MODULE_LICENSE("GPL");
