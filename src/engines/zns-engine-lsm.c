// SPDX-License-Identifier: GPL-2.0
/*
 * LSM engine with allocator and MemTable lifecycle management.
 *
 * The last zone of the underlying device is reserved for mapping metadata, so
 * the allocator only ever sees the zones ahead of it. Reads walk
 *
 *	active -> immutable -> SSTables (newest first)
 *
 * and fall back to a zero fill when the logical block was never written.
 */

#include <linux/bio.h>
#include <linux/device-mapper.h>
#include <linux/errno.h>
#include <linux/list.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/workqueue.h>

#include "lsm-memtable.h"
#include "lsm-sstable.h"
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
	struct lsm_memtable *active_memtable;
	struct lsm_memtable *immutable_memtable;
	struct mutex table_lock;
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

	struct workqueue_struct *read_wq;
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

static int zns_lsm_lookup_mapping(
		struct zns_lsm *lsm, sector_t logical_block,
		sector_t *physical_sector)
{
	if (!lsm || !physical_sector)
		return -EINVAL;

	return memtable_lookup_active_immutable(
			&lsm->active_memtable, &lsm->immutable_memtable,
			&lsm->table_lock, logical_block, physical_sector);
}

/*
 * Sleeps on SSTable block reads, so this only runs from the read workqueue. The
 * list is append-only for now, but sst_lock is held for the whole walk so that
 * a newly published SSTable cannot be spliced in underneath it.
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

static int zns_lsm_read(struct zns_lsm *lsm, sector_t logical_sector,
			unsigned int sectors, sector_t *physical_sector)
{
	sector_t logical_block;

	if (!zns_lsm_is_aligned_io(lsm, logical_sector, sectors))
		return -EINVAL;

	logical_block = logical_sector / lsm->sectors_per_block;
	return zns_lsm_lookup_mapping(lsm, logical_block, physical_sector);
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

	ret = zns_lsm_lookup_mapping(lsm, logical_block, &physical_sector);
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
 * is already known and the bio is completed right here.
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

	return memtable_put_active(&lsm->active_memtable,
				   &lsm->immutable_memtable,
				   &lsm->table_lock,
				   lsm->memtable_threshold,
				   logical_block, *physical_sector);
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
 * Reserve the last zone of the underlying device for mapping metadata and hand
 * the allocator only the zones ahead of it. The allocator cannot tell this
 * apart from a slightly smaller device, so it needs no changes.
 */
static int zns_lsm_init_metadata_zone(struct zns_lsm *lsm)
{
	const struct zns_zone *meta;

	if (lsm->zone_table.nr_zones < 2)
		return -EINVAL;

	meta = &lsm->zone_table.zones[lsm->zone_table.nr_zones - 1];
	if (meta->write_pointer < meta->start_sector ||
	    meta->write_pointer > meta->start_sector + meta->capacity)
		return -EINVAL;

	lsm->meta_start = meta->start_sector;
	lsm->meta_wp = meta->write_pointer;
	lsm->meta_end = meta->start_sector + meta->capacity;

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

	ret = zns_zone_table_init(&lsm->zone_table, lower_bdev);
	if (ret)
		goto free_lsm;

	ret = zns_lsm_init_metadata_zone(lsm);
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
	lsm->immutable_memtable = NULL;

	lsm->read_wq = alloc_workqueue("zns-lsm-read", WQ_MEM_RECLAIM, 0);
	if (!lsm->read_wq) {
		ret = -ENOMEM;
		goto free_memtable;
	}

	engine->private = lsm;
	DMINFO("lsm: %u data zones, metadata zone at sector %llu",
	       lsm->zone_table.nr_zones - 1,
	       (unsigned long long)lsm->meta_start);
	return 0;

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

	/* Drain the queue before anything it references goes away. */
	destroy_workqueue(lsm->read_wq);

	memtable_free(lsm->active_memtable);
	memtable_free(lsm->immutable_memtable);
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
	unsigned long long nr_sst_entries, meta_used;
	unsigned int active, immutable, nr_sstables;
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
	mutex_unlock(&lsm->table_lock);

	mutex_lock(&lsm->sst_lock);
	nr_sstables = lsm->nr_sstables;
	nr_sst_entries = lsm->nr_sst_entries;
	meta_used = lsm->meta_wp - lsm->meta_start;
	mutex_unlock(&lsm->sst_lock);

	DMEMIT("lsm active=%u immutable=%u sstables=%u sst_entries=%llu meta_used=%llu",
	       active, immutable, nr_sstables, nr_sst_entries, meta_used);
}

const char *zns_engine_name(void)
{
	return "lsm";
}
