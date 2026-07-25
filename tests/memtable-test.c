// SPDX-License-Identifier: GPL-2.0
/* Standalone kernel-module tests for the in-memory memtable. */

#include <linux/completion.h>
#include <linux/errno.h>
#include <linux/kthread.h>
#include <linux/module.h>

#include "../src/lsm-memtable.c"

#define FREEZE_TEST_THRESHOLD 32
#define FREEZE_TEST_WORKERS 2
#define FREEZE_TEST_PUTS_PER_WORKER 32

struct memtable_freeze_worker {
	struct lsm_memtable **active;
	struct lsm_memtable **immutable;
	struct mutex *table_lock;
	unsigned int start;
	struct completion done;
	int ret;
};

static int memtable_freeze_worker_fn(void *data)
{
	struct memtable_freeze_worker *worker = data;
	unsigned int i;

	for (i = 0; i < FREEZE_TEST_PUTS_PER_WORKER; i++) {
		sector_t logical_block = worker->start + i;

		worker->ret = memtable_put_active(
				worker->active, worker->immutable,
				worker->table_lock, FREEZE_TEST_THRESHOLD,
				logical_block, logical_block * 8);
		if (worker->ret)
			break;
	}

	complete(&worker->done);
	return 0;
}

static int memtable_test_heap_lifecycle(void)
{
	struct lsm_memtable *active;
	struct lsm_memtable *immutable = NULL;
	sector_t physical_sector;
	int ret;

	active = memtable_create();
	if (!active)
		return -ENOMEM;
	if (!RB_EMPTY_ROOT(&active->root) || active->nr_entries ||
	    active->next_sequence != 1) {
		ret = -EINVAL;
		goto out;
	}

	ret = memtable_put(active, 7, 56);
	if (ret)
		goto out;
	ret = memtable_lookup(active, 7, &physical_sector, NULL);
	if (ret || physical_sector != 56)
		ret = -EINVAL;

out:
	memtable_free(active);
	memtable_free(immutable);
	return ret;
}

static int memtable_test_threshold_freeze(void)
{
	struct lsm_memtable *active;
	struct lsm_memtable *immutable = NULL;
	struct lsm_memtable *old_active;
	struct lsm_memtable *active_after_freeze;
	struct mutex table_lock;
	sector_t physical_sector;
	int ret;

	active = memtable_create();
	if (!active)
		return -ENOMEM;
	mutex_init(&table_lock);
	old_active = active;

	ret = memtable_put_active(&active, &immutable, &table_lock, 2, 10, 80);
	if (ret)
		goto out;
	if (active != old_active || immutable || memtable_size(active) != 1) {
		ret = -EINVAL;
		goto out;
	}

	/* Updating an existing key must not advance the entry threshold. */
	ret = memtable_put_active(&active, &immutable, &table_lock, 2, 10, 88);
	if (ret)
		goto out;
	if (active != old_active || immutable || memtable_size(active) != 1) {
		ret = -EINVAL;
		goto out;
	}

	ret = memtable_put_active(&active, &immutable, &table_lock, 2, 11, 96);
	if (ret)
		goto out;
	if (immutable != old_active || active == old_active ||
	    memtable_size(immutable) != 2 || memtable_size(active) != 0) {
		ret = -EINVAL;
		goto out;
	}

	ret = memtable_lookup(immutable, 11, &physical_sector, NULL);
	if (ret || physical_sector != 96) {
		ret = -EINVAL;
		goto out;
	}

	ret = memtable_put_active(&active, &immutable, &table_lock, 2, 12, 104);
	if (ret)
		goto out;
	ret = memtable_lookup(active, 12, &physical_sector, NULL);
	if (ret || physical_sector != 104) {
		ret = -EINVAL;
		goto out;
	}

	/*
	 * Once immutable exists, reaching the threshold again keeps accepting
	 * writes in the same active table until a flush path is implemented.
	 */
	active_after_freeze = active;
	ret = memtable_put_active(&active, &immutable, &table_lock, 2, 13, 112);
	if (ret || active != active_after_freeze ||
	    immutable != old_active || memtable_size(active) != 2) {
		ret = -EINVAL;
		goto out;
	}

	ret = 0;

out:
	memtable_free(active);
	memtable_free(immutable);
	return ret;
}

