/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LSM_SUPER_H
#define _LSM_SUPER_H

#include <linux/types.h>

#include "lsm-sstable.h"

struct block_device;

/*
 * Superblock of the reserved metadata zone.
 *
 * It occupies the first block of that zone and is written exactly once, when
 * the zone is still empty. A sequential-only zone cannot rewrite a block in
 * place, so the superblock records only what stays fixed for the life of the
 * format: the geometry every mapping below it was recorded against.
 *
 * Its job is to make a changed device loud instead of silent. Without it a
 * different zone count moves the reserved zone somewhere else, the old
 * SSTables become ordinary data space, and every mapping is lost with no
 * error anywhere.
 */
#define ZNS_SUPER_MAGIC		0x5a4e535355504552ULL	/* "ZNSSUPER" */
#define ZNS_SUPER_VERSION	1u

struct zns_super_disk {
	__le64 magic;
	__le32 version;
	__le32 crc;		/* crc32_le from uuid to the end of the block */
	__le64 uuid;
	__le64 logical_sectors;
	__le64 zone_size_sectors;
	__le32 nr_zones;
	__le32 meta_zone_id;
	__le32 sectors_per_block;
	__le32 reserved;
} __packed;

/* In-memory form. uuid identifies one format and is not compared. */
struct zns_super {
	u64 uuid;
	sector_t logical_sectors;
	sector_t zone_size_sectors;
	u32 nr_zones;
	u32 meta_zone_id;
	u32 sectors_per_block;
};

void zns_super_encode(void *block, const struct zns_super *super);

/* Returns 0, or -EINVAL when the block is not a superblock we wrote. */
int zns_super_decode(const void *block, struct zns_super *super);

/*
 * Compare the geometry a format was made with against the device in front of
 * us. Returns 0, or -EINVAL after naming the first field that disagrees.
 */
int zns_super_matches(const struct zns_super *on_disk,
		      const struct zns_super *device);

/* Both sleep on block I/O, so neither may be called from .map(). */
int zns_super_write(struct block_device *bdev, sector_t sector,
		    const struct zns_super *super);
int zns_super_read(struct block_device *bdev, sector_t sector,
		   struct zns_super *super);

#endif
