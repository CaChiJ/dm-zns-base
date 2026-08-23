// SPDX-License-Identifier: GPL-2.0
/*
 * Superblock of the reserved metadata zone.
 *
 * Written once into an empty metadata zone and only ever read afterwards, so
 * that a device whose geometry no longer matches the format is refused instead
 * of quietly presenting every old mapping as a hole.
 */

#include <linux/crc32.h>
#include <linux/device-mapper.h>
#include <linux/errno.h>
#include <linux/slab.h>
#include <linux/string.h>

#include "lsm-super.h"

#define DM_MSG_PREFIX "zns-base"

/*
 * Cover everything from uuid onwards, padding included. Starting past the crc
 * field keeps the checksum computable without mutating the block.
 */
static u32 zns_super_crc(const void *block)
{
	unsigned int offset = offsetof(struct zns_super_disk, uuid);

	return crc32_le(0, (const u8 *)block + offset,
			ZNS_SST_BLOCK_BYTES - offset);
}

void zns_super_encode(void *block, const struct zns_super *super)
{
	struct zns_super_disk *disk = block;

	memset(block, 0, ZNS_SST_BLOCK_BYTES);
	disk->magic = cpu_to_le64(ZNS_SUPER_MAGIC);
	disk->version = cpu_to_le32(ZNS_SUPER_VERSION);
	disk->uuid = cpu_to_le64(super->uuid);
	disk->logical_sectors = cpu_to_le64(super->logical_sectors);
	disk->zone_size_sectors = cpu_to_le64(super->zone_size_sectors);
	disk->nr_zones = cpu_to_le32(super->nr_zones);
	disk->meta_zone_id = cpu_to_le32(super->meta_zone_id);
	disk->sectors_per_block = cpu_to_le32(super->sectors_per_block);

	/* Last, so that it covers the fields above and the zero padding. */
	disk->crc = cpu_to_le32(zns_super_crc(block));
}

int zns_super_decode(const void *block, struct zns_super *super)
{
	const struct zns_super_disk *disk = block;

	if (!block || !super)
		return -EINVAL;
	if (le64_to_cpu(disk->magic) != ZNS_SUPER_MAGIC)
		return -EINVAL;
	if (le32_to_cpu(disk->version) != ZNS_SUPER_VERSION)
		return -EINVAL;
	if (le32_to_cpu(disk->crc) != zns_super_crc(block))
		return -EINVAL;

	super->uuid = le64_to_cpu(disk->uuid);
	super->logical_sectors = le64_to_cpu(disk->logical_sectors);
	super->zone_size_sectors = le64_to_cpu(disk->zone_size_sectors);
	super->nr_zones = le32_to_cpu(disk->nr_zones);
	super->meta_zone_id = le32_to_cpu(disk->meta_zone_id);
	super->sectors_per_block = le32_to_cpu(disk->sectors_per_block);

	return 0;
}

/* One field at a time, so the log says what actually moved. */
static int zns_super_compare(const char *field, u64 on_disk, u64 device)
{
	if (on_disk == device)
		return 0;

	DMERR("superblock mismatch: %s was %llu at format time, now %llu",
	      field, (unsigned long long)on_disk, (unsigned long long)device);
	return -EINVAL;
}

int zns_super_matches(const struct zns_super *on_disk,
		      const struct zns_super *device)
{
	int ret;

	if (!on_disk || !device)
		return -EINVAL;

	ret = zns_super_compare("sectors_per_block", on_disk->sectors_per_block,
				device->sectors_per_block);
	if (ret)
		return ret;
	ret = zns_super_compare("nr_zones", on_disk->nr_zones,
				device->nr_zones);
	if (ret)
		return ret;
	ret = zns_super_compare("zone_size_sectors", on_disk->zone_size_sectors,
				device->zone_size_sectors);
	if (ret)
		return ret;
	ret = zns_super_compare("meta_zone_id", on_disk->meta_zone_id,
				device->meta_zone_id);
	if (ret)
		return ret;

	return zns_super_compare("logical_sectors", on_disk->logical_sectors,
				 device->logical_sectors);
}

int zns_super_write(struct block_device *bdev, sector_t sector,
		    const struct zns_super *super)
{
	void *block;
	int ret;

	if (!bdev || !super)
		return -EINVAL;

	block = kmalloc(ZNS_SST_BLOCK_BYTES, GFP_KERNEL);
	if (!block)
		return -ENOMEM;

	zns_super_encode(block, super);
	ret = zns_meta_block_rw(bdev, sector, REQ_OP_WRITE, block);

	kfree(block);
	return ret;
}

int zns_super_read(struct block_device *bdev, sector_t sector,
		   struct zns_super *super)
{
	void *block;
	int ret;

	if (!bdev || !super)
		return -EINVAL;

	block = kmalloc(ZNS_SST_BLOCK_BYTES, GFP_KERNEL);
	if (!block)
		return -ENOMEM;

	ret = zns_meta_block_rw(bdev, sector, REQ_OP_READ, block);
	if (!ret)
		ret = zns_super_decode(block, super);

	kfree(block);
	return ret;
}