static int memtable_test_active_immutable_lookup(void)
{
	struct lsm_memtable *active;
	struct lsm_memtable *immutable = NULL;
	struct lsm_memtable *null_active = NULL;
	struct mutex table_lock;
	sector_t physical_sector;
	int ret;

	active = memtable_create();
	if (!active)
		return -ENOMEM;
	mutex_init(&table_lock);

	ret = memtable_put(active, 10, 80);
	if (ret)
		goto out;
	ret = memtable_put(active, 11, 88);
	if (ret)
		goto out;

	/* Before freeze, mappings are found in active. */
	ret = memtable_lookup_active_immutable(
			&active, &immutable, &table_lock, 11,
			&physical_sector);
	if (ret || physical_sector != 88) {
		ret = -EINVAL;
		goto out;
	}

	ret = memtable_freeze(&active, &immutable, &table_lock);
	if (ret)
		goto out;

	/* After freeze, the same mapping is found in immutable. */
	ret = memtable_lookup_active_immutable(
			&active, &immutable, &table_lock, 11,
			&physical_sector);
	if (ret || physical_sector != 88) {
		ret = -EINVAL;
		goto out;
	}

	/* A newer active mapping must shadow the immutable mapping. */
	ret = memtable_put(active, 10, 800);
	if (ret)
		goto out;
	ret = memtable_lookup_active_immutable(
			&active, &immutable, &table_lock, 10,
			&physical_sector);
	if (ret || physical_sector != 800) {
		ret = -EINVAL;
		goto out;
	}

	ret = memtable_lookup_active_immutable(
			&active, &immutable, &table_lock, 999,
			&physical_sector);
	if (ret != -ENODATA) {
		ret = -EINVAL;
		goto out;
	}

	if (memtable_lookup_active_immutable(
			NULL, &immutable, &table_lock, 10,
			&physical_sector) != -EINVAL ||
	    memtable_lookup_active_immutable(
			&active, NULL, &table_lock, 10,
			&physical_sector) != -EINVAL ||
	    memtable_lookup_active_immutable(
			&active, &immutable, NULL, 10,
			&physical_sector) != -EINVAL ||
	    memtable_lookup_active_immutable(
			&active, &immutable, &table_lock, 10, NULL) !=
			-EINVAL ||
	    memtable_lookup_active_immutable(
			&null_active, &immutable, &table_lock, 10,
			&physical_sector) != -EINVAL) {
		ret = -EINVAL;
		goto out;
	}

	ret = 0;

out:
	memtable_free(active);
	memtable_free(immutable);
	return ret;
}

static int memtable_test_threshold_freeze_concurrent(void)
{
	struct memtable_freeze_worker workers[FREEZE_TEST_WORKERS];
	struct task_struct *tasks[FREEZE_TEST_WORKERS];
	struct lsm_memtable *active;
	struct lsm_memtable *immutable = NULL;
	struct mutex table_lock;
	unsigned int i;
	int ret;

	active = memtable_create();
	if (!active)
		return -ENOMEM;
	mutex_init(&table_lock);

	for (i = 0; i < FREEZE_TEST_WORKERS; i++) {
		workers[i].active = &active;
		workers[i].immutable = &immutable;
		workers[i].table_lock = &table_lock;
		workers[i].start = i * FREEZE_TEST_PUTS_PER_WORKER;
		workers[i].ret = 0;
		init_completion(&workers[i].done);
		tasks[i] = kthread_run(memtable_freeze_worker_fn, &workers[i],
				     "zns-freeze-%u", i);
		if (IS_ERR(tasks[i])) {
			ret = PTR_ERR(tasks[i]);
			while (i-- > 0) {
				kthread_stop(tasks[i]);
				wait_for_completion(&workers[i].done);
			}
			goto out;
		}
	}

	for (i = 0; i < FREEZE_TEST_WORKERS; i++)
		wait_for_completion(&workers[i].done);

	for (i = 0; i < FREEZE_TEST_WORKERS; i++) {
		if (workers[i].ret) {
			ret = workers[i].ret;
			goto out;
		}
	}

	if (!active || !immutable ||
	    memtable_size(immutable) != FREEZE_TEST_THRESHOLD ||
	    memtable_size(active) + memtable_size(immutable) !=
		    FREEZE_TEST_WORKERS * FREEZE_TEST_PUTS_PER_WORKER) {
		ret = -EINVAL;
		goto out;
	}

	for (i = 0;
	     i < FREEZE_TEST_WORKERS * FREEZE_TEST_PUTS_PER_WORKER; i++) {
		sector_t physical_sector;

		ret = memtable_lookup(active, i, &physical_sector, NULL);
		if (ret == -ENODATA)
			ret = memtable_lookup(immutable, i, &physical_sector,
					      NULL);
		if (ret || physical_sector != i * 8) {
			ret = -EINVAL;
			goto out;
		}
	}

	ret = 0;

out:
	memtable_free(active);
	memtable_free(immutable);
	return ret;
}

