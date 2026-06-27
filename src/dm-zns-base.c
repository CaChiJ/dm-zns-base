// SPDX-License-Identifier: GPL-2.0
/*
 * dm-zns-base: M0 scaffold for the capstone project.
 *
 * Registers a zoned-aware pass-through DM target on top of a host-managed
 * zoned device. The random-to-sequential translation that the project is
 * actually about is left out on purpose — that's the student's work.
 * See docs/07-milestones.md.
 */

#include <linux/module.h>
#include <linux/init.h>
#include <linux/bio.h>
#include <linux/device-mapper.h>
#include <linux/spinlock.h>
#include <linux/vmalloc.h>

#define DM_MSG_PREFIX "zns-base"
#define ZNS_BASE_BLOCK_SECTORS 8
#define ZNS_BASE_UNMAPPED ((sector_t)-1)

struct zns_mapping {
	sector_t *addr_mapping;      		/* Logical block -> Physical sector 매핑 */
	sector_t next_append_sector; 		/* 다음 append 시 write될 물리 섹터 */
	unsigned long nr_logical_blocks;	/* 전체 Logical block 개수 */
	sector_t sectors_per_block;      	/* Block 하나에 들어가는 Sector 개수 (8 sectors = 4 KiB) */
	sector_t nr_physical_sectors;   	/* append-only 물리 주소 공간 크기 (섹터 개수) */
	spinlock_t lock;             		/* 매핑 테이블과 append 포인터 보호 */
};

struct zns_base_c {
	struct dm_dev *dev;
	struct zns_mapping mapping;
};

/* Internal address-mapping helpers. */
static int zns_mapping_init(struct zns_mapping *m, sector_t logical_sectors, sector_t nr_physical_sectors, sector_t sectors_per_block);
static void zns_mapping_exit(struct zns_mapping *m);
static int zns_mapping_read(struct zns_mapping *m, sector_t logical_sector, unsigned int sectors, sector_t *physical_sector);
static int zns_mapping_write(struct zns_mapping *m, sector_t logical_sector, unsigned int sectors, sector_t *physical_sector);

static int zns_base_ctr(struct dm_target *ti, unsigned int argc, char **argv)
{
	struct zns_base_c *c;
	int ret;

	if (argc != 1) {
		ti->error = "expected one argument: underlying device";
		return -EINVAL;
	}

	c = kzalloc(sizeof(*c), GFP_KERNEL);
	if (!c) {
		ti->error = "out of memory";
		return -ENOMEM;
	}

	ret = dm_get_device(ti, argv[0], dm_table_get_mode(ti->table), &c->dev);
	if (ret) {
		ti->error = "failed to open underlying device";
		kfree(c);
		return ret;
	}

	ret = zns_mapping_init(&c->mapping, ti->len, ti->len, ZNS_BASE_BLOCK_SECTORS);
	if (ret) {
		ti->error = "failed to initialize address mapping";
		dm_put_device(ti, c->dev);
		kfree(c);
		return ret;
	}

	ret = dm_set_target_max_io_len(ti, ZNS_BASE_BLOCK_SECTORS);
	if (ret) {
		ti->error = "failed to set target max io length";
		zns_mapping_exit(&c->mapping);
		dm_put_device(ti, c->dev);
		kfree(c);
		return ret;
	}

	ti->private = c;
	ti->num_flush_bios = 1;

	DMINFO("ctr: target attached on top of %s (%lu mapping entries)", argv[0], c->mapping.nr_logical_blocks);
	return 0;
}

static void zns_base_dtr(struct dm_target *ti)
{
	struct zns_base_c *c = ti->private;

	zns_mapping_exit(&c->mapping);
	dm_put_device(ti, c->dev);
	kfree(c);
	DMINFO("dtr: target detached");
}

static int zns_base_map(struct dm_target *ti, struct bio *bio)
{
	struct zns_base_c *c = ti->private;
	sector_t physical_sector;
	int ret;

	switch (bio_op(bio)) {
	case REQ_OP_FLUSH:
		bio_set_dev(bio, c->dev->bdev);
		return DM_MAPIO_REMAPPED;
	case REQ_OP_READ:
		ret = zns_mapping_read(&c->mapping, bio->bi_iter.bi_sector, bio_sectors(bio), &physical_sector);

		// edge case 1: 매핑되지 않은 logical block
		if (ret == -ENODATA) {
			zero_fill_bio(bio); 
			bio_endio(bio);
			return DM_MAPIO_SUBMITTED;
		}

		// edge case 2: 공간 부족, 범위 오류
		if (ret) {
			return DM_MAPIO_KILL;
		}
		
		bio->bi_iter.bi_sector = physical_sector;
		bio_set_dev(bio, c->dev->bdev);
		return DM_MAPIO_REMAPPED;
	case REQ_OP_WRITE:
		ret = zns_mapping_write(&c->mapping, bio->bi_iter.bi_sector, bio_sectors(bio), &physical_sector);

		// edge case: 공간 부족, 범위 오류
		if (ret) {
			return DM_MAPIO_KILL;
		}

		bio->bi_iter.bi_sector = physical_sector;
		bio_set_dev(bio, c->dev->bdev);
		return DM_MAPIO_REMAPPED;
	default:
		return DM_MAPIO_KILL;
	}
}

