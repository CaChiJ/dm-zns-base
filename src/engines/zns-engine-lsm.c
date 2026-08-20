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
#include <linux/device-mapper.h>
#include <linux/errno.h>
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
	struct workqueue_struct *read_wq;
	struct work_struct flush_work;
};

struct zns_lsm_read_work {
	struct work_struct work;
	struct zns_lsm *lsm;
	struct bio *bio;
};

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

static bool zns_lsm_has_sstables(struct zns_lsm *lsm)
{
	bool present;

	mutex_lock(&lsm->sst_lock);
	present = lsm->nr_sstables != 0;
	mutex_unlock(&lsm->sst_lock);

	return present;
}

static bool zns_lsm_is_aligned_io(const struct zns_lsm *lsm,
				  sector_t logical_sector,
				  unsigned int sectors)
{
	return sectors == lsm->sectors_per_block &&
	       logical_sector % lsm->sectors_per_block == 0;
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

static void zns_lsm_read_worker(struct work_struct *work)
{
	struct zns_lsm_read_work *ctx =
		container_of(work, struct zns_lsm_read_work, work);
	struct zns_lsm *lsm = ctx->lsm;
	struct bio *bio = ctx->bio;
	sector_t logical_block;
	sector_t physical_sector;
	int ret;

	logical_block = bio->bi_iter.bi_sector / lsm->sectors_per_block;

	/* Re-check: a flush may have moved the mapping since the .map() miss. */
	ret = zns_lsm_lookup_memtables(lsm, logical_block, &physical_sector);
	if (ret == -ENODATA)
		ret = zns_lsm_lookup_sstables(lsm, logical_block,
					      &physical_sector);

	if (ret == -ENODATA) {
		zero_fill_bio(bio);
		bio_endio(bio);
	} else if (ret) {
		bio->bi_status = errno_to_blk_status(ret);
		bio_endio(bio);
	} else {
		bio->bi_iter.bi_sector = physical_sector;
		bio_set_dev(bio, lsm->lower_bdev);
		submit_bio_noacct(bio);
	}

	kfree(ctx);
}

/*
 * SSTable lookups sleep on block reads, which .map() cannot do, so a MemTable
 * miss is handed to the read workqueue. Without any SSTable on disk the answer
 * is already known and the bio is completed here.
 */
static int zns_lsm_queue_read(struct zns_lsm *lsm, struct bio *bio)
{
	struct zns_lsm_read_work *ctx;

	if (!zns_lsm_has_sstables(lsm)) {
		zero_fill_bio(bio);
		bio_endio(bio);
		return DM_MAPIO_SUBMITTED;
	}

	ctx = kmalloc(sizeof(*ctx), GFP_NOIO);
	if (!ctx)
		return DM_MAPIO_KILL;

	INIT_WORK(&ctx->work, zns_lsm_read_worker);
	ctx->lsm = lsm;
	ctx->bio = bio;
	queue_work(lsm->read_wq, &ctx->work);

	return DM_MAPIO_SUBMITTED;
}

static int zns_lsm_read(struct zns_lsm *lsm, sector_t logical_sector,
			unsigned int sectors, sector_t *physical_sector)
{
	sector_t logical_block;

	if (!zns_lsm_is_aligned_io(lsm, logical_sector, sectors))
		return -EINVAL;

	logical_block = logical_sector / lsm->sectors_per_block;
	return zns_lsm_lookup_memtables(lsm, logical_block, physical_sector);
}

static int zns_lsm_write(struct zns_lsm *lsm, sector_t logical_sector,
			 unsigned int sectors, sector_t *physical_sector)
{
	sector_t logical_block;
	int ret;

	if (!zns_lsm_is_aligned_io(lsm, logical_sector, sectors))
		return -EINVAL;

	logical_block = logical_sector / lsm->sectors_per_block;
	ret = zns_allocator_alloc(&lsm->allocator, physical_sector);
	if (ret)
		return ret;

	ret = memtable_put_active(&lsm->active_memtable,
				  &lsm->immutable_memtable,
				  &lsm->table_lock,
				  lsm->memtable_threshold,
				  logical_block, *physical_sector);
	if (ret)
		return ret;

	zns_lsm_maybe_queue_flush(lsm);
	return 0;
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

static bool zns_lsm_data_zones_dirty(const struct zns_lsm *lsm)
{
	unsigned int i;

	for (i = 0; i + 1 < lsm->zone_table.nr_zones; i++)
		if (lsm->zone_table.zones[i].write_pointer !=
		    lsm->zone_table.zones[i].start_sector)
			return true;

	return false;
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
	int ret;

	if (lsm->zone_table.nr_zones < 2)
		return -EINVAL;

	meta = &lsm->zone_table.zones[lsm->zone_table.nr_zones - 1];
	if (meta->capacity < ZNS_SST_BLOCK_SECTORS)
		return -EINVAL;
	if (meta->write_pointer < meta->start_sector ||
	    meta->write_pointer > meta->start_sector + meta->capacity)
		return -EINVAL;

	lsm->meta_start = meta->start_sector;
	lsm->meta_end = meta->start_sector + meta->capacity;

	lsm->super.logical_sectors = logical_sectors;
	lsm->super.zone_size_sectors = meta->length;
	lsm->super.nr_zones = lsm->zone_table.nr_zones;
	lsm->super.meta_zone_id = meta->id;
	lsm->super.sectors_per_block = lsm->sectors_per_block;

	if (meta->write_pointer != meta->start_sector) {
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
		lsm->meta_wp = meta->write_pointer;
		return 0;
	}

	if (zns_lsm_data_zones_dirty(lsm))
		DMWARN("formatting an empty metadata zone while data zones already hold writes; their mappings are unrecoverable");

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

	if (!engine || !lower_bdev || !sectors_per_block ||
	    !zns_lsm_memtable_threshold ||
	    sectors_per_block != ZNS_SST_BLOCK_SECTORS ||
	    logical_sectors % sectors_per_block ||
	    physical_sectors % sectors_per_block)
		return -EINVAL;

	lsm = kzalloc(sizeof(*lsm), GFP_KERNEL);
	if (!lsm)
		return -ENOMEM;

	lsm->lower_bdev = lower_bdev;
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

	ret = zns_lsm_open_metadata(lsm, logical_sectors);
	if (ret)
		goto destroy_zone_table;

	ret = zns_allocator_init_zoned(&lsm->allocator,
				       lsm->zone_table.zones,
				       lsm->zone_table.nr_zones - 1,
				       sectors_per_block);
	if (ret)
		goto destroy_zone_table;

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

	lsm->read_wq = alloc_workqueue("zns-lsm-read", WQ_MEM_RECLAIM, 0);
	if (!lsm->read_wq) {
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
destroy_zone_table:
	zns_zone_table_destroy(&lsm->zone_table);
free_lsm:
	kfree(lsm);
	return ret;
}

void zns_engine_exit(struct zns_engine *engine)
{
	struct zns_lsm *lsm;

	if (!engine)
		return;

	lsm = engine->private;
	if (!lsm)
		return;

	/* Drain both queues before anything they reference goes away. */
	destroy_workqueue(lsm->read_wq);
	destroy_workqueue(lsm->flush_wq);

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
	sector_t physical_sector;
	int ret;

	if (!engine || !bio)
		return DM_MAPIO_KILL;

	lsm = engine->private;
	if (!lsm)
		return DM_MAPIO_KILL;

	switch (bio_op(bio)) {
	case REQ_OP_FLUSH:
		bio_set_dev(bio, lsm->lower_bdev);
		return DM_MAPIO_REMAPPED;
	case REQ_OP_READ:
		ret = zns_lsm_read(lsm, bio->bi_iter.bi_sector,
				   bio_sectors(bio), &physical_sector);
		if (ret == -ENODATA)
			return zns_lsm_queue_read(lsm, bio);
		if (ret)
			return DM_MAPIO_KILL;

		bio->bi_iter.bi_sector = physical_sector;
		bio_set_dev(bio, lsm->lower_bdev);
		return DM_MAPIO_REMAPPED;
	case REQ_OP_WRITE:
		ret = zns_lsm_write(lsm, bio->bi_iter.bi_sector,
				    bio_sectors(bio), &physical_sector);
		if (ret)
			return DM_MAPIO_KILL;

		bio->bi_iter.bi_sector = physical_sector;
		bio_set_dev(bio, lsm->lower_bdev);
		return DM_MAPIO_REMAPPED;
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
