// SPDX-License-Identifier: GPL-2.0
/*
 * LSM engine: MemTable generations backed by on-disk SSTables.
 *
 * Writes append to the zoned allocator and land in the active MemTable. When it
 * reaches the threshold it is frozen, then flushed to the reserved metadata zone
 * as an SSTable and released from memory. Reads walk
 *
 *	active -> immutable -> flushing -> SSTables (newest first)
 *
 * and fall back to a zero fill when the logical block was never written.
 */

#include <linux/bio.h>
#include <linux/blkzoned.h>
#include <linux/device-mapper.h>
#include <linux/errno.h>
#include <linux/highmem.h>
#include <linux/list.h>
#include <linux/module.h>
#include <linux/random.h>
#include <linux/slab.h>
#include <linux/workqueue.h>

#include "lsm-memtable.h"
#include "lsm-sstable.h"
#include "lsm-super.h"
#include "zns-allocator.h"
#include "zns-engine.h"
#include "zns-zone.h"

#define DM_MSG_PREFIX "zns-base"

#define ZNS_LSM_MEMTABLE_THRESHOLD 16384

static unsigned int zns_lsm_memtable_threshold =
	ZNS_LSM_MEMTABLE_THRESHOLD;
module_param_named(memtable_threshold, zns_lsm_memtable_threshold, uint, 0444);
MODULE_PARM_DESC(memtable_threshold,
		 "Number of active MemTable entries that triggers a freeze");

#ifdef DM_ZNS_BASE_TESTING
/*
 * Test-only approximation of losing volatile mappings after I/O has quiesced.
 * It deliberately does not claim to model an in-flight crash or power loss.
 */
static bool zns_lsm_test_skip_shutdown_flush;
module_param_named(test_skip_shutdown_flush,
		   zns_lsm_test_skip_shutdown_flush, bool, 0400);
MODULE_PARM_DESC(test_skip_shutdown_flush,
		 "TEST ONLY: omit the clean-detach MemTable flush");
#endif

struct zns_lsm {
	struct block_device *lower_bdev;
	struct zns_zone_table zone_table;
	struct zns_allocator allocator;

	/* MemTable generations, all guarded by table_lock. */
	struct lsm_memtable *active_memtable;
	struct lsm_memtable *immutable_memtable;
	struct lsm_memtable *flushing_memtable;
	struct mutex table_lock;
	bool flush_in_flight;
	unsigned int memtable_threshold;
	sector_t logical_sectors;
	sector_t sectors_per_block;

	/* Reserved metadata zone and its SSTables, all guarded by sst_lock. */
	struct mutex sst_lock;
	struct list_head sstables;
	unsigned int nr_sstables;
	u64 nr_sst_entries;
	u64 next_sst_seq;
	sector_t meta_start;
	sector_t meta_wp;
	sector_t meta_end;
	struct zns_super super;

	struct workqueue_struct *flush_wq;
	struct workqueue_struct *io_wq;
	struct work_struct flush_work;
};

struct zns_lsm_io_work {
	struct work_struct work;
	struct zns_lsm *lsm;
	struct bio *bio;
};

struct zns_lsm_wp_report {
	sector_t write_pointer;
	u8 condition;
};

static int zns_lsm_wp_report_cb(struct blk_zone *zone, unsigned int index,
				void *data)
{
	struct zns_lsm_wp_report *report = data;

	(void)index;
	report->write_pointer = zone->wp;
	report->condition = zone->cond;
	return 0;
}

static int zns_lsm_report_wp(struct zns_lsm *lsm, sector_t sector,
			     struct zns_lsm_wp_report *report)
{
	int ret;

	report->write_pointer = (sector_t)-1;
	report->condition = BLK_ZONE_COND_NOT_WP;
	ret = blkdev_report_zones(lsm->lower_bdev, sector, 1,
				  zns_lsm_wp_report_cb, report);
	if (ret < 0)
		return ret;
	if (ret != 1)
		return -EIO;

	return 0;
}

static int __maybe_unused zns_lsm_freeze_memtable(struct zns_lsm *lsm)
{
	if (!lsm)
		return -EINVAL;

	return memtable_freeze(&lsm->active_memtable,
			       &lsm->immutable_memtable,
			       &lsm->table_lock);
}

/*
 * Newest generation wins. memtable_lookup_active_immutable() only knows about
 * two generations, so the flushing slot is checked here under the same lock.
 */