static int memtable_test_freeze(void)
{
	struct lsm_memtable *active;
	struct lsm_memtable *immutable = NULL;
	struct lsm_memtable *old_active;
	struct lsm_memtable *active_after_freeze;
	struct mutex table_lock;
	sector_t physical_sector;
	int ret;

	active = memtable_create();
	if (!active)
		return -ENOMEM;
	mutex_init(&table_lock);

	ret = memtable_put(active, 7, 56);
	if (ret)
		goto out;

	old_active = active;
	ret = memtable_freeze(&active, &immutable, &table_lock);
	if (ret)
		goto out;
	if (immutable != old_active || active == old_active ||
	    !RB_EMPTY_ROOT(&active->root) || active->nr_entries) {
		ret = -EINVAL;
		goto out;
	}

	ret = memtable_lookup(immutable, 7, &physical_sector, NULL);
	if (ret || physical_sector != 56) {
		ret = -EINVAL;
		goto out;
	}

	ret = memtable_put(active, 8, 64);
	if (ret)
		goto out;
	ret = memtable_lookup(active, 8, &physical_sector, NULL);
	if (ret || physical_sector != 64) {
		ret = -EINVAL;
		goto out;
	}

	active_after_freeze = active;
	ret = memtable_freeze(&active, &immutable, &table_lock);
	if (ret != -EBUSY || active != active_after_freeze ||
	    immutable != old_active) {
		ret = -EINVAL;
		goto out;
	}

	ret = 0;

out:
	memtable_free(active);
	memtable_free(immutable);
	return ret;
}

static int memtable_test_freeze_allocation_failure(void)
{
	struct lsm_memtable *active;
	struct lsm_memtable *immutable = NULL;
	struct lsm_memtable *old_active;
	struct mutex table_lock;
	sector_t physical_sector;
	int ret;

	active = memtable_create();
	if (!active)
		return -ENOMEM;
	mutex_init(&table_lock);

	ret = memtable_put(active, 9, 72);
	if (ret)
		goto out;

	old_active = active;
	ret = memtable_freeze_prepared(&active, &immutable, &table_lock, NULL);
	if (ret != -ENOMEM || active != old_active || immutable) {
		ret = -EINVAL;
		goto out;
	}

	ret = memtable_lookup(active, 9, &physical_sector, NULL);
	if (ret || physical_sector != 72)
		ret = -EINVAL;
	else
		ret = 0;

out:
	memtable_free(active);
	memtable_free(immutable);
	return ret;
}

static int memtable_test_insert_lookup_update(void)
{
	struct lsm_memtable memtable;
	sector_t physical_sector;
	u64 insert_sequence;
	u64 update_sequence;
	int ret;

	ret = memtable_init(&memtable);
	if (ret)
		return ret;

	ret = memtable_insert(&memtable, 10, 100);
	if (ret)
		goto out;

	ret = memtable_lookup(&memtable, 10, &physical_sector,
			      &insert_sequence);
	if (ret)
		goto out;
	if (physical_sector != 100 || memtable.nr_entries != 1) {
		ret = -EINVAL;
		goto out;
	}

	ret = memtable_update(&memtable, 10, 200);
	if (ret)
		goto out;

	ret = memtable_lookup(&memtable, 10, &physical_sector,
			      &update_sequence);
	if (ret)
		goto out;
	if (physical_sector != 200 || update_sequence <= insert_sequence ||
	    memtable.nr_entries != 1)
		ret = -EINVAL;

out:
	memtable_destroy(&memtable);
	return ret;
}

