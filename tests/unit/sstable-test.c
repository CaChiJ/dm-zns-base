// SPDX-License-Identifier: GPL-2.0
/* Standalone kernel-module tests for the on-disk SSTable format helpers. */

#include <linux/errno.h>
#include <linux/module.h>
#include <linux/slab.h>

#include "../../src/lsm-memtable.c"
#include "../../src/lsm-sstable.c"

#include "zns-test.h"

#define SST_TEST_SEQ 7

static void sstable_test_fill_block(void *block, unsigned int nr_in_block,
				    sector_t first_key)
{
	struct zns_sst_disk_entry *entries = block;
	unsigned int i;

	memset(block, 0, ZNS_SST_BLOCK_BYTES);
	for (i = 0; i < nr_in_block; i++) {
		entries[i].logical_block = cpu_to_le64(first_key + i * 2);
		entries[i].physical_sector = cpu_to_le64((first_key + i * 2) * 8);
	}
}

static int sstable_test_block_geometry(void)
{
	if (ZNS_SST_ENTRIES_PER_BLOCK != 256) {
		pr_err("unexpected entries per block: %lu\n",
		       (unsigned long)ZNS_SST_ENTRIES_PER_BLOCK);
		return -EINVAL;
	}

	/* One header block plus the payload blocks the entries need. */
	if (zns_sst_nr_blocks(1) != 2 || zns_sst_nr_blocks(256) != 2 ||
	    zns_sst_nr_blocks(257) != 3 || zns_sst_nr_blocks(512) != 3 ||
	    zns_sst_nr_blocks(U32_MAX) != 16777217)
		return -EINVAL;

	if (zns_sst_entries_in_block(300, 0) != 256 ||
	    zns_sst_entries_in_block(300, 1) != 44 ||
	    zns_sst_entries_in_block(300, 2) != 0)
		return -EINVAL;

	return 0;
}

static int sstable_test_header_roundtrip(void)
{
	struct zns_sstable source = {
		.start_sector = 4096,
		.nr_entries = 300,
		.nr_blocks = 3,
		.min_key = 11,
		.max_key = 9999,
		.seq = SST_TEST_SEQ,
	};
	struct zns_sstable decoded = {};
	u32 crc = 0;
	void *block;
	int ret = 0;

	block = kzalloc(ZNS_SST_BLOCK_BYTES, GFP_KERNEL);
	if (!block)
		return -ENOMEM;

	zns_sst_encode_header(block, &source, 0xdeadbeef);
	ret = zns_sst_decode_header(block, &decoded, &crc);
	if (ret)
		goto out;

	if (decoded.nr_entries != source.nr_entries ||
	    decoded.nr_blocks != source.nr_blocks ||
	    decoded.min_key != source.min_key ||
	    decoded.max_key != source.max_key ||
	    decoded.seq != source.seq || crc != 0xdeadbeef) {
		ret = -EINVAL;
		goto out;
	}

	/* A block that was never written must not decode as a header. */
	memset(block, 0, ZNS_SST_BLOCK_BYTES);
	if (zns_sst_decode_header(block, &decoded, NULL) != -EINVAL) {
		ret = -EINVAL;
		goto out;
	}

	/* nr_blocks must agree with nr_entries. */
	zns_sst_encode_header(block, &source, 0);
	((struct zns_sst_disk_header *)block)->nr_blocks = cpu_to_le32(9);
	if (zns_sst_decode_header(block, &decoded, NULL) != -EINVAL)
		ret = -EINVAL;

out:
	kfree(block);
	return ret;
}