static int zns_lsm_lookup_memtables(struct zns_lsm *lsm, sector_t logical_block,
				    sector_t *physical_sector)
{
	int ret;

	mutex_lock(&lsm->table_lock);
	if (!lsm->active_memtable) {
		ret = -EINVAL;
		goto unlock;
	}

	ret = memtable_lookup(lsm->active_memtable, logical_block,
			      physical_sector, NULL);
	if (ret == -ENODATA && lsm->immutable_memtable)
		ret = memtable_lookup(lsm->immutable_memtable, logical_block,
				      physical_sector, NULL);
	if (ret == -ENODATA && lsm->flushing_memtable)
		ret = memtable_lookup(lsm->flushing_memtable, logical_block,
				      physical_sector, NULL);

unlock:
	mutex_unlock(&lsm->table_lock);
	return ret;
}

/*
 * Sleeps on SSTable reads, so this only runs from the read workqueue. The list
 * is append-only in this milestone, but sst_lock is held for the whole walk so
 * that a concurrent flush cannot splice a new head underneath it.
 */
static int zns_lsm_lookup_sstables(struct zns_lsm *lsm, sector_t logical_block,
				   sector_t *physical_sector)
{
	struct zns_sstable *sst;
	int ret = -ENODATA;

	mutex_lock(&lsm->sst_lock);
	list_for_each_entry(sst, &lsm->sstables, list) {
		ret = zns_sst_lookup(lsm->lower_bdev, sst, logical_block,
				     physical_sector);
		if (ret != -ENODATA)
			break;
	}
	mutex_unlock(&lsm->sst_lock);

	return ret;
}

/*
 * Claim the next MemTable to flush. A table already parked in the flushing slot
 * is a previous attempt that failed and is retried first. Moving the table out
 * of the immutable slot keeps memtable_put_active() from replacing and freeing
 * it while the flush is in progress.
 */
static struct lsm_memtable *zns_lsm_claim_flush_victim(struct zns_lsm *lsm)
{
	struct lsm_memtable *victim;

	mutex_lock(&lsm->table_lock);
	if (!lsm->flushing_memtable) {
		lsm->flushing_memtable = lsm->immutable_memtable;
		lsm->immutable_memtable = NULL;
	}
	victim = lsm->flushing_memtable;
	mutex_unlock(&lsm->table_lock);

	return victim;
}

static void zns_lsm_release_flush_victim(struct zns_lsm *lsm,
					 struct lsm_memtable *victim)
{
	mutex_lock(&lsm->table_lock);
	lsm->flushing_memtable = NULL;
	mutex_unlock(&lsm->table_lock);

	memtable_free(victim);
}

/*
 * Give up the metadata sectors a flush attempt burned. This must happen even
 * when the flush failed: the zone write pointer has already moved past them, so
 * reusing the same sectors would be a sequential-write violation.
 */
static void zns_lsm_advance_meta_wp(struct zns_lsm *lsm, sector_t start,
				    sector_t consumed)
{
	mutex_lock(&lsm->sst_lock);
	if (start + consumed > lsm->meta_wp)
		lsm->meta_wp = start + consumed;
	mutex_unlock(&lsm->sst_lock);
}

/*
 * A failed sequential-zone write may still move the device write pointer.
 * Re-read it before another flush can choose an append position. If the zone
 * cannot be inspected reliably, sacrifice the remaining metadata capacity
 * instead of risking a write behind the real WP.
 */
static void zns_lsm_reconcile_failed_meta_write(struct zns_lsm *lsm,
						 sector_t start,
						 sector_t consumed)
{
	struct zns_lsm_wp_report report;
	sector_t accounted = start + consumed;
	sector_t actual;
	bool unusable = consumed > 0;
	int ret;

	/*
	 * Once the header has landed, any later error leaves an incomplete record
	 * at the tail even when the failed block did not move the device WP. A retry
	 * after that header would make the torn record interior corruption, so this
	 * instance must never append to the metadata zone again.
	 */
	if (unusable)
		DMERR_LIMIT("metadata write left an incomplete record at sector %llu",
			    (unsigned long long)start);

	ret = zns_lsm_report_wp(lsm, start, &report);
	if (ret) {
		DMERR_LIMIT("failed to inspect metadata zone after write error: %d",
			    ret);
		unusable = true;
		actual = lsm->meta_end;
	} else if (report.condition == BLK_ZONE_COND_FULL) {
		actual = lsm->meta_end;
	} else {
		actual = report.write_pointer;
	}

	/*
	 * Any mismatch means the failed write consumed an unknown amount of media or
	 * the report cannot be reconciled with completed writes. Do not resume this
	 * zone from an untrustworthy append position.
	 */
	if (!ret && actual != accounted) {
		DMERR_LIMIT("metadata write pointer is inconsistent after error: expected %llu, reported %llu",
			    (unsigned long long)accounted,
			    (unsigned long long)actual);
		unusable = true;
	}
	if (unusable)
		actual = lsm->meta_end;

	mutex_lock(&lsm->sst_lock);
	if (actual > lsm->meta_wp)
		lsm->meta_wp = actual;
	mutex_unlock(&lsm->sst_lock);

	if (unusable)
		DMERR_LIMIT("metadata appends disabled until the zone is reset");
}

