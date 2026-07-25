// SPDX-License-Identifier: GPL-2.0
/* Standalone kernel-module tests for the in-memory memtable. */

#include <linux/errno.h>
#include <linux/module.h>

#include "../src/lsm-memtable.c"

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