static int memtable_test_missing(void)
{
	struct lsm_memtable memtable;
	sector_t physical_sector;
	int ret;

	ret = memtable_init(&memtable);
	if (ret)
		return ret;

	ret = memtable_lookup(&memtable, 999, &physical_sector, NULL);
	if (ret != -ENODATA)
		ret = -EINVAL;
	else
		ret = memtable_update(&memtable, 999, 100);

	memtable_destroy(&memtable);
	return ret == -ENODATA ? 0 : -EINVAL;
}

static int memtable_test_unordered_and_duplicate(void)
{
	static const sector_t logical_blocks[] = { 10, 5, 20, 3, 7, 15, 30 };
	struct lsm_memtable memtable;
	sector_t physical_sector;
	unsigned int i;
	int ret;

	ret = memtable_init(&memtable);
	if (ret)
		return ret;

	for (i = 0; i < ARRAY_SIZE(logical_blocks); i++) {
		ret = memtable_insert(&memtable, logical_blocks[i],
				      logical_blocks[i] * 8);
		if (ret)
			goto out;
	}

	for (i = 0; i < ARRAY_SIZE(logical_blocks); i++) {
		ret = memtable_lookup(&memtable, logical_blocks[i],
				      &physical_sector, NULL);
		if (ret)
			goto out;
		if (physical_sector != logical_blocks[i] * 8) {
			ret = -EINVAL;
			goto out;
		}
	}

	ret = memtable_insert(&memtable, 10, 999);
	if (ret == -EEXIST &&
	    memtable.nr_entries == ARRAY_SIZE(logical_blocks))
		ret = 0;
	else
		ret = -EINVAL;

out:
	memtable_destroy(&memtable);
	if (!RB_EMPTY_ROOT(&memtable.root) || memtable.nr_entries != 0)
		return -EINVAL;
	return ret;
}

static int memtable_test_latest_mapping(void)
{
	static const sector_t physical_sectors[] = { 1000, 2000, 3000 };
	struct lsm_memtable memtable;
	sector_t physical_sector;
	u64 previous_sequence = 0;
	u64 sequence;
	unsigned int i;
	int ret;

	ret = memtable_init(&memtable);
	if (ret)
		return ret;

	for (i = 0; i < ARRAY_SIZE(physical_sectors); i++) {
		ret = memtable_put(&memtable, 100, physical_sectors[i]);
		if (ret)
			goto out;

		ret = memtable_lookup(&memtable, 100, &physical_sector,
				      &sequence);
		if (ret)
			goto out;
		if (physical_sector != physical_sectors[i] ||
		    sequence <= previous_sequence || memtable.nr_entries != 1) {
			ret = -EINVAL;
			goto out;
		}
		previous_sequence = sequence;
	}

	ret = 0;

out:
	memtable_destroy(&memtable);
	return ret;
}

static int __init memtable_test_init(void)
{
	int ret;

	ret = memtable_test_heap_lifecycle();
	if (ret)
		goto fail;

	ret = memtable_test_threshold_freeze();
	if (ret)
		goto fail;

	ret = memtable_test_active_immutable_lookup();
	if (ret)
		goto fail;

	ret = memtable_test_threshold_freeze_concurrent();
	if (ret)
		goto fail;

	ret = memtable_test_freeze();
	if (ret)
		goto fail;

	ret = memtable_test_freeze_allocation_failure();
	if (ret)
		goto fail;

	ret = memtable_test_insert_lookup_update();
	if (ret)
		goto fail;

	ret = memtable_test_missing();
	if (ret)
		goto fail;

	ret = memtable_test_unordered_and_duplicate();
	if (ret)
		goto fail;

	ret = memtable_test_latest_mapping();
	if (ret)
		goto fail;

	pr_info("zns memtable test: PASS\n");
	return 0;

fail:
	pr_err("zns memtable test: FAIL (%d)\n", ret);
	return ret;
}

static void __exit memtable_test_exit(void)
{
}

module_init(memtable_test_init);
module_exit(memtable_test_exit);

MODULE_DESCRIPTION("dm-zns-base in-memory memtable tests");
MODULE_LICENSE("GPL");