static void zns_lsm_publish_sstable(struct zns_lsm *lsm,
				    struct zns_sstable *sst)
{
	mutex_lock(&lsm->sst_lock);
	list_add(&sst->list, &lsm->sstables);
	lsm->nr_sstables++;
	lsm->nr_sst_entries += sst->nr_entries;
	lsm->next_sst_seq++;
	mutex_unlock(&lsm->sst_lock);
}

static void zns_lsm_maybe_queue_flush(struct zns_lsm *lsm)
{
	bool queue;

	mutex_lock(&lsm->table_lock);
	queue = !lsm->flush_in_flight &&
		(lsm->immutable_memtable || lsm->flushing_memtable);
	if (queue)
		lsm->flush_in_flight = true;
	mutex_unlock(&lsm->table_lock);

	if (queue)
		queue_work(lsm->flush_wq, &lsm->flush_work);
}

static void zns_lsm_flush_worker(struct work_struct *work)
{
	struct zns_lsm *lsm = container_of(work, struct zns_lsm, flush_work);
	bool failed = false;

	for (;;) {
		struct lsm_memtable *victim;
		struct zns_sstable *sst;
		sector_t consumed;
		sector_t start;
		u64 seq;
		int ret;

		victim = zns_lsm_claim_flush_victim(lsm);
		if (!victim)
			break;

		mutex_lock(&lsm->sst_lock);
		start = lsm->meta_wp;
		seq = lsm->next_sst_seq;
		mutex_unlock(&lsm->sst_lock);

		ret = zns_sst_write(lsm->lower_bdev, victim, start,
				    lsm->meta_end, seq, &sst, &consumed);
		if (consumed)
			zns_lsm_advance_meta_wp(lsm, start, consumed);
		if (ret && ret != -ENODATA && start < lsm->meta_end)
			zns_lsm_reconcile_failed_meta_write(lsm, start,
							 consumed);

		if (ret == -ENODATA) {
			/* Nothing to persist; just reclaim the table. */
			zns_lsm_release_flush_victim(lsm, victim);
			continue;
		}
		if (ret) {
			/*
			 * Leave the table in the flushing slot: reads keep
			 * finding it and the next write retries the flush.
			 */
			DMERR_LIMIT("sstable flush failed: %d", ret);
			failed = true;
			break;
		}

		zns_lsm_publish_sstable(lsm, sst);
		zns_lsm_release_flush_victim(lsm, victim);
	}

	mutex_lock(&lsm->table_lock);
	lsm->flush_in_flight = false;
	mutex_unlock(&lsm->table_lock);

	/* Catch a freeze that landed after the last claim but before the clear. */
	if (!failed)
		zns_lsm_maybe_queue_flush(lsm);
}

static int zns_lsm_lookup_block(struct zns_lsm *lsm, sector_t logical_block,
				sector_t *physical_sector)
{
	int ret;

	ret = zns_lsm_lookup_memtables(lsm, logical_block, physical_sector);
	if (ret == -ENODATA)
		ret = zns_lsm_lookup_sstables(lsm, logical_block,
					      physical_sector);
	return ret;
}

static int zns_lsm_submit_block(struct zns_lsm *lsm, sector_t sector,
				blk_opf_t opf, struct page *page)
{
	struct bio *bio;
	unsigned int bytes = lsm->sectors_per_block << SECTOR_SHIFT;
	int ret;

	bio = bio_alloc(lsm->lower_bdev, 1, opf, GFP_NOIO);
	if (!bio)
		return -ENOMEM;

	bio->bi_iter.bi_sector = sector;
	if (bio_add_page(bio, page, bytes, 0) != bytes) {
		bio_put(bio);
		return -EIO;
	}

	ret = submit_bio_wait(bio);
	bio_put(bio);
	return ret;
}

