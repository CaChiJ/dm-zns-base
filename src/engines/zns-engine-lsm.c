// SPDX-License-Identifier: GPL-2.0
/*
 * LSM engine with allocator and MemTable lifecycle management.
 *
 * The last zone of the underlying device is reserved for mapping metadata, so
 * the allocator only ever sees the zones ahead of it.
 */

#include <linux/bio.h>
#include <linux/device-mapper.h>
#include <linux/errno.h>
#include <linux/module.h>
#include <linux/slab.h>

#include "lsm-memtable.h"
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

	/* Reserved metadata zone. Set once at init and read-only afterwards. */
	sector_t meta_start;
	sector_t meta_wp;
	sector_t meta_end;
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
	    logical_sectors % sectors_per_block ||
	    physical_sectors % sectors_per_block)
		return -EINVAL;

	lsm = kzalloc(sizeof(*lsm), GFP_KERNEL);
	if (!lsm)
		return -ENOMEM;

	lsm->lower_bdev = lower_bdev;
	lsm->sectors_per_block = sectors_per_block;
	lsm->memtable_threshold = zns_lsm_memtable_threshold;
	mutex_init(&lsm->table_lock);

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

	engine->private = lsm;
	DMINFO("lsm: %u data zones, metadata zone at sector %llu",
	       lsm->zone_table.nr_zones - 1,
	       (unsigned long long)lsm->meta_start);
	return 0;

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

	memtable_free(lsm->active_memtable);
	memtable_free(lsm->immutable_memtable);
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
		if (ret == -ENODATA) {
			zero_fill_bio(bio);
			bio_endio(bio);
			return DM_MAPIO_SUBMITTED;
		}
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
	unsigned long long meta_used;
	unsigned int active, immutable;
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

	meta_used = lsm->meta_wp - lsm->meta_start;

	DMEMIT("lsm active=%u immutable=%u meta_used=%llu",
	       active, immutable, meta_used);
}

const char *zns_engine_name(void)
{
	return "lsm";
}
