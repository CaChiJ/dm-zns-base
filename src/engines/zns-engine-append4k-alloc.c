// SPDX-License-Identifier: GPL-2.0
/*
 * append4k-alloc engine: 4 KiB mapping with a separate physical allocator.
 */

#include <linux/bio.h>
#include <linux/device-mapper.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/vmalloc.h>

#include "zns-allocator.h"
#include "zns-engine.h"

#define ZNS_APPEND4K_ALLOC_UNMAPPED ((sector_t)-1)

struct zns_append4k_alloc {
	struct block_device *lower_bdev;
	sector_t *addr_mapping;
	unsigned long nr_logical_blocks;
	sector_t sectors_per_block;
	struct zns_allocator allocator;
	spinlock_t mapping_lock;
};

static bool zns_append4k_alloc_is_aligned_io(
		const struct zns_append4k_alloc *m, sector_t logical_sector,
		unsigned int sectors)
{
	return sectors == m->sectors_per_block &&
	       logical_sector % m->sectors_per_block == 0;
}

static int zns_append4k_alloc_read(struct zns_append4k_alloc *m,
				   sector_t logical_sector, unsigned int sectors,
				   sector_t *physical_sector)
{
	sector_t logical_block;

	if (!zns_append4k_alloc_is_aligned_io(m, logical_sector, sectors))
		return -EINVAL;

	logical_block = logical_sector / m->sectors_per_block;
	if (logical_block >= m->nr_logical_blocks)
		return -EINVAL;

	spin_lock(&m->mapping_lock);
	*physical_sector = m->addr_mapping[logical_block];
	spin_unlock(&m->mapping_lock);

	if (*physical_sector == ZNS_APPEND4K_ALLOC_UNMAPPED)
		return -ENODATA;

	return 0;
}

static int zns_append4k_alloc_write(struct zns_append4k_alloc *m,
				    sector_t logical_sector, unsigned int sectors,
				    sector_t *physical_sector)
{
	sector_t logical_block;
	int ret;

	if (!zns_append4k_alloc_is_aligned_io(m, logical_sector, sectors))
		return -EINVAL;

	logical_block = logical_sector / m->sectors_per_block;
	if (logical_block >= m->nr_logical_blocks)
		return -EINVAL;

	ret = zns_allocator_alloc(&m->allocator, physical_sector);
	if (ret)
		return ret;

	spin_lock(&m->mapping_lock);
	m->addr_mapping[logical_block] = *physical_sector;
	spin_unlock(&m->mapping_lock);

	return 0;
}

int zns_engine_init(struct zns_engine *engine, struct block_device *lower_bdev,
		    sector_t logical_sectors, sector_t physical_sectors,
		    sector_t sectors_per_block)
{
	struct zns_append4k_alloc *m;
	unsigned long i;
	int ret;

	if (sectors_per_block == 0 || logical_sectors % sectors_per_block ||
	    physical_sectors % sectors_per_block)
		return -EINVAL;

	m = kzalloc(sizeof(*m), GFP_KERNEL);
	if (!m)
		return -ENOMEM;

	m->nr_logical_blocks = logical_sectors / sectors_per_block;
	m->addr_mapping = vmalloc_array(m->nr_logical_blocks,
					 sizeof(*m->addr_mapping));
	if (!m->addr_mapping) {
		kfree(m);
		return -ENOMEM;
	}

	for (i = 0; i < m->nr_logical_blocks; i++)
		m->addr_mapping[i] = ZNS_APPEND4K_ALLOC_UNMAPPED;

	m->lower_bdev = lower_bdev;
	m->sectors_per_block = sectors_per_block;
	ret = zns_allocator_init(&m->allocator, physical_sectors,
				 sectors_per_block);
	if (ret) {
		vfree(m->addr_mapping);
		kfree(m);
		return ret;
	}
	spin_lock_init(&m->mapping_lock);
	engine->private = m;

	return 0;
}

void zns_engine_exit(struct zns_engine *engine)
{
	struct zns_append4k_alloc *m = engine->private;

	if (!m)
		return;

	zns_allocator_exit(&m->allocator);
	vfree(m->addr_mapping);
	kfree(m);
	engine->private = NULL;
}

int zns_engine_map(struct zns_engine *engine, struct bio *bio)
{
	struct zns_append4k_alloc *m = engine->private;
	sector_t physical_sector;
	int ret;

	switch (bio_op(bio)) {
	case REQ_OP_FLUSH:
		bio_set_dev(bio, m->lower_bdev);
		return DM_MAPIO_REMAPPED;
	case REQ_OP_READ:
		ret = zns_append4k_alloc_read(m, bio->bi_iter.bi_sector,
					       bio_sectors(bio), &physical_sector);
		if (ret == -ENODATA) {
			zero_fill_bio(bio);
			bio_endio(bio);
			return DM_MAPIO_SUBMITTED;
		}
		if (ret)
			return DM_MAPIO_KILL;

		bio->bi_iter.bi_sector = physical_sector;
		bio_set_dev(bio, m->lower_bdev);
		return DM_MAPIO_REMAPPED;
	case REQ_OP_WRITE:
		ret = zns_append4k_alloc_write(m, bio->bi_iter.bi_sector,
						bio_sectors(bio), &physical_sector);
		if (ret)
			return DM_MAPIO_KILL;

		bio->bi_iter.bi_sector = physical_sector;
		bio_set_dev(bio, m->lower_bdev);
		return DM_MAPIO_REMAPPED;
	default:
		return DM_MAPIO_KILL;
	}
}

const char *zns_engine_name(void)
{
	return "append4k-alloc";
}