static int zns_lsm_copy_bio_range(struct bio *bio, unsigned int bio_offset,
				   void *buffer, unsigned int length,
				   bool to_bio)
{
	struct bio_vec bv;
	struct bvec_iter iter;
	unsigned int cursor = 0;
	unsigned int copied = 0;

	bio_for_each_segment(bv, bio, iter) {
		unsigned int start;
		unsigned int chunk;
		void *mapped;

		if (bio_offset >= cursor + bv.bv_len) {
			cursor += bv.bv_len;
			continue;
		}

		start = bio_offset > cursor ? bio_offset - cursor : 0;
		chunk = min(length - copied, bv.bv_len - start);
		mapped = bvec_kmap_local(&bv);
		if (to_bio)
			memcpy((char *)mapped + start,
			       (char *)buffer + copied, chunk);
		else
			memcpy((char *)buffer + copied,
			       (char *)mapped + start, chunk);
		kunmap_local(mapped);

		copied += chunk;
		if (copied == length)
			return 0;
		cursor += bv.bv_len;
	}

	return -EIO;
}

static void zns_lsm_reconcile_failed_write(struct zns_lsm *lsm,
					    sector_t physical_sector)
{
	struct zns_lsm_wp_report report;
	int ret;

	ret = zns_lsm_report_wp(lsm, physical_sector, &report);
	if (ret) {
		DMERR_LIMIT("failed to inspect zone after write error: %d", ret);
		return;
	}

	if (report.write_pointer != physical_sector)
		return;

	ret = zns_allocator_rollback(&lsm->allocator, physical_sector);
	if (ret)
		DMERR_LIMIT("failed to roll back sector %llu: %d",
			    (unsigned long long)physical_sector, ret);
}

static bool zns_lsm_valid_data_io(const struct zns_lsm *lsm,
				  const struct bio *bio)
{
	sector_t sector = bio->bi_iter.bi_sector;
	sector_t sectors = bio_sectors(bio);

	return sectors && sector <= lsm->logical_sectors &&
	       sectors <= lsm->logical_sectors - sector;
}

static int zns_lsm_process_read(struct zns_lsm *lsm, struct bio *bio)
{
	sector_t logical_sector = bio->bi_iter.bi_sector;
	sector_t remaining = bio_sectors(bio);
	unsigned int bio_offset = 0;
	struct page *page;
	int ret = 0;

	page = alloc_page(GFP_NOIO);
	if (!page)
		return -ENOMEM;

	while (remaining) {
		sector_t logical_block = logical_sector / lsm->sectors_per_block;
		sector_t block_offset = logical_sector % lsm->sectors_per_block;
		sector_t fragment = min_t(sector_t, remaining,
					  lsm->sectors_per_block - block_offset);
		sector_t physical_sector;
		unsigned int fragment_bytes = fragment << SECTOR_SHIFT;
		void *buffer;

		ret = zns_lsm_lookup_block(lsm, logical_block, &physical_sector);
		if (ret == -ENODATA) {
			buffer = kmap_local_page(page);
			memset(buffer, 0,
			       lsm->sectors_per_block << SECTOR_SHIFT);
			kunmap_local(buffer);
			ret = 0;
		} else if (!ret) {
			ret = zns_lsm_submit_block(lsm, physical_sector,
						   REQ_OP_READ, page);
		}
		if (ret)
			break;

		buffer = kmap_local_page(page);
		ret = zns_lsm_copy_bio_range(
			bio, bio_offset,
			(char *)buffer + (block_offset << SECTOR_SHIFT),
			fragment_bytes, true);
		kunmap_local(buffer);
		if (ret)
			break;

		logical_sector += fragment;
		remaining -= fragment;
		bio_offset += fragment_bytes;
	}

	__free_page(page);
	return ret;
}