static int sstable_test_block_find(void)
{
	sector_t physical_sector;
	sector_t first_key;
	void *block;
	int ret = 0;

	block = kzalloc(ZNS_SST_BLOCK_BYTES, GFP_KERNEL);
	if (!block)
		return -ENOMEM;

	/* Keys 100, 102, ... 610 -- every odd key in between is a miss. */
	sstable_test_fill_block(block, 256, 100);

	if (zns_sst_block_first_key(block, &first_key) || first_key != 100) {
		ret = -EINVAL;
		goto out;
	}

	/* First, last, and an interior key. */
	if (zns_sst_block_find(block, 256, 100, &physical_sector) ||
	    physical_sector != 800) {
		ret = -EINVAL;
		goto out;
	}
	if (zns_sst_block_find(block, 256, 610, &physical_sector) ||
	    physical_sector != 4880) {
		ret = -EINVAL;
		goto out;
	}
	if (zns_sst_block_find(block, 256, 200, &physical_sector) ||
	    physical_sector != 1600) {
		ret = -EINVAL;
		goto out;
	}

	/* Misses inside, below, and above the key range. */
	if (zns_sst_block_find(block, 256, 201, &physical_sector) != -ENODATA ||
	    zns_sst_block_find(block, 256, 99, &physical_sector) != -ENODATA ||
	    zns_sst_block_find(block, 256, 611, &physical_sector) != -ENODATA) {
		ret = -EINVAL;
		goto out;
	}

	/*
	 * A partially filled tail block must not match the zero padding behind
	 * the live entries.
	 */
	sstable_test_fill_block(block, 3, 100);
	if (zns_sst_block_find(block, 3, 104, &physical_sector) ||
	    physical_sector != 832) {
		ret = -EINVAL;
		goto out;
	}
	if (zns_sst_block_find(block, 3, 0, &physical_sector) != -ENODATA) {
		ret = -EINVAL;
		goto out;
	}

	/* Single-entry block. */
	sstable_test_fill_block(block, 1, 42);
	if (zns_sst_block_find(block, 1, 42, &physical_sector) ||
	    physical_sector != 336) {
		ret = -EINVAL;
		goto out;
	}
	if (zns_sst_block_find(block, 1, 43, &physical_sector) != -ENODATA) {
		ret = -EINVAL;
		goto out;
	}

	/* Invalid arguments. */
	if (zns_sst_block_find(NULL, 1, 42, &physical_sector) != -EINVAL ||
	    zns_sst_block_find(block, 0, 42, &physical_sector) != -EINVAL ||
	    zns_sst_block_find(block, 257, 42, &physical_sector) != -EINVAL ||
	    zns_sst_block_find(block, 1, 42, NULL) != -EINVAL)
		ret = -EINVAL;

out:
	kfree(block);
	return ret;
}

/*
 * The flush path relies on rb_first()/rb_next() already yielding sorted keys,
 * and on the scan pass agreeing with what the write pass emits.
 */
static int sstable_test_memtable_scan(void)
{
	static const sector_t keys[] = { 90, 3, 41, 3, 7 };
	struct zns_sstable sst = {};
	struct lsm_memtable *memtable;
	struct rb_node *node;
	sector_t previous = 0;
	unsigned int seen = 0;
	unsigned int i;
	int ret = 0;

	memtable = memtable_create();
	if (!memtable)
		return -ENOMEM;

	for (i = 0; i < ARRAY_SIZE(keys); i++) {
		ret = memtable_put(memtable, keys[i], keys[i] * 8);
		if (ret)
			goto out;
	}

	zns_sst_scan_memtable(memtable, &sst);
	/* 3 appears twice, so four unique keys survive. */
	if (sst.nr_entries != 4 || sst.min_key != 3 || sst.max_key != 90) {
		ret = -EINVAL;
		goto out;
	}

	for (node = rb_first(&memtable->root); node; node = rb_next(node)) {
		const struct lsm_entry *entry;

		entry = rb_entry(node, struct lsm_entry, node);
		if (seen && entry->logical_block <= previous) {
			ret = -EINVAL;
			goto out;
		}
		previous = entry->logical_block;
		seen++;
	}

	if (seen != sst.nr_entries)
		ret = -EINVAL;

out:
	memtable_free(memtable);
	return ret;
}

static const struct zns_test_case sstable_cases[] = {
	ZNS_TEST_CASE(sstable_test_block_geometry,
		      "when entries fill a 4 KiB block, 256 fit and the block count rounds up"),
	ZNS_TEST_CASE(sstable_test_header_roundtrip,
		      "when a header is encoded, it decodes back and a zero block is not a header"),
	ZNS_TEST_CASE(sstable_test_block_find,
		      "when a block is searched, hits, misses, and a padded tail all behave"),
	ZNS_TEST_CASE(sstable_test_memtable_scan,
		      "when a memtable is scanned, its order and key range match the tree"),
};

static int __init sstable_test_init(void)
{
	return zns_test_run("sstable", sstable_cases,
			    ARRAY_SIZE(sstable_cases));
}

static void __exit sstable_test_exit(void)
{
}

module_init(sstable_test_init);
module_exit(sstable_test_exit);

MODULE_DESCRIPTION("dm-zns-base on-disk SSTable format tests");
MODULE_LICENSE("GPL");
