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
	if (!engine || !engine->private || !bio)
		return DM_MAPIO_KILL;

	/* Read and write mapping will be connected in a later milestone. */
	return DM_MAPIO_KILL;
}

const char *zns_engine_name(void)
{
	return "lsm";
}