static int zns_lsm_process_write(struct zns_lsm *lsm, struct bio *bio)
{
	sector_t logical_sector = bio->bi_iter.bi_sector;
	sector_t remaining = bio_sectors(bio);
	unsigned int bio_offset = 0;
	struct page *page;
	blk_opf_t write_opf = REQ_OP_WRITE | REQ_SYNC;
	int ret = 0;

	if (bio->bi_opf & REQ_PREFLUSH) {
		ret = blkdev_issue_flush(lsm->lower_bdev);
		if (ret)
			return ret;
	}
	if (bio->bi_opf & REQ_FUA)
		write_opf |= REQ_FUA;

	page = alloc_page(GFP_NOIO);
	if (!page)
		return -ENOMEM;

	while (remaining) {
		sector_t logical_block = logical_sector / lsm->sectors_per_block;
		sector_t block_offset = logical_sector % lsm->sectors_per_block;
		sector_t fragment = min_t(sector_t, remaining,
					  lsm->sectors_per_block - block_offset);
		sector_t physical_sector;
		unsigned int fragment_bytes = fragment << SECTOR_SHIFT;
		bool whole_block = block_offset == 0 &&
				   fragment == lsm->sectors_per_block;
		void *buffer;

		if (!whole_block) {
			ret = zns_lsm_lookup_block(lsm, logical_block,
						   &physical_sector);
			if (ret == -ENODATA) {
				buffer = kmap_local_page(page);
				memset(buffer, 0,
				       lsm->sectors_per_block << SECTOR_SHIFT);
				kunmap_local(buffer);
				ret = 0;
			} else if (!ret) {
				ret = zns_lsm_submit_block(lsm, physical_sector,
							   REQ_OP_READ, page);
			}
			if (ret)
				break;
		}

		buffer = kmap_local_page(page);
		ret = zns_lsm_copy_bio_range(
			bio, bio_offset,
			(char *)buffer + (block_offset << SECTOR_SHIFT),
			fragment_bytes, false);
		kunmap_local(buffer);
		if (ret)
			break;

		ret = zns_allocator_alloc(&lsm->allocator, &physical_sector);
		if (ret)
			break;
		ret = zns_lsm_submit_block(lsm, physical_sector, write_opf, page);
		if (ret) {
			zns_lsm_reconcile_failed_write(lsm, physical_sector);
			break;
		}

		ret = memtable_put_active(&lsm->active_memtable,
					  &lsm->immutable_memtable,
					  &lsm->table_lock,
					  lsm->memtable_threshold,
					  logical_block, physical_sector);
		if (ret)
			break;
		zns_lsm_maybe_queue_flush(lsm);

		logical_sector += fragment;
		remaining -= fragment;
		bio_offset += fragment_bytes;
	}

	__free_page(page);
	return ret;
}

static void zns_lsm_complete_bio(struct bio *bio, int ret)
{
	if (ret) {
		if (ret > 0)
			ret = -EIO;
		bio->bi_status = errno_to_blk_status(ret);
	}
	bio_endio(bio);
}

static void zns_lsm_io_worker(struct work_struct *work)
{
	struct zns_lsm_io_work *ctx =
		container_of(work, struct zns_lsm_io_work, work);
	struct bio *bio = ctx->bio;
	int ret;

	switch (bio_op(bio)) {
	case REQ_OP_READ:
		ret = zns_lsm_process_read(ctx->lsm, bio);
		break;
	case REQ_OP_WRITE:
		ret = zns_lsm_process_write(ctx->lsm, bio);
		break;
	case REQ_OP_FLUSH:
		ret = blkdev_issue_flush(ctx->lsm->lower_bdev);
		break;
	default:
		ret = -EOPNOTSUPP;
		break;
	}

	zns_lsm_complete_bio(bio, ret);
	kfree(ctx);
}

static int zns_lsm_queue_io(struct zns_lsm *lsm, struct bio *bio)
{
	struct zns_lsm_io_work *ctx;

	if (bio_op(bio) != REQ_OP_FLUSH && !zns_lsm_valid_data_io(lsm, bio))
		return DM_MAPIO_KILL;

	ctx = kmalloc(sizeof(*ctx), GFP_NOIO);
	if (!ctx)
		return DM_MAPIO_KILL;

	INIT_WORK(&ctx->work, zns_lsm_io_worker);
	ctx->lsm = lsm;
	ctx->bio = bio;
	queue_work(lsm->io_wq, &ctx->work);
	return DM_MAPIO_SUBMITTED;
}

static void zns_lsm_free_sstables(struct zns_lsm *lsm)
{
	struct zns_sstable *sst;
	struct zns_sstable *next;

	list_for_each_entry_safe(sst, next, &lsm->sstables, list) {
		list_del(&sst->list);
		kfree(sst);
	}
	lsm->nr_sstables = 0;
	lsm->nr_sst_entries = 0;
}

/*
 * Adopt the SSTables a previous instance left behind.
 *
 * The metadata zone is an append-only log, so walking it forward replays the
 * order the flushes happened in, and list_add() leaves the newest at the head
 * where the read path already expects the winner to be. Each header says how
 * far to jump to the next table, but its full payload is checksum- and
 * structure-verified before the table is adopted.
 *
 * An incomplete final table is also refused. Continuing after it would append
 * new records beyond an uncommitted gap and turn that tail into permanent
 * interior corruption on the next restart.
 */
