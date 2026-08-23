// SPDX-License-Identifier: GPL-2.0
/* Standalone kernel-module tests for the in-memory memtable. */

#include <linux/completion.h>
#include <linux/errno.h>
#include <linux/kthread.h>
#include <linux/module.h>

#include "../../src/lsm-memtable.c"

#include "zns-test.h"

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

static unsigned int compact_puts_before_failure;

static int memtable_test_failing_compact(
		const struct lsm_memtable *older,
		const struct lsm_memtable *newer,
		struct lsm_memtable **result)
{
	(void)older;
	(void)newer;
	*result = NULL;
	return -ENOMEM;
}

static struct lsm_memtable *memtable_test_failing_create(void)
{
	return NULL;
}

static int memtable_test_failing_compact_put(
		struct lsm_memtable *memtable,
		sector_t logical_block,
		sector_t physical_sector)
{
	if (!compact_puts_before_failure)
		return -ENOMEM;

	compact_puts_before_failure--;
	return memtable_put(memtable, logical_block, physical_sector);
}

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

static int memtable_test_compact_empty(void)
{
	struct lsm_memtable *older;
	struct lsm_memtable *newer;
	struct lsm_memtable *result = NULL;
	int ret;

	older = memtable_create();
	newer = memtable_create();
	if (!older || !newer) {
		ret = -ENOMEM;
		goto out;
	}

	ret = memtable_compact(older, newer, &result);
	if (ret)
		goto out;
	if (!result || memtable_size(result) != 0 ||
	    !RB_EMPTY_ROOT(&result->root))
		ret = -EINVAL;

out:
	memtable_free(result);
	memtable_free(newer);
	memtable_free(older);
	return ret;
}

static int memtable_test_compact_mappings(void)
{
	static const sector_t logical_blocks[] = { 10, 20, 30, 40 };
	static const sector_t expected[] = { 1000, 200, 300, 400 };
	struct lsm_memtable *older;
	struct lsm_memtable *newer;
	struct lsm_memtable *result = NULL;
	unsigned int older_size;
	unsigned int newer_size;
	unsigned int i;
	int ret;

	older = memtable_create();
	newer = memtable_create();
	if (!older || !newer) {
		ret = -ENOMEM;
		goto out;
	}

	/* Deliberately insert out of logical-block order. */
	ret = memtable_put(older, 40, 400);
	if (ret)
		goto out;
	ret = memtable_put(older, 10, 100);
	if (ret)
		goto out;
	ret = memtable_put(older, 20, 200);
	if (ret)
		goto out;

	ret = memtable_put(newer, 30, 300);
	if (ret)
		goto out;
	ret = memtable_put(newer, 10, 1000);
	if (ret)
		goto out;

	older_size = memtable_size(older);
	newer_size = memtable_size(newer);
	ret = memtable_compact(older, newer, &result);
	if (ret)
		goto out;

	if (!result || memtable_size(result) != ARRAY_SIZE(logical_blocks) ||
	    memtable_size(older) != older_size ||
	    memtable_size(newer) != newer_size) {
		ret = -EINVAL;
		goto out;
	}

	for (i = 0; i < ARRAY_SIZE(logical_blocks); i++) {
		sector_t before;
		sector_t after;

		ret = memtable_lookup(newer, logical_blocks[i], &before, NULL);
		if (ret == -ENODATA)
			ret = memtable_lookup(older, logical_blocks[i],
					      &before, NULL);
		if (ret)
			goto out;

		ret = memtable_lookup(result, logical_blocks[i], &after, NULL);
		if (ret || before != after || after != expected[i]) {
			ret = -EINVAL;
			goto out;
		}
	}

	/* Inputs must retain their original, generation-specific values. */
	{
		sector_t physical_sector;

		ret = memtable_lookup(older, 10, &physical_sector, NULL);
		if (ret || physical_sector != 100) {
			ret = -EINVAL;
			goto out;
		}
		ret = memtable_lookup(newer, 10, &physical_sector, NULL);
		if (ret || physical_sector != 1000) {
			ret = -EINVAL;
			goto out;
		}
	}

	ret = 0;

out:
	memtable_free(result);
	memtable_free(newer);
	memtable_free(older);
	return ret;
}

