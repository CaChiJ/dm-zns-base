// SPDX-License-Identifier: GPL-2.0
/*
 * On-disk SSTables for the LSM engine.
 *
 * A frozen MemTable is serialized into logical-block order and appended to the
 * reserved metadata zone. Lookups binary search the resulting blocks instead of
 * keeping the mappings resident in memory.
 *
 * Every helper here may sleep: submit_bio_wait() is used for both directions,
 * so callers must run outside the Device Mapper .map() context.
 */

#include <linux/bio.h>
#include <linux/blkdev.h>
#include <linux/crc32.h>
#include <linux/errno.h>
#include <linux/slab.h>
#include <linux/string.h>

#include "lsm-memtable.h"
#include "lsm-sstable.h"

unsigned int zns_sst_nr_blocks(u32 nr_entries)
{
	return 1 + DIV_ROUND_UP(nr_entries, ZNS_SST_ENTRIES_PER_BLOCK);
}

unsigned int zns_sst_entries_in_block(u32 nr_entries, unsigned int block_index)
{
	u32 consumed = block_index * ZNS_SST_ENTRIES_PER_BLOCK;

	if (consumed >= nr_entries)
		return 0;

	return min_t(u32, nr_entries - consumed, ZNS_SST_ENTRIES_PER_BLOCK);
}

void zns_sst_encode_header(void *block, const struct zns_sstable *sst,
			   u32 payload_crc)
{
	struct zns_sst_disk_header *header = block;

	memset(block, 0, ZNS_SST_BLOCK_BYTES);
	header->magic = cpu_to_le64(ZNS_SST_MAGIC);
	header->version = cpu_to_le32(ZNS_SST_VERSION);
	header->nr_entries = cpu_to_le32(sst->nr_entries);
	header->nr_blocks = cpu_to_le32(sst->nr_blocks);
	header->payload_crc = cpu_to_le32(payload_crc);
	header->seq = cpu_to_le64(sst->seq);
	header->min_key = cpu_to_le64(sst->min_key);
	header->max_key = cpu_to_le64(sst->max_key);
}

int zns_sst_decode_header(const void *block, struct zns_sstable *sst,
			  u32 *payload_crc)
{
	const struct zns_sst_disk_header *header = block;

	if (!block || !sst)
		return -EINVAL;
	if (le64_to_cpu(header->magic) != ZNS_SST_MAGIC)
		return -EINVAL;
	if (le32_to_cpu(header->version) != ZNS_SST_VERSION)
		return -EINVAL;

	sst->nr_entries = le32_to_cpu(header->nr_entries);
	sst->nr_blocks = le32_to_cpu(header->nr_blocks);
	if (!sst->nr_entries ||
	    sst->nr_blocks != zns_sst_nr_blocks(sst->nr_entries))
		return -EINVAL;

	sst->seq = le64_to_cpu(header->seq);
	sst->min_key = le64_to_cpu(header->min_key);
	sst->max_key = le64_to_cpu(header->max_key);
	if (sst->min_key > sst->max_key)
		return -EINVAL;

	if (payload_crc)
		*payload_crc = le32_to_cpu(header->payload_crc);

	return 0;
}

int zns_sst_block_first_key(const void *block, sector_t *logical_block)
{
	const struct zns_sst_disk_entry *entries = block;

	if (!block || !logical_block)
		return -EINVAL;

	*logical_block = le64_to_cpu(entries[0].logical_block);
	return 0;
}

int zns_sst_block_find(const void *block, unsigned int nr_in_block,
		       sector_t logical_block, sector_t *physical_sector)
{
	const struct zns_sst_disk_entry *entries = block;
	unsigned int low = 0;
	unsigned int high = nr_in_block;

	if (!block || !physical_sector || !nr_in_block ||
	    nr_in_block > ZNS_SST_ENTRIES_PER_BLOCK)
		return -EINVAL;

	while (low < high) {
		unsigned int mid = low + (high - low) / 2;
		sector_t key = le64_to_cpu(entries[mid].logical_block);

		if (key < logical_block) {
			low = mid + 1;
		} else if (key > logical_block) {
			high = mid;
		} else {
			*physical_sector =
				le64_to_cpu(entries[mid].physical_sector);
			return 0;
		}
	}

	return -ENODATA;
}