static int zns_lsm_recover_sstables(struct zns_lsm *lsm)
{
	sector_t cursor = lsm->meta_start + ZNS_SST_BLOCK_SECTORS;
	int ret;

	while (cursor < lsm->meta_wp) {
		struct zns_sstable *sst;

		ret = zns_sst_load(lsm->lower_bdev, cursor, lsm->meta_wp, &sst);
		if (ret == -ENODATA) {
			DMERR("metadata zone %u has an incomplete SSTable at sector %llu",
			      lsm->super.meta_zone_id,
			      (unsigned long long)cursor);
			return -EUCLEAN;
		}
		if (ret) {
			DMERR("metadata zone %u is corrupt at sector %llu: %d",
			      lsm->super.meta_zone_id,
			      (unsigned long long)cursor, ret);
			return ret;
		}
		if (sst->seq != lsm->next_sst_seq) {
			DMERR("metadata zone %u has sequence %llu at sector %llu, expected %llu",
			      lsm->super.meta_zone_id,
			      (unsigned long long)sst->seq,
			      (unsigned long long)cursor,
			      (unsigned long long)lsm->next_sst_seq);
			kfree(sst);
			return -EUCLEAN;
		}

		list_add(&sst->list, &lsm->sstables);
		lsm->nr_sstables++;
		lsm->nr_sst_entries += sst->nr_entries;
		lsm->next_sst_seq++;

		cursor += (sector_t)sst->nr_blocks * ZNS_SST_BLOCK_SECTORS;
	}

	DMINFO("lsm: recovered %u SSTable(s) holding %llu mappings",
	       lsm->nr_sstables, lsm->nr_sst_entries);
	return 0;
}

static bool zns_lsm_data_zones_dirty(const struct zns_lsm *lsm)
{
	unsigned int i;

	for (i = 0; i + 1 < lsm->zone_table.nr_zones; i++)
		if (lsm->zone_table.zones[i].write_pointer !=
		    lsm->zone_table.zones[i].start_sector)
			return true;

	return false;
}

static int zns_lsm_validate_logical_capacity(struct zns_lsm *lsm,
					      sector_t logical_sectors)
{
	sector_t usable_sectors = 0;
	unsigned int i;

	if (lsm->zone_table.nr_zones < 2)
		return -EINVAL;

	for (i = 0; i + 1 < lsm->zone_table.nr_zones; i++) {
		sector_t capacity = lsm->zone_table.zones[i].capacity;

		capacity -= capacity % lsm->sectors_per_block;
		if (capacity > (sector_t)-1 - usable_sectors)
			return -EOVERFLOW;
		usable_sectors += capacity;
	}

	if (logical_sectors > usable_sectors) {
		DMERR("logical size %llu exceeds usable data-zone capacity %llu",
		      (unsigned long long)logical_sectors,
		      (unsigned long long)usable_sectors);
		return -ENOSPC;
	}

	return 0;
}

/*
 * Reserve the last zone of the underlying device for metadata and hand the
 * allocator only the zones ahead of it.
 *
 * An empty metadata zone means the device was never formatted, so the
 * superblock goes into its first block. Otherwise the superblock is read back
 * and has to describe the device actually in front of us. A mismatch is
 * refused instead of worked around: every mapping below it was recorded
 * against the geometry it names, and a moved reserved zone would turn them
 * into ordinary data space with no error anywhere.
 */
