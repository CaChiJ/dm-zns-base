// SPDX-License-Identifier: GPL-2.0
/* LSM engine skeleton with allocator and MemTable lifecycle management. */

#include <linux/bio.h>
#include <linux/device-mapper.h>
#include <linux/errno.h>
#include <linux/slab.h>

#include "lsm-memtable.h"
#include "zns-allocator.h"
#include "zns-engine.h"

struct zns_lsm {
	struct block_device *lower_bdev;
	struct zns_allocator allocator;
	struct lsm_memtable memtable;
	sector_t sectors_per_block;
};

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
	return memtable_lookup(&lsm->memtable, logical_block, physical_sector,
			       NULL);
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

	return memtable_put(&lsm->memtable, logical_block, *physical_sector);
}

int zns_engine_init(struct zns_engine *engine, struct block_device *lower_bdev,
		    sector_t logical_sectors, sector_t physical_sectors,
		    sector_t sectors_per_block)
{
	struct zns_lsm *lsm;
	int ret;

	if (!engine || !lower_bdev || !sectors_per_block ||
	    logical_sectors % sectors_per_block ||
	    physical_sectors % sectors_per_block)
		return -EINVAL;

	lsm = kzalloc(sizeof(*lsm), GFP_KERNEL);
	if (!lsm)
		return -ENOMEM;

	lsm->lower_bdev = lower_bdev;
	lsm->sectors_per_block = sectors_per_block;

	ret = zns_allocator_init(&lsm->allocator, physical_sectors,
				 sectors_per_block);
	if (ret)
		goto free_lsm;

	ret = memtable_init(&lsm->memtable);
	if (ret)
		goto exit_allocator;

	engine->private = lsm;
	return 0;

exit_allocator:
	zns_allocator_exit(&lsm->allocator);
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

	memtable_destroy(&lsm->memtable);
	zns_allocator_exit(&lsm->allocator);
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

const char *zns_engine_name(void)
{
	return "lsm";
}