static int memtable_test_compact_errors(void)
{
	struct lsm_memtable *older;
	struct lsm_memtable *newer;
	struct lsm_memtable *result = NULL;
	sector_t physical_sector;
	int ret;

	older = memtable_create();
	newer = memtable_create();
	if (!older || !newer) {
		ret = -ENOMEM;
		goto out;
	}

	ret = memtable_put(older, 1, 8);
	if (ret)
		goto out;
	ret = memtable_put(older, 2, 16);
	if (ret)
		goto out;

	if (memtable_compact(NULL, newer, &result) != -EINVAL || result ||
	    memtable_compact(older, NULL, &result) != -EINVAL || result ||
	    memtable_compact(older, newer, NULL) != -EINVAL) {
		ret = -EINVAL;
		goto out;
	}

	/* Fail after one copied entry to exercise partial-result cleanup. */
	compact_puts_before_failure = 1;
	ret = memtable_compact_with_put(older, newer, &result,
					 memtable_test_failing_compact_put);
	if (ret != -ENOMEM || result) {
		ret = -EINVAL;
		goto out;
	}

	if (memtable_size(older) != 2 || memtable_size(newer) != 0) {
		ret = -EINVAL;
		goto out;
	}
	ret = memtable_lookup(older, 2, &physical_sector, NULL);
	if (ret || physical_sector != 16) {
		ret = -EINVAL;
		goto out;
	}

	ret = 0;

out:
	memtable_free(result);
	memtable_free(newer);
	memtable_free(older);
	return ret;
}

static int memtable_test_threshold_freeze(void)
{
	struct lsm_memtable *active;
	struct lsm_memtable *immutable = NULL;
	struct lsm_memtable *old_active;
	struct lsm_memtable *active_after_freeze;
	struct lsm_memtable *immutable_after_compaction;
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

	active_after_freeze = active;
	ret = memtable_put_active(&active, &immutable, &table_lock, 2, 10, 112);
	if (ret || active == active_after_freeze ||
	    immutable == old_active || memtable_size(active) != 0 ||
	    memtable_size(immutable) != 3) {
		ret = -EINVAL;
		goto out;
	}

	ret = memtable_lookup(immutable, 10, &physical_sector, NULL);
	if (ret || physical_sector != 112)
		goto invalid;
	ret = memtable_lookup(immutable, 12, &physical_sector, NULL);
	if (ret || physical_sector != 104)
		goto invalid;

	/* A later threshold must compact the generations again. */
	immutable_after_compaction = immutable;
	ret = memtable_put_active(&active, &immutable, &table_lock, 2, 14, 120);
	if (ret)
		goto out;
	ret = memtable_put_active(&active, &immutable, &table_lock, 2, 15, 128);
	if (ret || immutable == immutable_after_compaction ||
	    memtable_size(active) != 0 || memtable_size(immutable) != 5)
		goto invalid;

	ret = memtable_put_active(&active, &immutable, &table_lock, 2, 16, 136);
	if (ret)
		goto out;
	ret = memtable_lookup(active, 16, &physical_sector, NULL);
	if (ret || physical_sector != 136)
		goto invalid;

	ret = 0;
	goto out;

invalid:
	ret = -EINVAL;

out:
	memtable_free(active);
	memtable_free(immutable);
	return ret;
}