static int zns_lsm_open_metadata(struct zns_lsm *lsm, sector_t logical_sectors)
{
	const struct zns_zone *meta;
	struct zns_super on_disk;
	sector_t meta_wp;
	int ret;

	if (lsm->zone_table.nr_zones < 2)
		return -EINVAL;

	meta = &lsm->zone_table.zones[lsm->zone_table.nr_zones - 1];
	if (meta->capacity < ZNS_SST_BLOCK_SECTORS)
		return -EINVAL;
	if (meta->write_pointer < meta->start_sector)
		return -EINVAL;

	lsm->meta_start = meta->start_sector;
	lsm->meta_end = meta->start_sector + meta->capacity;

	/*
	 * A full zone reports its write pointer at the end of the zone, which
	 * is past the capacity whenever the zone has a capacity hole. Clamp
	 * rather than refuse: the SSTables in it are still readable, and a
	 * flush that tries to append will fail with -ENOSPC on its own.
	 * zns_zone_metadata_valid() makes the same allowance for data zones,
	 * and refusing here would mean a metadata zone can be filled once and
	 * then never opened again.
	 */
	if (meta->condition == BLK_ZONE_COND_FULL) {
		meta_wp = lsm->meta_end;
	} else {
		if (meta->write_pointer > lsm->meta_end)
			return -EINVAL;
		meta_wp = meta->write_pointer;
	}

	lsm->super.logical_sectors = logical_sectors;
	lsm->super.zone_size_sectors = meta->length;
	lsm->super.nr_zones = lsm->zone_table.nr_zones;
	lsm->super.meta_zone_id = meta->id;
	lsm->super.sectors_per_block = lsm->sectors_per_block;

	if (meta_wp != lsm->meta_start) {
		ret = zns_super_read(lsm->lower_bdev, lsm->meta_start,
				     &on_disk);
		if (ret) {
			DMERR("metadata zone %u holds no superblock we wrote: %d",
			      meta->id, ret);
			return ret;
		}

		ret = zns_super_matches(&on_disk, &lsm->super);
		if (ret)
			return ret;

		/* Adopt the existing format, uuid included. */
		lsm->super = on_disk;
		lsm->meta_wp = meta_wp;
		return zns_lsm_recover_sstables(lsm);
	}

	if (zns_lsm_data_zones_dirty(lsm)) {
		DMERR("refusing to format an empty metadata zone while data zones already hold writes");
		return -EUCLEAN;
	}

	lsm->super.uuid = get_random_u64();
	ret = zns_super_write(lsm->lower_bdev, lsm->meta_start, &lsm->super);
	if (ret)
		return ret;

	lsm->meta_wp = lsm->meta_start + ZNS_SST_BLOCK_SECTORS;
	DMINFO("lsm: formatted metadata zone %u", meta->id);
	return 0;
}

int zns_engine_init(struct zns_engine *engine, struct block_device *lower_bdev,
		    sector_t logical_sectors, sector_t physical_sectors,
		    sector_t sectors_per_block)
{
	struct zns_lsm *lsm;
	int ret;

	if (!engine || !lower_bdev || !logical_sectors || !sectors_per_block ||
	    !zns_lsm_memtable_threshold ||
	    sectors_per_block != ZNS_SST_BLOCK_SECTORS ||
	    logical_sectors % sectors_per_block ||
	    physical_sectors % sectors_per_block)
		return -EINVAL;

	lsm = kzalloc(sizeof(*lsm), GFP_KERNEL);
	if (!lsm)
		return -ENOMEM;

	lsm->lower_bdev = lower_bdev;
	lsm->logical_sectors = logical_sectors;
	lsm->sectors_per_block = sectors_per_block;
	lsm->memtable_threshold = zns_lsm_memtable_threshold;
	lsm->next_sst_seq = 1;
	mutex_init(&lsm->table_lock);
	mutex_init(&lsm->sst_lock);
	INIT_LIST_HEAD(&lsm->sstables);
	INIT_WORK(&lsm->flush_work, zns_lsm_flush_worker);

	ret = zns_zone_table_init(&lsm->zone_table, lower_bdev);
	if (ret)
		goto free_lsm;

	ret = zns_lsm_validate_logical_capacity(lsm, logical_sectors);
	if (ret)
		goto free_sstables;

	/* Validate and allocate all data-zone state before formatting metadata. */
	ret = zns_allocator_init_zoned(&lsm->allocator,
				       lsm->zone_table.zones,
				       lsm->zone_table.nr_zones - 1,
				       sectors_per_block);
	if (ret)
		goto free_sstables;

	ret = zns_lsm_open_metadata(lsm, logical_sectors);
	if (ret)
		goto exit_allocator;

	lsm->active_memtable = memtable_create();
	if (!lsm->active_memtable) {
		ret = -ENOMEM;
		goto exit_allocator;
	}

	lsm->flush_wq = alloc_ordered_workqueue("zns-lsm-flush", WQ_MEM_RECLAIM);
	if (!lsm->flush_wq) {
		ret = -ENOMEM;
		goto free_memtable;
	}

	lsm->io_wq = alloc_ordered_workqueue("zns-lsm-io", WQ_MEM_RECLAIM);
	if (!lsm->io_wq) {
		ret = -ENOMEM;
		goto destroy_flush_wq;
	}

	engine->private = lsm;
	DMINFO("lsm: %u data zones, metadata zone at sector %llu",
	       lsm->zone_table.nr_zones - 1,
	       (unsigned long long)lsm->meta_start);
	return 0;

destroy_flush_wq:
	destroy_workqueue(lsm->flush_wq);
free_memtable:
	memtable_free(lsm->active_memtable);
exit_allocator:
	zns_allocator_exit(&lsm->allocator);
free_sstables:
	zns_lsm_free_sstables(lsm);
	zns_zone_table_destroy(&lsm->zone_table);
free_lsm:
	kfree(lsm);
	return ret;
}

