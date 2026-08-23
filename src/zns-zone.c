// SPDX-License-Identifier: GPL-2.0

#include <linux/blkdev.h>
#include <linux/errno.h>
#include <linux/version.h>
#include <linux/slab.h>

#include "zns-zone.h"

struct zns_zone_report_ctx {
	struct zns_zone_table *table;
};

static bool zns_zone_is_active(u8 condition)
{
	return condition == BLK_ZONE_COND_IMP_OPEN ||
	       condition == BLK_ZONE_COND_EXP_OPEN ||
	       condition == BLK_ZONE_COND_CLOSED;
}

static unsigned int zns_bdev_nr_zones(struct block_device *bdev)
{
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 0, 0)
	return bdev_nr_zones(bdev);
#else
	return blkdev_nr_zones(bdev->bd_disk);
#endif
}

static int zns_zone_report_cb(struct blk_zone *reported,
			      unsigned int index, void *data)
{
	struct zns_zone_report_ctx *ctx = data;
	struct zns_zone *zone;

	if (index >= ctx->table->nr_zones)
		return -EOVERFLOW;

	zone = &ctx->table->zones[index];
	zone->id = index;
	zone->start_sector = reported->start;
	zone->length = reported->len;
	zone->capacity = reported->capacity;
	zone->write_pointer = reported->wp;
	zone->condition = reported->cond;
	zone->active = zns_zone_is_active(reported->cond);

	return 0;
}

int zns_zone_table_init(struct zns_zone_table *table,
			struct block_device *bdev)
{
	struct zns_zone_report_ctx ctx;
	unsigned int nr_zones;
	int reported;

	if (!table || !bdev)
		return -EINVAL;

	table->zones = NULL;
	table->nr_zones = 0;

	if (!bdev_is_zoned(bdev))
		return -ENODEV;

	nr_zones = zns_bdev_nr_zones(bdev);
	if (!nr_zones)
		return -ENODEV;

	table->zones = kcalloc(nr_zones, sizeof(*table->zones), GFP_KERNEL);
	if (!table->zones)
		return -ENOMEM;
	table->nr_zones = nr_zones;

	ctx.table = table;
	reported = blkdev_report_zones(bdev, 0, nr_zones,
				       zns_zone_report_cb, &ctx);
	if (reported < 0)
		goto fail;
	if (reported != nr_zones) {
		reported = -EIO;
		goto fail;
	}

	return 0;

fail:
	zns_zone_table_destroy(table);
	return reported;
}

void zns_zone_table_destroy(struct zns_zone_table *table)
{
	if (!table)
		return;

	kfree(table->zones);
	table->zones = NULL;
	table->nr_zones = 0;
}