static int memtable_test_threshold_compaction_failures(void)
{
	struct lsm_memtable *active;
	struct lsm_memtable *immutable;
	struct lsm_memtable *old_active;
	struct lsm_memtable *old_immutable;
	struct mutex table_lock;
	sector_t physical_sector;
	int ret;

	active = memtable_create();
	immutable = memtable_create();
	if (!active || !immutable) {
		ret = -ENOMEM;
		goto out;
	}
	mutex_init(&table_lock);

	ret = memtable_put(immutable, 1, 8);
	if (ret)
		goto out;
	ret = memtable_put(active, 2, 16);
	if (ret)
		goto out;
	old_active = active;
	old_immutable = immutable;

	ret = memtable_put_active_with_ops(
			&active, &immutable, &table_lock, 2, 3, 24,
			memtable_test_failing_compact, memtable_create);
	if (ret || active != old_active || immutable != old_immutable)
		goto invalid;
	ret = memtable_lookup(active, 3, &physical_sector, NULL);
	if (ret || physical_sector != 24)
		goto invalid;

	/*
	 * Let merge succeed but fail creation of the replacement active.
	 * The temporary merged table must be discarded without publication.
	 */
	ret = memtable_put_active_with_ops(
			&active, &immutable, &table_lock, 2, 4, 32,
			memtable_compact, memtable_test_failing_create);
	if (ret || active != old_active || immutable != old_immutable)
		goto invalid;
	ret = memtable_lookup_active_immutable(
			&active, &immutable, &table_lock, 4, &physical_sector);
	if (ret || physical_sector != 32)
		goto invalid;

	ret = 0;
	goto out;

invalid:
	ret = -EINVAL;
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

	if (!active || !immutable || memtable_size(active) != 0 ||
	    memtable_size(immutable) !=
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

static const struct zns_test_case memtable_cases[] = {
	ZNS_TEST_CASE(memtable_test_heap_lifecycle,
		      "when a memtable heap is created, it starts empty and serves put and lookup"),
	ZNS_TEST_CASE(memtable_test_compact_empty,
		      "when two empty memtables are compacted, the result is empty"),
	ZNS_TEST_CASE(memtable_test_compact_mappings,
		      "when memtables are compacted, newer mappings win and the inputs stay unchanged"),
	ZNS_TEST_CASE(memtable_test_compact_errors,
		      "when compaction gets bad arguments or fails midway, partial results are freed"),
	ZNS_TEST_CASE(memtable_test_threshold_freeze,
		      "when the unique key threshold is reached, the active memtable freezes"),
	ZNS_TEST_CASE(memtable_test_threshold_compaction_failures,
		      "when maintenance fails, the mapping just written still survives"),
	ZNS_TEST_CASE(memtable_test_active_immutable_lookup,
		      "when a key lives in both generations, active wins and immutable is the fallback"),
	ZNS_TEST_CASE(memtable_test_threshold_freeze_concurrent,
		      "when two writers cross the threshold together, every mapping survives"),
	ZNS_TEST_CASE(memtable_test_freeze,
		      "when freeze is explicit, the generation pointers swap and a second freeze is refused"),
	ZNS_TEST_CASE(memtable_test_freeze_allocation_failure,
		      "when freeze cannot allocate, the memtable is left untouched"),
	ZNS_TEST_CASE(memtable_test_insert_lookup_update,
		      "when mappings are inserted and updated, lookups return the newest value"),
	ZNS_TEST_CASE(memtable_test_missing,
		      "when a key was never inserted, lookup reports it as missing"),
	ZNS_TEST_CASE(memtable_test_unordered_and_duplicate,
		      "when keys arrive unordered or duplicated, the tree stays sorted and unique"),
	ZNS_TEST_CASE(memtable_test_latest_mapping,
		      "when a key is rewritten, the latest physical mapping is kept"),
};

static int __init memtable_test_init(void)
{
	return zns_test_run("memtable", memtable_cases,
			    ARRAY_SIZE(memtable_cases));
}

static void __exit memtable_test_exit(void)
{
}

module_init(memtable_test_init);
module_exit(memtable_test_exit);

MODULE_DESCRIPTION("dm-zns-base in-memory memtable tests");
MODULE_LICENSE("GPL");