/*
 * Persist whatever is still resident, oldest generation first.
 *
 * The order is the whole point. A read takes the first hit walking the SSTable
 * list from its head, so a younger generation has to be appended behind an
 * older one. Reversed, a block that was overwritten just before shutdown would
 * come back holding the value it had before the overwrite.
 *
 * Both workqueues are already gone and device-mapper has drained the target,
 * so this is the only thread left touching the engine.
 */
static void zns_lsm_flush_all_sync(struct zns_lsm *lsm)
{
	struct lsm_memtable *generations[] = {
		lsm->flushing_memtable,
		lsm->immutable_memtable,
		lsm->active_memtable,
	};
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(generations); i++) {
		struct zns_sstable *sst;
		sector_t consumed;
		sector_t start;
		int ret;

		if (!generations[i])
			continue;

		start = lsm->meta_wp;
		ret = zns_sst_write(lsm->lower_bdev, generations[i],
				    start, lsm->meta_end,
				    lsm->next_sst_seq, &sst, &consumed);
		lsm->meta_wp += consumed;
		if (ret && ret != -ENODATA && start < lsm->meta_end)
			zns_lsm_reconcile_failed_meta_write(lsm, start, consumed);

		if (ret == -ENODATA)	/* an empty generation holds nothing */
			continue;
		if (ret) {
			/*
			 * Stop instead of skipping ahead. Writing a younger
			 * generation over the gap left by an older one that
			 * failed would let stale mappings outrank fresh ones.
			 */
			DMERR("shutdown flush stopped after %u of %u generations: %d",
			      i, (unsigned int)ARRAY_SIZE(generations), ret);
			return;
		}

		lsm->next_sst_seq++;
		kfree(sst);
	}
}

void zns_engine_exit(struct zns_engine *engine)
{
	struct zns_lsm *lsm;

	if (!engine)
		return;

	lsm = engine->private;
	if (!lsm)
		return;

	/* Publish every completed data write before draining metadata work. */
	destroy_workqueue(lsm->io_wq);
	destroy_workqueue(lsm->flush_wq);

	/* Only now is nothing else writing, so the tables can be serialized. */
#ifdef DM_ZNS_BASE_TESTING
	if (zns_lsm_test_skip_shutdown_flush)
		DMWARN("TEST ONLY: skipping clean-detach MemTable flush");
	else
#endif
		zns_lsm_flush_all_sync(lsm);

	memtable_free(lsm->active_memtable);
	memtable_free(lsm->immutable_memtable);
	memtable_free(lsm->flushing_memtable);
	zns_lsm_free_sstables(lsm);
	zns_allocator_exit(&lsm->allocator);
	zns_zone_table_destroy(&lsm->zone_table);
	kfree(lsm);
	engine->private = NULL;
}

int zns_engine_map(struct zns_engine *engine, struct bio *bio)
{
	struct zns_lsm *lsm;

	if (!engine || !bio)
		return DM_MAPIO_KILL;

	lsm = engine->private;
	if (!lsm)
		return DM_MAPIO_KILL;

	switch (bio_op(bio)) {
	case REQ_OP_FLUSH:
	case REQ_OP_READ:
	case REQ_OP_WRITE:
		return zns_lsm_queue_io(lsm, bio);
	default:
		return DM_MAPIO_KILL;
	}
}

void zns_engine_status(struct zns_engine *engine, char *result,
		       unsigned int maxlen)
{
	unsigned int active, immutable, flushing, nr_sstables;
	unsigned long long nr_sst_entries, meta_used;
	struct zns_lsm *lsm;
	unsigned int sz = 0;

	if (!engine || !engine->private) {
		DMEMIT("lsm uninitialized");
		return;
	}
	lsm = engine->private;

	mutex_lock(&lsm->table_lock);
	active = memtable_size(lsm->active_memtable);
	immutable = memtable_size(lsm->immutable_memtable);
	flushing = memtable_size(lsm->flushing_memtable);
	mutex_unlock(&lsm->table_lock);

	mutex_lock(&lsm->sst_lock);
	nr_sstables = lsm->nr_sstables;
	nr_sst_entries = lsm->nr_sst_entries;
	meta_used = lsm->meta_wp - lsm->meta_start;
	mutex_unlock(&lsm->sst_lock);

	DMEMIT("lsm active=%u immutable=%u flushing=%u sstables=%u sst_entries=%llu meta_used=%llu",
	       active, immutable, flushing, nr_sstables, nr_sst_entries,
	       meta_used);
}

const char *zns_engine_name(void)
{
	return "lsm";
}
