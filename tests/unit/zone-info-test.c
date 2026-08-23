// SPDX-License-Identifier: GPL-2.0
/* Standalone kernel-module test for underlying zone discovery. */

#include <linux/blkdev.h>
#include <linux/errno.h>
#include <linux/file.h>
#include <linux/module.h>
#include <linux/version.h>

#include "../../src/zns-zone.c"

#include "zns-test.h"

#define ZONE_TEST_DEVICE "/dev/nullb0"

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 0, 0)
struct zone_info_bdev_handle {
	struct file *file;
	struct block_device *bdev;
};

static int zone_info_open_bdev(struct zone_info_bdev_handle *handle)
{
	handle->file = bdev_file_open_by_path(ZONE_TEST_DEVICE, BLK_OPEN_READ,
					      NULL, NULL);
	if (IS_ERR(handle->file))
		return PTR_ERR(handle->file);

	handle->bdev = file_bdev(handle->file);
	return 0;
}

static void zone_info_close_bdev(struct zone_info_bdev_handle *handle)
{
	fput(handle->file);
}
#else
struct zone_info_bdev_handle {
	struct block_device *bdev;
};

static int zone_info_open_bdev(struct zone_info_bdev_handle *handle)
{
	handle->bdev = blkdev_get_by_path(ZONE_TEST_DEVICE, FMODE_READ,
					  zone_info_open_bdev);
	if (IS_ERR(handle->bdev))
		return PTR_ERR(handle->bdev);

	return 0;
}

static void zone_info_close_bdev(struct zone_info_bdev_handle *handle)
{
	blkdev_put(handle->bdev, FMODE_READ);
}
#endif

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

static int zone_info_test_discovery(void)
{
	struct zns_zone_table table;
	struct zone_info_bdev_handle handle;
	struct zns_zone *zone;
	int ret;

	ret = zone_info_open_bdev(&handle);
	if (ret) {
		pr_err("zns zone info test: cannot open %s (%d)\n",
		       ZONE_TEST_DEVICE, ret);
		return ret;
	}

	ret = zns_zone_table_init(&table, handle.bdev);
	if (ret)
		goto out_close;

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
out_close:
	zone_info_close_bdev(&handle);

	return ret;
}

static const struct zns_test_case zone_info_cases[] = {
	ZNS_TEST_CASE(zone_info_test_discovery,
		      "when the underlying device is opened, its zone table is discovered and consistent"),
};

static int __init zone_info_test_init(void)
{
	return zns_test_run("zone-info", zone_info_cases,
			    ARRAY_SIZE(zone_info_cases));
}

static void __exit zone_info_test_exit(void)
{
}

module_init(zone_info_test_init);
module_exit(zone_info_test_exit);

MODULE_DESCRIPTION("dm-zns-base underlying zone discovery test");
MODULE_LICENSE("GPL");