static struct target_type zns_base_target = {
	.name            = "zns-base",
	.version         = {0, 1, 0},
	.module          = THIS_MODULE,
	.ctr             = zns_base_ctr,
	.dtr             = zns_base_dtr,
	.map             = zns_base_map,
};

static int __init zns_base_init(void)
{
	int ret = dm_register_target(&zns_base_target);

	if (ret < 0)
		DMERR("target registration failed: %d", ret);
	else
		DMINFO("target registered");
	return ret;
}

static void __exit zns_base_exit(void)
{
	dm_unregister_target(&zns_base_target);
	DMINFO("target unregistered");
}

/**
 * ===================================
 * 파일 내부에서만 사용되는 helper function
 * ===================================
 */
static bool zns_mapping_is_aligned_io(const struct zns_mapping *m, sector_t logical_sector, unsigned int sectors)
{
	return sectors == m->sectors_per_block &&
	       logical_sector % m->sectors_per_block == 0;
}

static int zns_mapping_init(struct zns_mapping *m, sector_t logical_sectors, sector_t nr_physical_sectors, sector_t sectors_per_block)
{

	if (sectors_per_block == 0 || logical_sectors % sectors_per_block ||
	    nr_physical_sectors % sectors_per_block)
		return -EINVAL;

	m->nr_logical_blocks = logical_sectors / sectors_per_block;
	m->addr_mapping = vmalloc_array(m->nr_logical_blocks,
					sizeof(*m->addr_mapping));
	if (!m->addr_mapping)
		return -ENOMEM;

	for (unsigned long i = 0; i < m->nr_logical_blocks; i++)
		m->addr_mapping[i] = ZNS_BASE_UNMAPPED;

	m->next_append_sector = 0;
	m->sectors_per_block = sectors_per_block;
	m->nr_physical_sectors = nr_physical_sectors;
	spin_lock_init(&m->lock);

	return 0;
}

static void zns_mapping_exit(struct zns_mapping *m)
{
	vfree(m->addr_mapping);
	m->addr_mapping = NULL;
}

static int zns_mapping_read(struct zns_mapping *m, sector_t logical_sector, unsigned int sectors, sector_t *physical_sector)
{
	sector_t logical_block;

	if (!zns_mapping_is_aligned_io(m, logical_sector, sectors))
		return -EINVAL;

	logical_block = logical_sector / m->sectors_per_block;
	if (logical_block >= m->nr_logical_blocks)
		return -EINVAL;

	spin_lock(&m->lock);
	*physical_sector = m->addr_mapping[logical_block];
	spin_unlock(&m->lock);

	if (*physical_sector == ZNS_BASE_UNMAPPED)
		return -ENODATA;

	return 0;
}

static int zns_mapping_write(struct zns_mapping *m, sector_t logical_sector, unsigned int sectors, sector_t *physical_sector)
{
	sector_t logical_block;

	if (!zns_mapping_is_aligned_io(m, logical_sector, sectors))
		return -EINVAL;

	logical_block = logical_sector / m->sectors_per_block;
	if (logical_block >= m->nr_logical_blocks)
		return -EINVAL;

	spin_lock(&m->lock);
	if (m->next_append_sector + m->sectors_per_block > m->nr_physical_sectors) {
		spin_unlock(&m->lock);
		return -ENOSPC;
	}

	*physical_sector = m->next_append_sector;
	m->next_append_sector += m->sectors_per_block;
	m->addr_mapping[logical_block] = *physical_sector;
	spin_unlock(&m->lock);

	return 0;
}

module_init(zns_base_init);
module_exit(zns_base_exit);

MODULE_DESCRIPTION("ZNS base dm target (zoned-aware pass-through scaffold)");
MODULE_AUTHOR("SPLAB");
MODULE_LICENSE("GPL");