/*
 * Submit one 4 KiB block and wait. The buffer comes from kmalloc() so it is
 * permanently mapped; no kmap is needed around the sleeping submission.
 */
static int zns_sst_submit_block(struct block_device *bdev, sector_t sector,
				blk_opf_t opf, void *buffer)
{
	struct bio *bio;
	int ret;

	bio = bio_alloc(bdev, 1, opf, GFP_NOIO);
	if (!bio)
		return -ENOMEM;

	bio->bi_iter.bi_sector = sector;
	if (bio_add_page(bio, virt_to_page(buffer), ZNS_SST_BLOCK_BYTES,
			 offset_in_page(buffer)) != ZNS_SST_BLOCK_BYTES) {
		bio_put(bio);
		return -EIO;
	}

	ret = submit_bio_wait(bio);
	bio_put(bio);

	return ret;
}

struct zns_sst_write_ctx {
	struct block_device *bdev;
	sector_t sector;
	u32 crc;
	bool write;
};

/* Consume one fully assembled payload block. */
static int zns_sst_consume_block(struct zns_sst_write_ctx *ctx,
				 const void *block)
{
	int ret;

	ctx->crc = crc32_le(ctx->crc, block, ZNS_SST_BLOCK_BYTES);
	if (!ctx->write)
		return 0;

	ret = zns_sst_submit_block(ctx->bdev, ctx->sector, REQ_OP_WRITE,
				   (void *)block);
	if (ret)
		return ret;

	ctx->sector += ZNS_SST_BLOCK_SECTORS;
	return 0;
}

/*
 * Walk the memtable in logical-block order and hand each assembled payload
 * block to zns_sst_consume_block(). rb_first()/rb_next() already yield sorted
 * keys, so no separate sort is needed.
 *
 * The tree is walked without memtable->lock: the caller guarantees the table is
 * immutable for the duration of the flush.
 */
static int zns_sst_emit_payload(struct lsm_memtable *memtable, void *block,
				struct zns_sst_write_ctx *ctx)
{
	struct zns_sst_disk_entry *entries = block;
	struct rb_node *node;
	unsigned int nr_in_block = 0;
	int ret;

	memset(block, 0, ZNS_SST_BLOCK_BYTES);
	for (node = rb_first(&memtable->root); node; node = rb_next(node)) {
		const struct lsm_entry *entry;

		entry = rb_entry(node, struct lsm_entry, node);
		entries[nr_in_block].logical_block =
			cpu_to_le64(entry->logical_block);
		entries[nr_in_block].physical_sector =
			cpu_to_le64(entry->physical_sector);

		if (++nr_in_block < ZNS_SST_ENTRIES_PER_BLOCK)
			continue;

		ret = zns_sst_consume_block(ctx, block);
		if (ret)
			return ret;

		memset(block, 0, ZNS_SST_BLOCK_BYTES);
		nr_in_block = 0;
	}

	/* The tail block is zero padded so its CRC is reproducible. */
	if (nr_in_block)
		return zns_sst_consume_block(ctx, block);

	return 0;
}

static void zns_sst_scan_memtable(struct lsm_memtable *memtable,
				  struct zns_sstable *sst)
{
	struct rb_node *node;

	sst->nr_entries = 0;
	sst->min_key = 0;
	sst->max_key = 0;

	for (node = rb_first(&memtable->root); node; node = rb_next(node)) {
		const struct lsm_entry *entry;

		entry = rb_entry(node, struct lsm_entry, node);
		if (!sst->nr_entries)
			sst->min_key = entry->logical_block;
		sst->max_key = entry->logical_block;
		sst->nr_entries++;
	}
}

int zns_sst_write(struct block_device *bdev, struct lsm_memtable *memtable,
		  sector_t start_sector, sector_t end_sector, u64 seq,
		  struct zns_sstable **result, sector_t *consumed)
{
	struct zns_sst_write_ctx ctx;
	struct zns_sstable *sst;
	void *block;
	int ret;

	if (!bdev || !memtable || !result || !consumed)
		return -EINVAL;
	*result = NULL;
	*consumed = 0;

	if (start_sector >= end_sector)
		return -ENOSPC;

	sst = kzalloc(sizeof(*sst), GFP_NOIO);
	if (!sst)
		return -ENOMEM;

