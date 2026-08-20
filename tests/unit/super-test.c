// SPDX-License-Identifier: GPL-2.0
/* Standalone kernel-module tests for the metadata zone superblock. */

#include <linux/errno.h>
#include <linux/module.h>
#include <linux/slab.h>

/* zns_super_read/write reach into the shared metadata block helper. */
#include "../../src/lsm-memtable.c"
#include "../../src/lsm-sstable.c"
#include "../../src/lsm-super.c"

#include "zns-test.h"

static const struct zns_super super_test_reference = {
	.uuid = 0x0123456789abcdefULL,
	.logical_sectors = 4194304,
	.zone_size_sectors = 131072,
	.nr_zones = 32,
	.meta_zone_id = 31,
	.sectors_per_block = 8,
};

static int super_test_roundtrip(void)
{
	const struct zns_super *source = &super_test_reference;
	struct zns_super decoded = {};
	void *block;
	int ret;

	block = kzalloc(ZNS_SST_BLOCK_BYTES, GFP_KERNEL);
	if (!block)
		return -ENOMEM;

	zns_super_encode(block, source);
	ret = zns_super_decode(block, &decoded);
	if (ret)
		goto out;

	if (decoded.uuid != source->uuid ||
	    decoded.logical_sectors != source->logical_sectors ||
	    decoded.zone_size_sectors != source->zone_size_sectors ||
	    decoded.nr_zones != source->nr_zones ||
	    decoded.meta_zone_id != source->meta_zone_id ||
	    decoded.sectors_per_block != source->sectors_per_block) {
		ret = -EINVAL;
		goto out;
	}

	/* A superblock always matches the format it was written from. */
	ret = zns_super_matches(&decoded, source);

out:
	kfree(block);
	return ret;
}

/*
 * The engine decides "never formatted" from the zone write pointer, but a
 * block full of anything else must not be mistaken for a superblock either.
 */
static int super_test_rejects_foreign_blocks(void)
{
	struct zns_super decoded = {};
	struct zns_super_disk *disk;
	void *block;
	int ret = 0;

	block = kzalloc(ZNS_SST_BLOCK_BYTES, GFP_KERNEL);
	if (!block)
		return -ENOMEM;

	/* A zone that was reset reads back as zeros. */
	if (zns_super_decode(block, &decoded) != -EINVAL) {
		ret = -EINVAL;
		goto out;
	}

	/* Somebody else's data that happens to sit in the first block. */
	memset(block, 0x5a, ZNS_SST_BLOCK_BYTES);
	if (zns_super_decode(block, &decoded) != -EINVAL) {
		ret = -EINVAL;
		goto out;
	}

	disk = block;

	zns_super_encode(block, &super_test_reference);
	disk->version = cpu_to_le32(ZNS_SUPER_VERSION + 1);
	if (zns_super_decode(block, &decoded) != -EINVAL) {
		ret = -EINVAL;
		goto out;
	}

	/* A single flipped field has to fail the checksum. */
	zns_super_encode(block, &super_test_reference);
	disk->nr_zones = cpu_to_le32(64);
	if (zns_super_decode(block, &decoded) != -EINVAL) {
		ret = -EINVAL;
		goto out;
	}

	/* So does a byte anywhere in the padding behind the fields. */
	zns_super_encode(block, &super_test_reference);
	((u8 *)block)[ZNS_SST_BLOCK_BYTES - 1] = 1;
	if (zns_super_decode(block, &decoded) != -EINVAL)
		ret = -EINVAL;

out:
	kfree(block);
	return ret;
}

/*
 * Every field except the uuid has to be compared: each one names something
 * the recorded mappings depend on.
 */
static int super_test_matches_each_field(void)
{
	struct zns_super changed;

	changed = super_test_reference;
	changed.uuid = ~changed.uuid;
	if (zns_super_matches(&super_test_reference, &changed))
		return -EINVAL;

	changed = super_test_reference;
	changed.nr_zones = 64;
	if (zns_super_matches(&super_test_reference, &changed) != -EINVAL)
		return -EINVAL;

	changed = super_test_reference;
	changed.logical_sectors = 2097152;
	if (zns_super_matches(&super_test_reference, &changed) != -EINVAL)
		return -EINVAL;

	changed = super_test_reference;
	changed.zone_size_sectors = 65536;
	if (zns_super_matches(&super_test_reference, &changed) != -EINVAL)
		return -EINVAL;

	changed = super_test_reference;
	changed.meta_zone_id = 63;
	if (zns_super_matches(&super_test_reference, &changed) != -EINVAL)
		return -EINVAL;

	changed = super_test_reference;
	changed.sectors_per_block = 16;
	if (zns_super_matches(&super_test_reference, &changed) != -EINVAL)
		return -EINVAL;

	return 0;
}

/* The superblock must leave room for an SSTable behind it in the same zone. */
static int super_test_fits_one_block(void)
{
	if (sizeof(struct zns_super_disk) > ZNS_SST_BLOCK_BYTES)
		return -EINVAL;

	return 0;
}

static const struct zns_test_case super_cases[] = {
	ZNS_TEST_CASE(super_test_fits_one_block,
		      "when the superblock is laid out, it fits in one metadata block"),
	ZNS_TEST_CASE(super_test_roundtrip,
		      "when a superblock is encoded, it decodes back to the same geometry"),
	ZNS_TEST_CASE(super_test_rejects_foreign_blocks,
		      "when a block is not a superblock we wrote, decoding refuses it"),
	ZNS_TEST_CASE(super_test_matches_each_field,
		      "when any geometry field changes, the match fails and the uuid is ignored"),
};

static int __init super_test_init(void)
{
	return zns_test_run("super", super_cases, ARRAY_SIZE(super_cases));
}

static void __exit super_test_exit(void)
{
}

module_init(super_test_init);
module_exit(super_test_exit);

MODULE_DESCRIPTION("dm-zns-base metadata zone superblock tests");
MODULE_LICENSE("GPL");
