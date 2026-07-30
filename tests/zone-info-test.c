// SPDX-License-Identifier: GPL-2.0
/* Standalone kernel-module test for underlying zone discovery. */

#include <linux/blkdev.h>
#include <linux/errno.h>
#include <linux/file.h>
#include <linux/module.h>

#include "../src/zns-zone.c"

#define ZONE_TEST_DEVICE "/dev/nullb0"

static int zone_info_validate(const struct zns_zone_table *table)
{
	unsigned int i;

	if (!table->nr_zones || !table->zones)
		return -EINVAL;

	for (i = 0; i < table->nr_zones; i++) {
		const struct zns_zone *zone = &table->zones[i];

		if (zone->id != i || !zone->length ||
		    zone->capacity > zone->length)
			return -EINVAL;
		if (zone->write_pointer < zone->start_sector ||
		    zone->write_pointer > zone->start_sector + zone->capacity)
			return -EINVAL;
		if (i && zone->start_sector <=
			 table->zones[i - 1].start_sector)
			return -EINVAL;
	}

	return 0;
}

static int __init zone_info_test_init(void)
{
	struct zns_zone_table table;
	struct block_device *bdev;
	struct zns_zone *zone;
	struct file *bdev_file;
	int ret;

	bdev_file = bdev_file_open_by_path(ZONE_TEST_DEVICE, BLK_OPEN_READ,
					   NULL, NULL);
	if (IS_ERR(bdev_file)) {
		ret = PTR_ERR(bdev_file);
		pr_err("zns zone info test: cannot open %s (%d)\n",
		       ZONE_TEST_DEVICE, ret);
		return ret;
	}
	bdev = file_bdev(bdev_file);

	ret = zns_zone_table_init(&table, bdev);
	if (ret)
		goto out_fput;

	ret = zone_info_validate(&table);
	if (ret)
		goto out_destroy;

	zone = &table.zones[0];
	pr_info("zns zone info test: zones=%u\n", table.nr_zones);
	pr_info("zns zone info test: zone0 start=%llu len=%llu capacity=%llu wp=%llu condition=0x%x active=%u\n",
		(unsigned long long)zone->start_sector,
		(unsigned long long)zone->length,
		(unsigned long long)zone->capacity,
		(unsigned long long)zone->write_pointer,
		zone->condition,
		zone->active);

out_destroy:
	zns_zone_table_destroy(&table);
	if (!ret && (table.zones || table.nr_zones))
		ret = -EINVAL;
out_fput:
	fput(bdev_file);

	if (ret)
		pr_err("zns zone info test: FAIL (%d)\n", ret);
	else
		pr_info("zns zone info test: PASS\n");
	return ret;
}

static void __exit zone_info_test_exit(void)
{
}

module_init(zone_info_test_init);
module_exit(zone_info_test_exit);

MODULE_DESCRIPTION("dm-zns-base underlying zone discovery test");
MODULE_LICENSE("GPL");