	INIT_LIST_HEAD(&sst->list);
	sst->start_sector = start_sector;
	sst->seq = seq;
	zns_sst_scan_memtable(memtable, sst);
	if (!sst->nr_entries) {
		ret = -ENODATA;
		goto free_sst;
	}

	sst->nr_blocks = zns_sst_nr_blocks(sst->nr_entries);
	if ((sector_t)sst->nr_blocks * ZNS_SST_BLOCK_SECTORS >
	    end_sector - start_sector) {
		ret = -ENOSPC;
		goto free_sst;
	}

	block = kmalloc(ZNS_SST_BLOCK_BYTES, GFP_NOIO);
	if (!block) {
		ret = -ENOMEM;
		goto free_sst;
	}

	/* Pass 1: CRC only, so the header can carry it despite being first. */
	ctx.bdev = bdev;
	ctx.sector = start_sector + ZNS_SST_BLOCK_SECTORS;
	ctx.crc = 0;
	ctx.write = false;
	ret = zns_sst_emit_payload(memtable, block, &ctx);
	if (ret)
		goto free_block;

	zns_sst_encode_header(block, sst, ctx.crc);
	ret = zns_sst_submit_block(bdev, start_sector, REQ_OP_WRITE, block);
	if (ret)
		goto free_block;
	*consumed = ZNS_SST_BLOCK_SECTORS;

	/* Pass 2: the payload itself, appended right behind the header. */
	ctx.sector = start_sector + ZNS_SST_BLOCK_SECTORS;
	ctx.crc = 0;
	ctx.write = true;
	ret = zns_sst_emit_payload(memtable, block, &ctx);

	/*
	 * Report what actually reached the zone even on failure. The zone write
	 * pointer has already moved past those blocks, so the caller must not
	 * hand the same sectors to the next flush.
	 */
	*consumed = ctx.sector - start_sector;
	if (ret)
		goto free_block;

	kfree(block);
	*result = sst;
	return 0;

free_block:
	kfree(block);
free_sst:
	kfree(sst);
	return ret;
}

static int zns_sst_read_payload_block(struct block_device *bdev,
				      const struct zns_sstable *sst,
				      unsigned int block_index, void *block,
				      unsigned int *cached)
{
	sector_t sector;
	int ret;

	if (*cached == block_index)
		return 0;

	sector = sst->start_sector +
		 (sector_t)(block_index + 1) * ZNS_SST_BLOCK_SECTORS;
	ret = zns_sst_submit_block(bdev, sector, REQ_OP_READ, block);
	if (ret)
		return ret;

	*cached = block_index;
	return 0;
}

int zns_sst_lookup(struct block_device *bdev, const struct zns_sstable *sst,
		   sector_t logical_block, sector_t *physical_sector)
{
	unsigned int cached = UINT_MAX;
	unsigned int low = 0;
	unsigned int high;
	void *block;
	int ret;

	if (!bdev || !sst || !physical_sector)
		return -EINVAL;
	if (sst->nr_blocks < 2)
		return -EINVAL;
	if (logical_block < sst->min_key || logical_block > sst->max_key)
		return -ENODATA;

	block = kmalloc(ZNS_SST_BLOCK_BYTES, GFP_NOIO);
	if (!block)
		return -ENOMEM;

	/*
	 * Locate the last payload block whose first key is still <= the wanted
	 * one, then search inside it. Blocks are sorted, so a hit can only live
	 * there. Payload blocks are indexed 0..nr_blocks-2; the header is not
	 * part of the search space.
	 */
	high = sst->nr_blocks - 2;
	while (low < high) {
		unsigned int mid = low + (high - low + 1) / 2;
		sector_t first_key;

		ret = zns_sst_read_payload_block(bdev, sst, mid, block,
						 &cached);
		if (ret)
			goto out;

		ret = zns_sst_block_first_key(block, &first_key);
		if (ret)
			goto out;

		if (first_key <= logical_block)
			low = mid;
		else
			high = mid - 1;
	}

	ret = zns_sst_read_payload_block(bdev, sst, low, block, &cached);
	if (ret)
		goto out;

	ret = zns_sst_block_find(block,
				 zns_sst_entries_in_block(sst->nr_entries, low),
				 logical_block, physical_sector);

out:
	kfree(block);
	return ret;
}
