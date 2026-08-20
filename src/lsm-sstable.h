/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LSM_SSTABLE_H
#define _LSM_SSTABLE_H

#include <linux/list.h>
#include <linux/types.h>

struct block_device;
struct lsm_memtable;

/*
 * On-disk SSTable layout. One SSTable is a header block followed by blocks of
 * logical-block-ordered entries, appended sequentially to the reserved
 * metadata zone.
 *
 *   [header][entries 0..255][entries 256..511]...[tail, zero padded]
 *
 * Nothing reads these blocks back after a restart yet. The magic, version,
 * sequence number, and CRC exist so that recovery can be added without
 * changing the format.
 */
#define ZNS_SST_MAGIC		0x5a4e53535354424bULL	/* "ZNSSSTBK" */
#define ZNS_SST_VERSION		1u
#define ZNS_SST_BLOCK_BYTES	4096u
#define ZNS_SST_BLOCK_SECTORS	8u

struct zns_sst_disk_header {
	__le64 magic;
	__le32 version;
	__le32 nr_entries;
	__le32 nr_blocks;	/* header block included */
	__le32 payload_crc;	/* crc32_le over every payload block */
	__le64 seq;
	__le64 min_key;
	__le64 max_key;
} __packed;

struct zns_sst_disk_entry {
	__le64 logical_block;
	__le64 physical_sector;
} __packed;

#define ZNS_SST_ENTRIES_PER_BLOCK \
	(ZNS_SST_BLOCK_BYTES / sizeof(struct zns_sst_disk_entry))

/* In-memory index of one flushed SSTable. */
struct zns_sstable {
	struct list_head list;
	sector_t start_sector;	/* header block */
	u32 nr_entries;
	u32 nr_blocks;
	sector_t min_key;
	sector_t max_key;
	u64 seq;
};

/* Total blocks, header included, needed to hold nr_entries mappings. */
unsigned int zns_sst_nr_blocks(u32 nr_entries);

/* Entries stored in payload block block_index of an SSTable. */
unsigned int zns_sst_entries_in_block(u32 nr_entries, unsigned int block_index);

void zns_sst_encode_header(void *block, const struct zns_sstable *sst,
			   u32 payload_crc);
int zns_sst_decode_header(const void *block, struct zns_sstable *sst,
			  u32 *payload_crc);

/* First logical block stored in a payload block. */
int zns_sst_block_first_key(const void *block, sector_t *logical_block);

/* Binary search one payload block. Returns 0, -ENODATA, or -EINVAL. */
int zns_sst_block_find(const void *block, unsigned int nr_in_block,
		       sector_t logical_block, sector_t *physical_sector);

/*
 * Append memtable to bdev at start_sector, without crossing end_sector, and
 * hand back the in-memory index on success. Returns -ENODATA for an empty
 * memtable and -ENOSPC when the reserved region cannot hold the SSTable.
 *
 * *consumed reports the sectors that reached the zone, and is set even when the
 * call fails partway: the zone write pointer has moved past them, so the caller
 * must never reuse those sectors.
 *
 * The caller must keep the memtable immutable for the whole call: it is walked
 * twice, once to compute the CRC and once to write.
 */
int zns_sst_write(struct block_device *bdev, struct lsm_memtable *memtable,
		  sector_t start_sector, sector_t end_sector, u64 seq,
		  struct zns_sstable **result, sector_t *consumed);

/* Look one mapping up on disk. Returns 0, -ENODATA, or an I/O error. */
int zns_sst_lookup(struct block_device *bdev, const struct zns_sstable *sst,
		   sector_t logical_block, sector_t *physical_sector);

#endif
